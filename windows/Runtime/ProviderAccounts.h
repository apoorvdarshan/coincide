#pragma once
#include "ACPVendorLaunch.h"
#include <sddl.h>
#include <roapi.h>
#include <functional>
#include <regex>
#include <set>
#include <winrt/Windows.Foundation.h>

namespace coincide {
// This file stores routing metadata only. The official CLI owns its credentials inside the
// selected, access-restricted profile. No credential is copied from an existing global profile.
struct ProviderAccountRecord {
    std::string id, provider, label, last_scope, identity_source, verified_at;
};
enum class ProviderAccountState {unknown, signed_out, signed_in_unverified, verified};
struct ProviderAccountMetadata {
    ProviderAccountState state{ProviderAccountState::unknown};
    std::string profile_id, provider, label, version, scope, identity_source, verified_at, credential_revision, status;
    bool can_resume(const std::string& saved_scope) const {
        return state == ProviderAccountState::verified && !scope.empty() && !saved_scope.empty() && scope == saved_scope;
    }
};
struct ProviderAccountProgram {
    std::string provider;
    std::filesystem::path executable;
    std::vector<std::wstring> command_prefix;
    static ProviderAccountProgram from(const ACPLaunchSpec& spec) {return {spec.provider, spec.executable, spec.options.command_prefix};}
};
struct ProviderAccountCapabilities {
    bool metadata{}, sign_in{};
    std::string explanation;
};

class ProviderAccountStore {
public:
    explicit ProviderAccountStore(std::filesystem::path root):root_(std::move(root)) {}
    const std::filesystem::path& root() const {return root_;}
    std::filesystem::path profile(const ProviderAccountRecord& record) const {
        validate(record); const auto path=root_ / ACPFileSystem::wide(record.provider) / ACPFileSystem::wide(record.id);
        if(std::filesystem::exists(path)) {ACPFileSystem root(root_); return root.working_directory(winrt::to_string(path.wstring()));} return path;
    }
    std::vector<ProviderAccountRecord> open() {
        if (!std::filesystem::exists(root_)) {snapshot_.reset(); opened_ = true; return {};}
        ACPFileSystem files(root_); root_ = files.root(); const auto path = root_ / L"provider-accounts.json";
        if (!std::filesystem::exists(path)) {snapshot_.reset(); opened_ = true; return {};}
        const auto bytes = files.read(winrt::to_string(path.wstring()));
        if (bytes.size() > 1024 * 1024) throw std::runtime_error("The provider account metadata file is too large");
        const auto json = ACPProtocol::Object::Parse(winrt::to_hstring(bytes));
        if (json.GetNamedNumber(L"schema", 0) != 1) throw std::runtime_error("Unsupported provider account metadata version");
        std::vector<ProviderAccountRecord> records; std::set<std::string> ids;
        for (const auto& raw : json.GetNamedArray(L"profiles", ACPProtocol::Array{})) {
            const auto item = raw.GetObject(); ProviderAccountRecord record{ACPProtocol::text(item,L"id"), ACPProtocol::text(item,L"provider"), ACPProtocol::text(item,L"label"),
                ACPProtocol::text(item,L"lastScope"), ACPProtocol::text(item,L"identitySource"), ACPProtocol::text(item,L"verifiedAt")};
            validate(record); if (!ids.insert(record.id).second || records.size() >= 100) throw std::runtime_error("Invalid provider account collection"); records.push_back(std::move(record));
        }
        snapshot_ = bytes; opened_ = true; return records;
    }
    ProviderAccountRecord create(const std::string& provider, const std::string& label) {
        GUID id{}; winrt::check_hresult(CoCreateGuid(&id)); wchar_t text[40]{}; StringFromGUID2(id,text,40);
        ProviderAccountRecord record{winrt::to_string(std::wstring_view(text+1,36)),provider,label,{},{},{}}; validate(record);
        if (!opened_) throw std::logic_error("Open provider account metadata before editing it");
        // Only a new app-owned directory is protected. Existing vendor/default directories are never
        // passed here, modified, or imported. Parent replacements are pinned during creation.
        std::filesystem::create_directories(root_); ACPFileSystem root(root_); root_ = root.root();
        const auto provider_path = root_ / ACPFileSystem::wide(provider); CreateDirectoryW(provider_path.c_str(),nullptr);
        root.working_directory(winrt::to_string(provider_path.wstring())); ACPFileSystem provider_pin(provider_path);
        const auto path = profile(record); if (!CreateDirectoryW(path.c_str(),nullptr)) throw std::runtime_error("Could not create a new provider profile");
        try {restrict_directory(path); ACPFileSystem pin(path); static_cast<void>(pin);}
        catch (...) {RemoveDirectoryW(path.c_str()); throw;}
        return record;
    }
    void save(const std::vector<ProviderAccountRecord>& records) {
        if (!opened_) throw std::logic_error("Open provider account metadata before editing it");
        if (records.size() > 100) throw std::invalid_argument("Keep at most 100 provider profiles");
        std::set<std::string> ids; ACPProtocol::Array profiles;
        for (const auto& record : records) {
            validate(record); if (!ids.insert(record.id).second) throw std::invalid_argument("Duplicate provider profile");
            ACPProtocol::Object item; ACPProtocol::put(item,L"id",record.id); ACPProtocol::put(item,L"provider",record.provider); ACPProtocol::put(item,L"label",record.label);
            ACPProtocol::put(item,L"lastScope",record.last_scope); ACPProtocol::put(item,L"identitySource",record.identity_source); ACPProtocol::put(item,L"verifiedAt",record.verified_at); profiles.Append(item);
        }
        std::filesystem::create_directories(root_); ACPFileSystem files(root_); root_ = files.root(); const auto path = root_ / L"provider-accounts.json";
        const auto current = std::filesystem::exists(path) ? std::optional(files.read(winrt::to_string(path.wstring()))) : std::nullopt;
        if (current != snapshot_) throw std::runtime_error("Provider profiles changed in another window; reload before saving");
        ACPProtocol::Object json; json.SetNamedValue(L"schema",ACPProtocol::Json::CreateNumberValue(1)); json.SetNamedValue(L"profiles",profiles);
        const auto bytes = winrt::to_string(json.Stringify()); files.write(winrt::to_string(path.wstring()),bytes); snapshot_ = bytes;
    }
    static void validate(const ProviderAccountRecord& record) {
        if (!provider_supported(record.provider) || record.id.size()!=36 || record.label.empty() || record.label.size()>160 || !ACPFileSystem::valid_utf8(record.label)) throw std::invalid_argument("Invalid provider profile");
        for (std::size_t i=0;i<record.id.size();++i) {
            const auto ch=record.id[i]; if (i==8||i==13||i==18||i==23) {if(ch!='-') throw std::invalid_argument("Invalid provider profile ID");}
            else if(!((ch>='0'&&ch<='9')||(ch>='a'&&ch<='f')||(ch>='A'&&ch<='F'))) throw std::invalid_argument("Invalid provider profile ID");
        }
        if (winrt::guid(winrt::to_hstring(record.id)) == winrt::guid{}) throw std::invalid_argument("Invalid provider profile ID");
        for(const auto ch:record.label) if(static_cast<unsigned char>(ch)<32 || ch==127) throw std::invalid_argument("Profile labels cannot contain control characters");
        if (!record.last_scope.empty() && (record.last_scope.size()!=64 || record.last_scope.find_first_not_of("0123456789abcdef")!=std::string::npos)) throw std::invalid_argument("Invalid account routing scope");
        if ((!record.identity_source.empty()&&record.identity_source!="cursor-status-getMe")||(!record.verified_at.empty()&&!std::regex_match(record.verified_at,std::regex("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")))) throw std::invalid_argument("Invalid provider identity metadata");
    }
    static bool provider_supported(const std::string& provider) {return provider=="cursor"||provider=="grok"||provider=="antigravity"||provider=="codex"||provider=="claude"||provider=="opencode";}
private:
    std::filesystem::path root_; std::optional<std::string> snapshot_; bool opened_{};
    static void restrict_directory(const std::filesystem::path& path) {
        HANDLE raw{}; if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&raw)) throw std::runtime_error("Could not read the current Windows profile identity"); NativeHandle token(raw);
        DWORD count{}; GetTokenInformation(token.get(),TokenUser,nullptr,0,&count); std::vector<unsigned char> storage(count);
        if(!count||!GetTokenInformation(token.get(),TokenUser,storage.data(),count,&count)) throw std::runtime_error("Could not protect the provider profile");
        wchar_t* sid{}; if(!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(storage.data())->User.Sid,&sid)) throw std::runtime_error("Could not protect the provider profile");
        struct Free {void* value; ~Free(){LocalFree(value);}} free_sid{sid};
        const auto sddl=L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;"+std::wstring(sid)+L")"; PSECURITY_DESCRIPTOR descriptor{};
        if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(),SDDL_REVISION_1,&descriptor,nullptr)) throw std::runtime_error("Could not protect the provider profile"); Free free_descriptor{descriptor};
        if(!SetFileSecurityW(path.c_str(),DACL_SECURITY_INFORMATION|PROTECTED_DACL_SECURITY_INFORMATION,descriptor)) throw std::runtime_error("Could not restrict access to the provider profile");
    }
};

class ProviderAccounts {
public:
    using Cancel = std::shared_ptr<std::atomic_bool>;
    using VerificationURL = std::function<void(const std::string&)>;
    static ProviderAccountCapabilities capabilities(const std::string& provider) {
        if(provider=="cursor") return {true,true,"The official CLI keeps this login in its own Coincide profile."};
        if(provider=="grok") return {true,true,"Device sign-in uses its own Coincide profile. Cached identity is labeled separately from a server-verified account."};
        if(provider=="antigravity") return {false,false,"Antigravity requires the account-risk acknowledgment and a verified Windows browser handoff before sign-in is available."};
        return {false,false,"Separate account metadata and sign-in are not available for this provider yet. Existing CLI profiles remain unchanged."};
    }
    static std::filesystem::path credential_path(const std::filesystem::path& profile,const std::string& provider) {
        if(provider=="cursor") return profile/L"Cursor/auth.json";
        if(provider=="grok") return profile/L"auth.json";
        return {};
    }
    // Revision detects replacement/refresh; it is not an account identity and never hashes tokens.
    // Open handles reject reparse points and hard links via the same bounded literal filesystem as ACP.
    static std::string credential_revision(const std::filesystem::path& profile,const std::string& provider) {
        ACPFileSystem files(profile); const auto path=credential_path(files.root(),provider); if(path.empty()) return {};
        if(!std::filesystem::exists(path)) return "missing";
        const auto parent=files.working_directory(winrt::to_string(path.parent_path().wstring())); ACPFileSystem pin(parent);
        NativeHandle file(CreateFileW(path.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
        BY_HANDLE_FILE_INFORMATION info{};
        if(file.get()==INVALID_HANDLE_VALUE||!GetFileInformationByHandle(file.get(),&info)||(info.dwFileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY))||info.nNumberOfLinks!=1) throw std::runtime_error("The provider credential profile is linked or unavailable");
        return std::to_string(info.dwVolumeSerialNumber)+":"+std::to_string(info.nFileIndexHigh)+":"+std::to_string(info.nFileIndexLow)+":"+std::to_string(info.nFileSizeHigh)+":"+std::to_string(info.nFileSizeLow)+":"+std::to_string(info.ftLastWriteTime.dwHighDateTime)+":"+std::to_string(info.ftLastWriteTime.dwLowDateTime);
    }
    static bool current(const ProviderAccountMetadata& metadata,const ProviderAccountRecord& record,const std::filesystem::path& profile) {
        if(metadata.state!=ProviderAccountState::verified||metadata.scope.empty()||metadata.profile_id!=record.id||metadata.provider!=record.provider) return false;
        try{return credential_revision(profile,record.provider)==metadata.credential_revision;} catch(...){return false;}
    }
    static ACPLaunchSpec bind(const ACPLaunchSpec& program,const ProviderAccountRecord& record,const std::filesystem::path& profile,
            const std::filesystem::path& cache,const ProviderAccountMetadata& metadata,const std::string& saved_scope={},bool resuming=false) {
        if(program.provider!=record.provider) throw std::invalid_argument("This profile belongs to a different provider");
        if(!current(metadata,record,profile)) throw std::runtime_error("The provider account changed; verify it again before continuing");
        return ACPVendorLaunch::bind_profile(program,profile,cache,{metadata.scope,saved_scope},true,resuming);
    }
    static ProviderAccountMetadata check(const ProviderAccountProgram& program,const ProviderAccountRecord& record,
            const std::filesystem::path& profile,const Cancel& cancel={}) {
        Apartment apartment;
        require_program(program,record); if(!capabilities(record.provider).metadata) throw std::runtime_error(capabilities(record.provider).explanation);
        ACPFileSystem pin(profile); ProviderAccountMetadata result; result.profile_id=record.id; result.provider=record.provider; result.label=record.label;
        const auto environment=profile_environment(record.provider,pin.root());
        const auto version=run(program,{L"--version"},pin.root(),environment,cancel,std::chrono::seconds(15));
        if(version.exit!=0) throw std::runtime_error("The provider version check failed"); result.version=version_label(version.output);
        if(record.provider=="cursor") {
            for(unsigned attempt=0;attempt<2;++attempt) {
                const auto before=credential_revision(pin.root(),record.provider);
                const auto status=run(program,{L"status",L"--format",L"json"},pin.root(),environment,cancel,std::chrono::seconds(30));
                result=parse_cursor_status(record,pin.root(),status.output,status.exit); result.version=version_label(version.output);
                if(before==result.credential_revision) break;
                result.state=ProviderAccountState::unknown; result.scope.clear(); result.status="The provider login changed during verification. Check status again before continuing.";
            }
        } else {
            result.credential_revision=credential_revision(pin.root(),record.provider);
            result.state=result.credential_revision=="missing"?ProviderAccountState::signed_out:ProviderAccountState::signed_in_unverified;
            result.status=result.state==ProviderAccountState::signed_out?"Not signed in to this profile.":"A native sign-in file is present. Its account identity has not been server-verified; saved conversations remain locked.";
        }
        return result;
    }
    // Called only by an explicit Sign in action. It never signs out, creates an external account,
    // imports a login, or opens a browser. Verification links stay ephemeral in the callback.
    static ProviderAccountMetadata sign_in(const ProviderAccountProgram& program,const ProviderAccountRecord& record,
            const std::filesystem::path& profile,const Cancel& cancel,const VerificationURL& verification_url) {
        Apartment apartment;
        require_program(program,record); if(!capabilities(record.provider).sign_in) throw std::runtime_error(capabilities(record.provider).explanation);
        ACPFileSystem pin(profile); const auto environment=profile_environment(record.provider,pin.root());
        const std::vector<std::wstring> args=record.provider=="cursor"?std::vector<std::wstring>{L"login"}:std::vector<std::wstring>{L"login",L"--device-auth"};
        const auto result=run(program,args,pin.root(),environment,cancel,std::chrono::minutes(5),verification_url);
        if(result.exit!=0) throw std::runtime_error("The provider sign-in did not complete. Its profile and existing conversations were preserved.");
        return check(program,record,pin.root(),cancel);
    }
    static ProviderAccountMetadata parse_cursor_status(const ProviderAccountRecord& record,const std::filesystem::path& profile,const std::string& bytes,DWORD exit) {
        ProviderAccountMetadata result; result.profile_id=record.id; result.provider=record.provider; result.label=record.label;
        result.credential_revision=credential_revision(profile,record.provider);
        ACPProtocol::Object status{nullptr}; const auto first=bytes.find('{'),last=bytes.rfind('}');
        if(exit!=0||first==std::string::npos||last==std::string::npos||!ACPProtocol::Object::TryParse(winrt::to_hstring(bytes.substr(first,last-first+1)),status)) {result.status="The provider could not verify its current account. Saved conversations remain locked.";return result;}
        const auto state=ACPProtocol::text(status,L"status");
        if(state=="unauthenticated"||state=="partially-authenticated") {result.state=ProviderAccountState::signed_out; result.status="Not signed in to this profile.";return result;}
        if(state!="authenticated"||!status.GetNamedBoolean(L"isAuthenticated",false)) {result.status="The provider returned an unknown sign-in state.";return result;}
        result.state=ProviderAccountState::signed_in_unverified; result.status="Signed in, but the provider did not verify its account identity. Try Check status again.";
        const auto user=status.GetNamedObject(L"userInfo",ACPProtocol::Object{}); auto subject=scalar(user,L"userId");
        const auto email=ACPProtocol::text(user,L"email"); if(subject.empty()) subject=email;
        if(subject.empty()||subject.size()>512||!safe_identity(subject)||result.credential_revision=="missing") return result;
        auto location=pin_profile_name(profile); const auto team=scalar(user,L"teamId");
        result.scope=AgentAccountScope::fingerprint(record.provider,subject+"\nteam:"+team,location); result.state=ProviderAccountState::verified;
        result.label=!email.empty()&&email.size()<=254&&safe_identity(email)?email:record.label; result.identity_source="cursor-status-getMe"; result.verified_at=utc_now();
        result.status="The provider verified this profile's current account."; return result;
    }
    static bool verification_url_allowed(const std::string& provider,const std::string& value) {
        if(value.size()>8192||value.find_first_of("\r\n\t ")!=std::string::npos) return false;
        try {
            winrt::Windows::Foundation::Uri uri(winrt::to_hstring(value)); if(uri.SchemeName()!=L"https"||!uri.UserName().empty()||!uri.Password().empty()||!uri.Fragment().empty()||uri.Port()!=443) return false;
            const auto host=winrt::to_string(uri.Host()); const bool allowed=provider=="cursor"?(host=="cursor.com"||host=="www.cursor.com"):
                provider=="grok"?(host=="auth.x.ai"||host=="accounts.x.ai"||host=="grok.com"):false;
            if(!allowed) return false;
            for(const auto& parameter:uri.QueryParsed()) {
                auto key=winrt::to_string(parameter.Name()); std::transform(key.begin(),key.end(),key.begin(),[](unsigned char c){return static_cast<char>(std::tolower(c));});
                if(key.find("token")!=std::string::npos||key.find("secret")!=std::string::npos||key=="api_key"||key=="apikey"||key=="password"||key=="authorization") return false;
            }
            return true;
        }catch(...){return false;}
    }
    static WindowsProcess::Environment profile_environment(const std::string& provider,const std::filesystem::path& profile) {
        WindowsProcess::Environment env;
        for(const auto* key:{L"NODE_OPTIONS",L"ELECTRON_RUN_AS_NODE",L"CURSOR_API_KEY",L"XAI_API_KEY",L"GROK_AUTH",L"GROK_CONFIG",L"GROK_CONFIG_PATH",L"GROK_LOCAL_AUTH",L"GROK_AUTH_PROVIDER_COMMAND",
                L"GROK_OIDC_ISSUER",L"GROK_OIDC_CLIENT_ID",L"GROK_OAUTH2_ISSUER",L"GROK_OAUTH2_CLIENT_ID",L"GROK_OAUTH2_PRINCIPAL_TYPE",L"GROK_OAUTH2_PRINCIPAL_ID",L"GROK_CLI_CHAT_PROXY_BASE_URL",L"GROK_MODELS_BASE_URL",
                L"CURSOR_AUTH_TOKEN",L"CURSOR_AUTH_TOKEN_EXPIRES_AT",L"CURSOR_API_BASE_URL",L"CURSOR_API_ENDPOINT",L"CURSOR_API_URL",L"CURSOR_WEBSITE_URL",L"CURSOR_LOCAL_AGENT_BASE_URL",
                L"CURSOR_AGENT_CLI_AUTHLESS_MODE",L"CURSOR_ENABLE_AUTHLESS",L"CURSOR_AGENT_CLI_LOCAL_MODE",L"CURSOR_AGENT_STORE",L"CURSOR_AGENT_STORE_FILES_DIR",L"CURSOR_AGENT_STORE_SHARED_PATHS",L"CURSOR_BEDROCK_AWS_AUTH_REFRESH",L"CURSOR_BEDROCK_BASE_URL"}) env.emplace_back(key,std::nullopt);
        // Redirect only this child. It cannot inherit another CLI's credential home or browser opener.
        for(const auto* key:{L"HOME",L"USERPROFILE",L"APPDATA",L"LOCALAPPDATA",L"XDG_CONFIG_HOME",L"XDG_DATA_HOME",L"XDG_CACHE_HOME"}) env.emplace_back(key,profile.wstring());
        env.emplace_back(L"NO_OPEN_BROWSER",L"1"); env.emplace_back(L"NO_COLOR",L"1");
        if(provider=="cursor") {
            env.emplace_back(L"CURSOR_CONFIG_DIR",profile.wstring()); env.emplace_back(L"CURSOR_DATA_DIR",profile.wstring()); env.emplace_back(L"CURSOR_INVOKED_AS",L"cursor-agent");
            env.emplace_back(L"AGENT_CLI_CREDENTIAL_STORE",L"file"); env.emplace_back(L"NODE_COMPILE_CACHE",(profile/L"compile-cache").wstring());
        } else if(provider=="grok") {env.emplace_back(L"GROK_HOME",profile.wstring()); env.emplace_back(L"GROK_MANAGED_BY_NPM",L"1");env.emplace_back(L"GROK_DISABLE_AUTOUPDATER",L"1");}
        return env;
    }
private:
    // Metadata may run on a plain worker or a WinUI STA. Initialize only an uninitialized/MTA
    // worker; RPC_E_CHANGED_MODE means the caller already owns a valid STA and is preserved.
    struct Apartment {
        HRESULT result{RoInitialize(RO_INIT_MULTITHREADED)};
        Apartment(){if(FAILED(result)&&result!=RPC_E_CHANGED_MODE)winrt::check_hresult(result);}
        ~Apartment(){if(SUCCEEDED(result))RoUninitialize();}
    };
    struct Run {DWORD exit{};std::string output;};
    static void require_program(const ProviderAccountProgram& program,const ProviderAccountRecord& record) {
        ProviderAccountStore::validate(record); DWORD binary{};
        if(program.provider!=record.provider||!program.executable.is_absolute()||program.executable.wstring().starts_with(L"\\\\")||!GetBinaryTypeW(program.executable.c_str(),&binary)||(binary!=SCS_32BIT_BINARY&&binary!=SCS_64BIT_BINARY)) throw std::invalid_argument("Select the provider's native Windows executable before managing its profile");
    }
    static Run run(const ProviderAccountProgram& program,const std::vector<std::wstring>& arguments,const std::filesystem::path& profile,
            const WindowsProcess::Environment& environment,const Cancel& cancel,std::chrono::milliseconds timeout,const VerificationURL& callback={}) {
        if(cancel&&cancel->load()) throw std::runtime_error("Provider account operation cancelled");
        auto args=program.command_prefix; args.insert(args.end(),arguments.begin(),arguments.end());
        std::mutex mutex; std::string output; auto process=WindowsProcess::start_bytes(program.executable,args,profile,[&](std::string_view bytes){std::lock_guard lock(mutex);output.append(bytes);},1024*1024,environment,true);
        process->close_input(); const auto deadline=std::chrono::steady_clock::now()+timeout; std::set<std::string> delivered;
        const auto links=[&] {
            if(!callback) return; std::string snapshot; {std::lock_guard lock(mutex);snapshot=output;}
            std::size_t at{}; while((at=snapshot.find("https://",at))!=std::string::npos) {
                auto end=snapshot.find_first_of("\r\n\t \"'<>\x1b",at); if(end==std::string::npos) break;
                auto link=snapshot.substr(at,end-at); while(!link.empty()&&(link.back()==')'||link.back()==']'||link.back()=='.'||link.back()==','))link.pop_back();
                if(verification_url_allowed(program.provider,link)&&delivered.insert(link).second) callback(link); at=end;
            }
        };
        for(;;) {
            if(cancel&&cancel->load()) {process->stop();throw std::runtime_error("Provider account operation cancelled");}
            if(std::chrono::steady_clock::now()>=deadline) {process->stop();throw std::runtime_error("The provider account operation timed out");}
            const auto completed=process->wait(std::chrono::milliseconds(25)); links();
            if(completed) {
                if(completed->stdout_truncated||!completed->channel_error.empty()) throw std::runtime_error("The provider account response exceeded its limits");
                std::lock_guard lock(mutex); if(!ACPFileSystem::valid_utf8(output)) throw std::runtime_error("The provider account response was not UTF-8"); return {completed->status,std::move(output)};
            }
        }
    }
    static bool safe_identity(const std::string& value) {return ACPFileSystem::valid_utf8(value)&&std::none_of(value.begin(),value.end(),[](unsigned char ch){return ch<32||ch==127;});}
    static std::string scalar(const ACPProtocol::Object& value,const wchar_t* key) {
        const auto field=value.GetNamedValue(key,ACPProtocol::Json::CreateNullValue());
        if(field.ValueType()==rpc_json::JsonValueType::String) {const auto result=winrt::to_string(field.GetString());return result.size()<=256&&safe_identity(result)?result:"";}
        if(field.ValueType()==rpc_json::JsonValueType::Number) return winrt::to_string(field.Stringify()); return {};
    }
    static std::string pin_profile_name(const std::filesystem::path& profile) {
        ACPFileSystem pin(profile); auto path=pin.root().wstring(); std::transform(path.begin(),path.end(),path.begin(),[](wchar_t ch){return static_cast<wchar_t>(std::towlower(ch));}); return winrt::to_string(path);
    }
    static std::string version_label(const std::string& output) {
        if(!ACPFileSystem::valid_utf8(output)) return {}; std::smatch match;
        return std::regex_search(output,match,std::regex("[vV]?[0-9]{1,4}\\.[0-9]{1,3}\\.[0-9]{1,3}([-+][A-Za-z0-9.]{1,40})?"))?match.str():"";
    }
    static std::string utc_now() {SYSTEMTIME time{};GetSystemTime(&time);char bytes[32]{};snprintf(bytes,sizeof(bytes),"%04u-%02u-%02uT%02u:%02u:%02uZ",time.wYear,time.wMonth,time.wDay,time.wHour,time.wMinute,time.wSecond);return bytes;}
};
} // namespace coincide
