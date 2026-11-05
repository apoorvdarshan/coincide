#pragma once
#include "../Runtime/ProviderAccounts.h"
#include "ProcessTests.h"
#include <fstream>
#include <future>

namespace coincide {
// This child is the entire account fixture: no installed CLI, credentials or network is used.
inline int provider_account_fixture(int argc,wchar_t** argv) {
    if(argc<5)return 2;const std::wstring mode=argv[2],provider=argv[3],command=argv[4];
    const auto env=[](const wchar_t* key){wchar_t value[32768]{};const auto size=GetEnvironmentVariableW(key,value,32768);return size&&size<32768?std::wstring(value,size):std::wstring{};};
    const auto output=[](const std::string& bytes){fixture_write(GetStdHandle(STD_OUTPUT_HANDLE),bytes);};
    const auto profile=std::filesystem::current_path();
    if(env(L"APPDATA")!=profile.wstring()||env(L"NO_OPEN_BROWSER")!=L"1"||!env(L"CURSOR_API_KEY").empty()||!env(L"XAI_API_KEY").empty()||!env(L"NODE_OPTIONS").empty())return 3;
    if(provider==L"cursor"&&(env(L"CURSOR_CONFIG_DIR")!=profile.wstring()||env(L"CURSOR_DATA_DIR")!=profile.wstring()||env(L"AGENT_CLI_CREDENTIAL_STORE")!=L"file"))return 4;
    if(provider==L"grok"&&(env(L"GROK_HOME")!=profile.wstring()||env(L"GROK_DISABLE_AUTOUPDATER")!=L"1"))return 5;
    std::ofstream(profile/L"fixture-invocations",std::ios::app)<<winrt::to_string(command)<<'\n';
    if(command==L"--version"){output("Fixture 2026.10.22-abcdef\n");return 0;}
    if(command==L"login") {
        if(provider==L"grok"&&(argc!=6||std::wstring_view(argv[5])!=L"--device-auth"))return 6;
        if(provider==L"cursor"&&argc!=5)return 6;
        output("Sign-in link: https://");Sleep(10);output(provider==L"cursor"?"cursor.com/login?state=fixture\n":"auth.x.ai/activate?user_code=fixture\n");
        output("https://cursor.com/login?access_token=fixture-secret\nhttps://evil.example/login\nhttps://cursor.com.evil.example/\n");
        if(mode==L"wait"){Sleep(30000);return 1;}
        if(mode==L"failure")return 7;
        const auto credentials=ProviderAccounts::credential_path(profile,winrt::to_string(provider));std::filesystem::create_directories(credentials.parent_path());
        std::ofstream(credentials)<<R"({"accessToken":"synthetic-secret-never-returned","refreshToken":"synthetic-refresh"})";return 0;
    }
    if(command==L"status") {
        if(provider!=L"cursor"||argc!=7||std::wstring_view(argv[5])!=L"--format"||std::wstring_view(argv[6])!=L"json")return 8;
        if(mode==L"wait-status"){Sleep(30000);return 1;}
        if(mode==L"flood"){for(unsigned i=0;i<300;++i)output(std::string(8192,'x'));return 1;}
        if(mode==L"changes")std::ofstream(profile/L"Cursor/auth.json",std::ios::app)<<'x';
        if(!std::filesystem::exists(profile/L"Cursor/auth.json")){output(R"({"status":"unauthenticated","isAuthenticated":false})");return 0;}
        if(mode==L"offline"){output(R"({"status":"authenticated","isAuthenticated":true,"message":"unable to fetch user details"})");return 0;}
        if(mode==L"malformed"){output("secret-diagnostic-not-a-status\n");return 0;}
        if(mode==L"other"){output(R"({"status":"authenticated","isAuthenticated":true,"userInfo":{"userId":2,"email":"other@example.invalid","teamId":7}})");return 0;}
        if(mode==L"other-team"){output(R"({"status":"authenticated","isAuthenticated":true,"userInfo":{"userId":1,"email":"fixture@example.invalid","teamId":8}})");return 0;}
        output(R"({"status":"authenticated","isAuthenticated":true,"userInfo":{"userId":1,"email":"fixture@example.invalid","teamId":7}})");return 0;
    }
    return 9;
}

inline int provider_accounts_tests(const std::filesystem::path& report) {
    using namespace std::chrono_literals;
    int checks{};const auto check=[&](bool value,const char* message){++checks;if(!value)throw std::runtime_error(message);};
    const auto rejects=[&](const auto& action,const char* message){bool rejected{};try{action();}catch(const std::exception&){rejected=true;}catch(const winrt::hresult_error&){rejected=true;}check(rejected,message);};
    wchar_t executable_name[32768]{};GetModuleFileNameW(nullptr,executable_name,32768);
    GUID id{};CoCreateGuid(&id);wchar_t unique[40]{};StringFromGUID2(id,unique,40);const auto folder=std::filesystem::temp_directory_path()/(L"coincide-account-test-"+std::wstring(unique));
    struct Cleanup {std::filesystem::path path;~Cleanup(){std::error_code ignored;std::filesystem::remove_all(path,ignored);}} cleanup{folder};
    try {
        const auto program=[&](const std::string& provider,const std::wstring& mode=L"normal"){return ProviderAccountProgram{provider,executable_name,{L"--provider-account-fixture",mode,ACPFileSystem::wide(provider)}};};
        ProviderAccountStore store(folder/L"profiles");check(store.open().empty()&&!std::filesystem::exists(store.root()),"Opening empty account metadata must not create a profile or start a process");
        auto cursor=store.create("cursor","Work Cursor");const auto profile=store.profile(cursor);check(std::filesystem::is_directory(profile),"An explicit Add must create an app-owned profile");
        PSECURITY_DESCRIPTOR security{};if(GetNamedSecurityInfoW(const_cast<wchar_t*>(profile.c_str()),SE_FILE_OBJECT,DACL_SECURITY_INFORMATION,nullptr,nullptr,nullptr,nullptr,&security)!=ERROR_SUCCESS)throw std::runtime_error("Could not read fixture profile security");
        SECURITY_DESCRIPTOR_CONTROL control{};DWORD revision{};const bool protected_dacl=GetSecurityDescriptorControl(security,&control,&revision)&&(control&SE_DACL_PROTECTED);LocalFree(security);check(protected_dacl,"New credential profiles must use a protected Windows DACL");
        store.save({cursor});ProviderAccountStore reopened(store.root());const auto loaded=reopened.open();check(loaded.size()==1&&loaded[0].id==cursor.id&&loaded[0].last_scope.empty(),"Profile metadata must round-trip without treating a profile as signed in");
        rejects([&]{auto bad=cursor;bad.id="../escape";store.profile(bad);},"Profile IDs must not be filesystem paths");
        rejects([&]{auto bad=cursor;bad.identity_source="token=unsafe";store.save({bad});},"Identity provenance must be a recognized nonsecret metadata source");
        rejects([&]{auto bad=cursor;bad.last_scope="not-a-fingerprint";store.save({bad});},"Account scope metadata must be a bounded SHA-256 fingerprint");
        const auto parent_value=[](const wchar_t* key){wchar_t value[32768]{};auto count=GetEnvironmentVariableW(key,value,32768);return count&&count<32768?std::optional<std::wstring>(std::wstring(value,count)):std::nullopt;};
        struct ParentEnv {std::vector<std::pair<std::wstring,std::optional<std::wstring>>> values;~ParentEnv(){for(const auto& [key,value]:values)SetEnvironmentVariableW(key.c_str(),value?value->c_str():nullptr);}} original;
        for(const auto* key:{L"APPDATA",L"CURSOR_API_KEY",L"XAI_API_KEY",L"NODE_OPTIONS"}){original.values.emplace_back(key,parent_value(key));SetEnvironmentVariableW(key,L"synthetic-parent-sentinel");}
        auto metadata=ProviderAccounts::check(program("cursor"),cursor,profile);check(metadata.state==ProviderAccountState::signed_out&&metadata.scope.empty()&&metadata.version=="2026.10.22-abcdef","Missing credentials must stay signed out after bounded native metadata checks");
        check(parent_value(L"APPDATA")==std::optional<std::wstring>(L"synthetic-parent-sentinel")&&parent_value(L"CURSOR_API_KEY")==std::optional<std::wstring>(L"synthetic-parent-sentinel"),"Private metadata processes must not mutate or consume the parent's credential environment");
        std::vector<std::string> links;const auto cancel=std::make_shared<std::atomic_bool>(false);
        metadata=ProviderAccounts::sign_in(program("cursor"),cursor,profile,cancel,[&](const std::string& url){links.push_back(url);});
        check(links==std::vector<std::string>{"https://cursor.com/login?state=fixture"},"Only official verification links without token parameters must reach the browser callback, including split output");
        check(metadata.state==ProviderAccountState::verified&&metadata.scope.size()==64&&metadata.label=="fixture@example.invalid"&&metadata.identity_source=="cursor-status-getMe","A successful server identity response must establish account-scoped routing");
        check(ProviderAccounts::current(metadata,cursor,profile)&&metadata.can_resume(metadata.scope)&&!metadata.can_resume(""),"A fresh verified account may resume only a saved matching nonempty scope");
        const auto scope=metadata.scope;const auto other=ProviderAccounts::check(program("cursor",L"other"),cursor,profile);const auto team=ProviderAccounts::check(program("cursor",L"other-team"),cursor,profile);
        check(other.scope!=scope&&!other.can_resume(scope)&&team.scope!=scope,"Another account or team must not resume the original account's session");
        const auto offline=ProviderAccounts::check(program("cursor",L"offline"),cursor,profile);check(offline.state==ProviderAccountState::signed_in_unverified&&offline.scope.empty()&&!ProviderAccounts::current(offline,cursor,profile),"Cached signed-in state without server user details must never authorize resume");
        const auto malformed=ProviderAccounts::check(program("cursor",L"malformed"),cursor,profile);check(malformed.state==ProviderAccountState::unknown&&malformed.status.find("secret-diagnostic")==std::string::npos,"Unexpected raw auth output must not reach persisted metadata or user-facing status");
        auto saved=cursor;saved.last_scope=metadata.scope;saved.identity_source=metadata.identity_source;saved.verified_at=metadata.verified_at;store.save({saved});ProviderAccountStore restored(store.root());const auto historical=restored.open();
        check(historical[0].last_scope==scope&&!ProviderAccounts::current(ProviderAccountMetadata{},historical[0],profile),"Reopened account records must retain history without trusting a previous verification as current");
        const auto bytes=ACPFileSystem(store.root()).read(winrt::to_string((store.root()/L"provider-accounts.json").wstring()));
        check(bytes.find("synthetic-secret")==std::string::npos&&bytes.find("accessToken")==std::string::npos&&bytes.find("fixture@example")==std::string::npos,"Account persistence must contain only labels, IDs, scope and provenance, never credential values or raw CLI output");
        auto cache=folder/L"cache";std::filesystem::create_directories(cache);ACPLaunchSpec native;native.provider="cursor";native.executable=executable_name;
        auto bound=ProviderAccounts::bind(native,cursor,profile,cache,metadata,scope,true);check(bound.options.account.current==scope&&bound.options.account.saved==scope,"Verified profile metadata must bind the runtime's current and saved account guards");
        rejects([&]{ProviderAccounts::bind(native,cursor,profile,cache,metadata,other.scope,true);},"Mismatched saved account scope must fail before starting a provider process");
        rejects([&]{ProviderAccounts::bind(native,cursor,profile,cache,metadata,{},true);},"Legacy unscoped sessions require explicit account migration instead of automatic resume");
        auto wrong=native;wrong.provider="grok";rejects([&]{ProviderAccounts::bind(wrong,cursor,profile,cache,metadata);},"Verified account metadata must not be reused by another provider");
        std::ofstream(profile/L"Cursor/auth.json",std::ios::app)<<"changed";
        check(!ProviderAccounts::current(metadata,cursor,profile),"Credential refresh or replacement must invalidate the cached current account verification");
        const auto changing=ProviderAccounts::check(program("cursor",L"changes"),cursor,profile);check(changing.state==ProviderAccountState::unknown&&changing.scope.empty(),"Credentials changing during server verification must not bind the stale user identity to a new login");
        rejects([&]{ProviderAccounts::check(program("cursor",L"flood"),cursor,profile);},"Auth metadata output must be capped without exposing the captured bytes");
        auto grok=store.create("grok","Separate Grok");const auto grok_profile=store.profile(grok);auto grok_status=ProviderAccounts::check(program("grok"),grok,grok_profile);check(grok_status.state==ProviderAccountState::signed_out,"Grok metadata must not sign in implicitly");
        links.clear();grok_status=ProviderAccounts::sign_in(program("grok"),grok,grok_profile,cancel,[&](const std::string& url){links.push_back(url);});check(grok_status.state==ProviderAccountState::signed_in_unverified&&grok_status.scope.empty()&&links==std::vector<std::string>{"https://auth.x.ai/activate?user_code=fixture"},"Grok must use explicit device authentication and keep unverified cached identities locked");
        check(!ProviderAccounts::capabilities("antigravity").sign_in&&!ProviderAccounts::capabilities("antigravity").metadata&&!ProviderAccounts::capabilities("codex").sign_in,"Unvalidated provider authentication flows must stay unavailable");
        auto agy=store.create("antigravity","Disabled Antigravity");const auto agy_profile=store.profile(agy);rejects([&]{ProviderAccounts::sign_in(program("antigravity"),agy,agy_profile,cancel,{});},"Antigravity must fail before invoking its native executable without a validated risk/browser/identity flow");
        check(!std::filesystem::exists(agy_profile/L"fixture-invocations"),"Opening an unavailable account flow must never start the provider CLI");
        for(const auto* url:{"http://cursor.com/login","https://cursor.com.evil.example/login","https://user:pass@cursor.com/","https://cursor.com:444/login","https://cursor.com/login#access_token=unsafe","https://cursor.com/login?ACCESS_TOKEN=unsafe","https://cursor.com/login?%74oken=unsafe","https://cursor.com/login?api_key=unsafe"})check(!ProviderAccounts::verification_url_allowed("cursor",url),"Verification URL validation must reject insecure, lookalike, credential-bearing or token-bearing URLs");
        check(!ProviderAccounts::verification_url_allowed("grok","https://cursor.com/login")&&ProviderAccounts::verification_url_allowed("grok","https://auth.x.ai/activate?user_code=fixture"),"Verification links must remain owned by the selected provider");
        auto cancellation=std::make_shared<std::atomic_bool>(false);auto wait=std::async(std::launch::async,[&]{try{ProviderAccounts::sign_in(program("cursor",L"wait"),cursor,profile,cancellation,{});return false;}catch(...){return true;}});std::this_thread::sleep_for(100ms);cancellation->store(true);
        check(wait.wait_for(3s)==std::future_status::ready&&wait.get(),"Cancel must terminate only the account operation's owned native Job promptly");
        check(ProviderAccounts::check(program("cursor"),cursor,profile).state==ProviderAccountState::verified,"Cancelling one operation must leave a sibling/new profile check usable");
        auto plain_worker=std::async(std::launch::async,[&]{return ProviderAccounts::check(program("cursor"),cursor,profile);});check(plain_worker.get().state==ProviderAccountState::verified,"Account metadata must initialize a plain worker's WinRT apartment without changing a caller's STA");
        const auto stale_records=loaded;rejects([&]{reopened.save(stale_records);},"Concurrent account edits must be detected instead of overwriting another window's metadata");
        std::ofstream output(report);output<<"PASS: "<<checks<<" provider account contract checks\n";return output?0:2;
    }catch(const winrt::hresult_error& error){std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<winrt::to_string(error.message())<<'\n';}
     catch(const std::exception& error){std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';}
    return 1;
}
} // namespace coincide
