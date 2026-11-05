#pragma once
#include "AgentSession.h"
#include "AgentAccountScope.h"
#include "ACPFileSystem.h"

namespace coincide {
// One worker keeps this binding for its whole queue/runtime lifetime. A different account is
// rejected, never adopted into an existing native conversation or already queued user input.
class AgentAccountBinding {
public:
    AgentAccountBinding(const AgentLaunch& launch,std::string provider):launch_(launch),provider_(std::move(provider)),saved_session_(!launch.session_id.empty()){}
    bool fixture() const {
        if(!launch_.fixture_account_reviewed||launch_.arguments.size()!=2||launch_.arguments.front()!=
                (provider_=="codex"?L"--codex-session-fixture":L"--claude-session-fixture"))return false;
        wchar_t executable[32768]{};const auto count=GetModuleFileNameW(nullptr,executable,32768);if(!count||count>=32768)return false;
        std::error_code error;return std::filesystem::equivalent(launch_.executable,std::filesystem::path(executable),error)&&!error;
    }
    bool fixture_arguments() const {
        return launch_.arguments.size()==2&&(launch_.arguments.front()==L"--codex-session-fixture"||launch_.arguments.front()==L"--claude-session-fixture");
    }
    const std::filesystem::path& profile() {
        if(!valid_profile_id(launch_.profile_id)||(!launch_.saved_profile_id.empty()&&!valid_profile_id(launch_.saved_profile_id))||(!launch_.saved_account_scope.empty()&&(launch_.saved_account_scope.size()!=64||launch_.saved_account_scope.find_first_not_of("0123456789abcdef")!=std::string::npos)))throw RpcError("Select a valid provider profile and saved account binding before continuing");
        if(launch_.profile_id!="default"&&launch_.profile_directory.empty())throw RpcError("A separate provider account requires its explicit private profile folder; the global login was not used.");
        if(profile_.empty()) {
            if(!launch_.profile_directory.empty())profile_=launch_.profile_directory;
            else if(fixture())profile_=launch_.cwd;
            else {
                const auto home=environment_value(provider_=="codex"?L"CODEX_HOME":L"CLAUDE_CONFIG_DIR");
                if(!home.empty())profile_=home;
                else {const auto user=environment_value(L"USERPROFILE");if(user.empty())throw RpcError("The current Windows provider profile could not be located");profile_=std::filesystem::path(user)/(provider_=="codex"?L".codex":L".claude");}
            }
        }
        if(!profile_.is_absolute()||profile_.wstring().starts_with(L"\\\\"))throw RpcError("Provider profiles require an absolute local Windows folder");
        if(!profile_pin_&&std::filesystem::exists(profile_)){profile_pin_=std::make_unique<ACPFileSystem>(profile_);profile_=profile_pin_->root();}return profile_;
    }
    WindowsProcess::Environment environment() {
        if(fixture_arguments()&&!fixture())throw RpcError("Synthetic provider sessions require explicit fixture account review and the current test executable");
        WindowsProcess::Environment result{{provider_=="codex"?L"CODEX_HOME":L"CLAUDE_CONFIG_DIR",profile().wstring()}};
        if(provider_=="claude")for(const auto* name:{L"CLAUDECODE",L"CLAUDE_CODE_ENTRYPOINT",L"CLAUDE_CODE_SESSION_ID",L"CLAUDE_CODE_CHILD_SESSION",L"CLAUDE_CODE_BRIDGE_SESSION_ID",L"CLAUDE_CODE_MESSAGING_SOCKET",L"CLAUDE_CODE_MESSAGING_TOKEN",L"CLAUDE_CODE_SESSION_ATTENDED",L"CLAUDE_CODE_EXECPATH",L"CLAUDE_PID"})result.emplace_back(name,std::nullopt);
        if(!launch_.profile_directory.empty()&&launch_.profile_id!="default") {
            if(provider_=="codex")for(const auto* name:{L"OPENAI_API_KEY",L"CODEX_API_KEY",L"OPENAI_BASE_URL"})result.emplace_back(name,std::nullopt);
            else for(const auto* name:{L"ANTHROPIC_API_KEY",L"ANTHROPIC_AUTH_TOKEN",L"CLAUDE_CODE_OAUTH_TOKEN",L"ANTHROPIC_BASE_URL",L"CLAUDE_CODE_USE_BEDROCK",L"CLAUDE_CODE_USE_VERTEX",L"CLAUDE_CODE_USE_FOUNDRY"})result.emplace_back(name,std::nullopt);
        }
        return result;
    }
    bool accept(std::string subject,const std::string& source,const std::string& label={}) {
        if(subject.empty()&&fixture())subject="synthetic-reviewed-fixture";
        if(subject.empty()||subject.size()>1024||!ACPFileSystem::valid_utf8(subject)||std::any_of(subject.begin(),subject.end(),[](unsigned char ch){return ch<32||ch==127;}))
            throw RpcError("The provider could not verify a nonsecret account identity. Review its account before starting or resuming a conversation.");
        ACPFileSystem pin(profile());auto path=pin.root().wstring();std::transform(path.begin(),path.end(),path.begin(),[](wchar_t ch){return static_cast<wchar_t>(std::towlower(ch));});
        const auto current=AgentAccountScope::fingerprint(provider_,subject,winrt::to_string(path));
        if(!launch_.saved_profile_id.empty()&&launch_.saved_profile_id!=launch_.profile_id)throw RpcError("This saved conversation belongs to another provider profile; select its original profile.");
        if(saved_session_&&(launch_.saved_profile_id.empty()||launch_.saved_account_scope.empty())&&!fixture())throw RpcError("This saved conversation has no verified account binding. Its original account needs explicit owner review before it can resume.");
        if(!launch_.saved_account_scope.empty()&&launch_.saved_account_scope!=current)throw RpcError("This saved conversation belongs to another provider account; select that account or start a new conversation.");
        if(!scope_.empty()&&scope_!=current)throw RpcError("The provider account changed. Queued inputs were paused to preserve their original account and conversation.");
        const bool first=scope_.empty();scope_=current;source_=source;label_=label;revision_=credential_revision();return first;
    }
    const std::string& scope()const{return scope_;}
    const std::string& profile_id()const{return launch_.profile_id;}
    std::string detail()const {
        rpc_json::JsonObject value;CodexProtocol::text(value,L"provider",provider_);CodexProtocol::text(value,L"identity_source",source_);CodexProtocol::text(value,L"label",label_);return winrt::to_string(value.Stringify());
    }
    bool credentials_changed(){return !scope_.empty()&&credential_revision()!=revision_;}
    std::string credential_revision() {
        if(fixture())return "fixture";
        std::string result;const auto root=profile();
        for(const auto* name:provider_=="codex"?std::vector<const wchar_t*>{L"auth.json"}:std::vector<const wchar_t*>{L".credentials.json"}) {
            const auto path=root/name;const auto attributes=GetFileAttributesW(path.c_str());if(attributes==INVALID_FILE_ATTRIBUTES){result+="missing;";continue;}
            NativeHandle file(CreateFileW(path.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));BY_HANDLE_FILE_INFORMATION info{};
            if(file.get()==INVALID_HANDLE_VALUE||!GetFileInformationByHandle(file.get(),&info)||(info.dwFileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY))||info.nNumberOfLinks!=1)throw RpcError("The provider credential file is linked or unavailable; verify its profile again.");
            result+=std::to_string(info.dwVolumeSerialNumber)+":"+std::to_string(info.nFileIndexHigh)+":"+std::to_string(info.nFileIndexLow)+":"+std::to_string(info.nFileSizeHigh)+":"+std::to_string(info.nFileSizeLow)+":"+std::to_string(info.ftLastWriteTime.dwHighDateTime)+":"+std::to_string(info.ftLastWriteTime.dwLowDateTime)+";";
        }
        return result;
    }
    static std::string codex_subject(const rpc_json::JsonObject& response) {
        const auto account=response.GetNamedValue(L"account",rpc_json::JsonValue::CreateNullValue());if(account.ValueType()!=rpc_json::JsonValueType::Object)return{};
        const auto value=account.GetObject();if(CodexProtocol::string(value,L"type")!="chatgpt")return{};return CodexProtocol::string(value,L"email");
    }
    static std::string claude_subject(const rpc_json::JsonObject& status) {
        if(!status.GetNamedBoolean(L"loggedIn",false))return{};const auto method=CodexProtocol::string(status,L"authMethod"),provider=CodexProtocol::string(status,L"apiProvider");
        if((method!="claude.ai"&&method!="oauth_token")||(!provider.empty()&&provider!="firstParty"))return{};
        const auto email=CodexProtocol::string(status,L"email");if(email.empty())return{};const auto organization=CodexProtocol::string(status,L"orgId");return std::to_string(email.size())+":"+email+std::to_string(organization.size())+":"+organization;
    }
private:
    const AgentLaunch& launch_;std::string provider_;bool saved_session_{};std::filesystem::path profile_;std::unique_ptr<ACPFileSystem> profile_pin_;std::string scope_,source_,label_,revision_;
    static bool valid_profile_id(const std::string& value) {
        if(value=="default")return true;if(value.size()!=36)return false;
        for(std::size_t i=0;i<value.size();++i){const auto ch=value[i];if(i==8||i==13||i==18||i==23){if(ch!='-')return false;}else if(!((ch>='0'&&ch<='9')||(ch>='a'&&ch<='f')||(ch>='A'&&ch<='F')))return false;}return value!="00000000-0000-0000-0000-000000000000";
    }
    static std::wstring environment_value(const wchar_t* name){const auto count=GetEnvironmentVariableW(name,nullptr,0);if(!count||count>32768)return{};std::wstring value(count,L'\0');const auto copied=GetEnvironmentVariableW(name,value.data(),count);if(!copied||copied>=count)return{};value.resize(copied);return value;}
};
} // namespace coincide
