#pragma once
#include "../Runtime/NativeHostResolver.h"
#include "../Runtime/NativeBackgroundHost.h"
#include "../Runtime/HostIPC.h"
#include <fstream>

namespace coincide {
namespace native_host_entry_fixture {
class Session final:public AgentSession {
public:
    bool send(CodexTurn)override{return false;}bool busy()const noexcept override{return false;}void interrupt()noexcept override{}
    bool refresh_models()override{return false;}bool queue(CodexTurn,std::string)override{return false;}
    std::vector<AgentQueuedTurn> queued()const override{return{};}std::size_t queued_count()const override{return 0;}
    bool queue_paused()const override{return true;}bool remove_queued(const std::string&)override{return false;}
    bool resume_queue()override{return false;}bool steer(CodexTurn,std::string)override{return false;}
    void respond(std::string,std::string)override{}std::vector<SessionEvent> take_events()override{return{};}
    void close()noexcept override{}void shutdown()noexcept override{}
};
}
inline int native_background_host_tests(const std::filesystem::path& report){
    using namespace background_host;unsigned checks{};bool owned{};
    const auto root=std::filesystem::temp_directory_path()/(L"Coincide-Native-Host-Resolver-"+std::wstring(winrt::to_hstring(new_guid())));
    struct Cleanup {std::filesystem::path path;bool& owned;~Cleanup(){if(owned){std::error_code error;std::filesystem::remove_all(path,error);}}}cleanup{root,owned};
    const auto check=[&](bool value,const char* message){++checks;if(!value)throw std::runtime_error(message);};
    const auto rejects=[&](auto action,const char* message){bool rejected{};try{action();}catch(...){rejected=true;}check(rejected,message);};
    try{
        if(!std::filesystem::create_directory(root))throw std::runtime_error("The owned resolver fixture could not be created");owned=true;
        const auto data=root/L"data",project=root/L"project";std::filesystem::create_directory(data);std::filesystem::create_directory(project);
        const auto executable=root/L"provider.exe",other=root/L"other.exe";std::filesystem::copy_file(current_image(),executable);std::filesystem::copy_file(current_image(),other);
        auto scope=std::make_shared<Scope>(data);Preferences prefs;std::vector<ProviderAccountRecord> records;unsigned loaded{},profiles{},discovered{},inspected{};
        auto selected=executable;NativeHostResolverServices services;
        services.preferences=[&]{++loaded;return prefs;};services.profiles=[&]{++profiles;return records;};
        services.discover=[&](const auto& provider){++discovered;check(provider=="codex"||provider=="claude"||provider=="cursor","File discovery must retain the requested provider");return selected;};
        services.inspect=[&](const auto& provider,const auto& path){++inspected;check(provider=="cursor"&&path==selected,"Cursor inspection must use trusted selected metadata");return ACPLaunchSpec{provider,path,{},{},{}};};
        {
            NativeHostResolver resolver(scope,services);
            check(loaded==0&&profiles==0&&discovered==0&&inspected==0,"Construction must not read metadata, discover programs, query an account or start a process");
            check(!std::filesystem::exists(scope->ledger_directory()),"Construction must not create a cache or runtime ledger");
            const auto first=resolver("codex","default");check(first.provider=="codex"&&first.profile_id=="default"&&first.executable==executable&&first.profile_directory.empty()&&!first.cursor,"Default Codex must resolve without a guessed named account");
            check(loaded==1&&profiles==0&&inspected==0,"A default native provider must not inspect account records or ACP packages");
            prefs.providers.at("codex").executable=winrt::to_string(other.wstring());const auto scans=discovered;
            check(resolver("codex","default").executable==other&&discovered==scans,"Fresh settings overrides must supersede discovery on the next Start");
            prefs.default_provider="claude";prefs.providers.at("codex").enabled=false;
            rejects([&]{resolver("codex","default");},"Disabling a provider must immediately refuse a new hosted Start");
            prefs.providers.at("codex").enabled=true;prefs.providers.at("codex").executable.clear();
            check(resolver("claude","default").provider=="claude","Claude default metadata must remain supported");
            const auto previous=loaded;
            for(const auto* provider:{"opencode","grok","antigravity","unknown"})rejects([&]{resolver(provider,"default");},"Providers without verified account continuity must stay unavailable");
            for(const auto* profile:{"","bad","{198ac3fd-4113-463f-8061-e692c31340c6}","00000000-0000-0000-0000-000000000000","198ac3fd-4113-463f-8061-e692c31340c6"})rejects([&]{resolver("codex",profile);},"Codex cannot fall back from an unsupported named or malformed profile");
            rejects([&]{resolver("cursor","default");},"Cursor requires an existing separate profile, never the global default");
            check(loaded==previous,"Invalid provider/profile selections must fail before any metadata read");
            const auto profile_id=std::string("198AC3FD-4113-463F-8061-E692C31340C6");
            prefs.providers.at("cursor").profile_id="11111111-1111-4111-8111-111111111111";
            const auto profile_root=data/L"provider-profiles";std::filesystem::create_directory(profile_root);
            ProviderAccountStore store(profile_root);store.open();auto record=store.create("cursor","Synthetic original profile");record.id=profile_id;
            // Move only the fixture's empty app-owned folder to a deterministic profile ID.
            const auto created=std::filesystem::directory_iterator(profile_root/L"cursor")->path();
            std::filesystem::rename(created,profile_root/L"cursor"/winrt::to_hstring(profile_id).c_str());
            record.last_scope=std::string(64,'a');record.identity_source="cursor-status-getMe";record.verified_at="2026-11-05T00:00:00Z";records={record};
            const auto cursor=resolver("cursor",profile_id);
            check(cursor.profile_id==profile_id&&cursor.profile_directory==store.profile(record)&&cursor.cursor&&cursor.cursor->record.id==profile_id,"An existing conversation must retain its exact profile despite a changed Settings default");
            check(profiles==1&&inspected==1&&std::filesystem::is_directory(cursor.cursor->cache),"Explicit Cursor Start may prepare its bounded private compilation cache");
            check(cursor.cursor->cache.parent_path()==scope->ledger_directory(),"Hosted Cursor cache must stay in the private runtime tree, separate from credentials");
            records.clear();rejects([&]{resolver("cursor",profile_id);},"Removing a profile record must refuse before a new session can fall back to global credentials");
            records={record};records.front().provider="claude";rejects([&]{resolver("cursor",profile_id);},"A profile for another provider cannot authorize Cursor");
            records={record};records.front().last_scope.clear();rejects([&]{resolver("cursor",profile_id);},"A never-verified profile cannot authorize hosting");
            records={record};records.front().verified_at.clear();rejects([&]{resolver("cursor",profile_id);},"Missing identity verification metadata requires owner review");
            records={record};records.front().identity_source.clear();rejects([&]{resolver("cursor",profile_id);},"Cached credentials without the official verified identity source cannot authorize hosting");
            records={record,record};std::transform(records.back().id.begin(),records.back().id.end(),records.back().id.begin(),[](char c){return c>='A'&&c<='Z'?static_cast<char>(c+('a'-'A')):c;});
            rejects([&]{resolver("cursor",profile_id);},"Case-variant repeated UUID profiles must fail before account selection");records={record};
            auto broken=services;broken.inspect=[](const auto&,const auto& path){return ACPLaunchSpec{"grok",path,{},{},{}};};NativeHostResolver wrong(scope,broken);
            rejects([&]{wrong("cursor",profile_id);},"A package inspection cannot change the requested provider");
            selected=root/L"missing.exe";rejects([&]{resolver("codex","default");},"A missing discovery result cannot become a hosted program");
            selected=std::filesystem::path(executable.wstring()+L":stream");rejects([&]{resolver("codex","default");},"Alternate-stream discovery results must be denied");
            selected=executable;std::ofstream(root/L"wrapper.cmd")<<"@echo synthetic fixture only\n";selected=root/L"wrapper.cmd";
            rejects([&]{resolver("codex","default");},"Shell wrappers are not native hosted provider executables");selected=executable;
        }
        {
            // Exercise actual bounded JSON metadata readers only in the owned fixture.
            PreferencesStore settings(data);auto persisted=settings.open();persisted.providers.at("codex").executable=winrt::to_string(executable.wstring());settings.save(persisted);
            NativeHostResolver actual(scope);check(actual("codex","default").executable==executable,"The production resolver must read only the scoped persisted settings");
            persisted.providers.at("codex").executable=winrt::to_string(other.wstring());settings.save(persisted);
            check(actual("codex","default").executable==other,"A resolver cannot cache stale provider paths across Starts");
            const auto metadata=data/L"settings.json",saved=data/L"settings.saved";std::filesystem::rename(metadata,saved);
            std::ofstream(metadata)<<"{malformed synthetic settings";rejects([&]{actual("codex","default");},"Malformed persisted settings must never silently use discovery/defaults");std::filesystem::remove(metadata);
            check(CreateHardLinkW(metadata.c_str(),saved.c_str(),nullptr)!=FALSE,"Owned settings hardlink setup must succeed");
            rejects([&]{actual("codex","default");},"Hardlinked settings metadata must not escape the data-folder trust boundary");std::filesystem::remove(metadata);std::filesystem::rename(saved,metadata);
            const auto profile_root=data/L"provider-profiles";ProviderAccountStore store(profile_root);store.open();store.save(records);
            auto persisted_cursor=PreferencesStore(data).open();persisted_cursor.providers.at("cursor").executable=winrt::to_string(executable.wstring());PreferencesStore cursor_settings(data);cursor_settings.open();cursor_settings.save(persisted_cursor);
            // The synthetic executable has no recognized Cursor filename/package. This
            // rejects before account metadata probes or any process construction.
            rejects([&]{actual("cursor",records.front().id);},"An unrecognized native Cursor installation must remain unavailable");
            check(!std::filesystem::exists(data/L"threads")&&!std::filesystem::exists(data/L"index.json"),"Resolver validation must not write workspace transcripts or index data");
        }
        {
            unsigned resolved{},made{};auto resolver=std::make_shared<NativeHostResolver>(scope);
            NativeHostFactoryOptions options;options.scope=scope;
            options.resolve=[&](const auto& provider,const auto& profile){++resolved;return(*resolver)(provider,profile);};
            options.make=[&](const auto&,auto launch,auto acp){++made;check(!launch.fixture_account_reviewed&&!acp,"Synthetic make injection must not enable a production account bypass");return std::make_unique<native_host_entry_fixture::Session>();};
            NativeHostFactory factory(options);Core core(scope,[factory](const auto& key,const auto& launch){return factory(key,launch);});Server server(core,scope);
            Command list;check(core.perform(list).GetNamedArray(L"sessions").Size()==0&&resolved==0&&made==0,"Real Core/Server setup and readiness list must not resolve metadata or create any provider");
            Command start;start.operation=Operation::start;start.key={new_guid(),"codex"};start.epoch=new_guid();start.launch.executable=other;start.launch.cwd=project;start.launch.arguments={L"app-server"};
            check(text(core.perform(start),L"status",32)=="accepted"&&resolved==1&&made==1,"An explicit validated Start must pass fresh resolution into the injected session factory");
            Command stop;stop.operation=Operation::shutdown;stop.key=start.key;stop.epoch=start.epoch;
            check(text(core.perform(stop),L"status",32)=="accepted","Explicit scoped shutdown must settle the synthetic generation");
            PreferencesStore settings(data);auto fresh=settings.open();fresh.default_provider="claude";fresh.providers.at("codex").enabled=false;settings.save(fresh);
            start.id=new_guid();start.epoch=new_guid();const auto refused=core.perform(start);
            check(text(refused,L"status",32)=="uncertain"&&resolved==2&&made==1,"A changed disabled setting must prevent the next generation from reaching a provider, even inside the composed host");
            check(core.blocked(),"A refused/uncertain explicit generation must remain reviewable rather than silently replaying");
        }
        check(run_native_background_host({})==2,"The shallow entrypoint must reject an empty scope before constructing a host or provider");
        check(run_native_background_host(L"relative-data")==2,"The shallow entrypoint must refuse relative data roots without filesystem writes");
        check(run_native_background_host(root/L"missing-data")==2,"The shallow entrypoint must not create a missing data root");
        int sta_exit{};std::thread sta([&]{winrt::init_apartment(winrt::apartment_type::single_threaded);sta_exit=run_native_background_host(data);winrt::uninit_apartment();});sta.join();
        check(sta_exit==2,"The shallow entrypoint must refuse a UI STA before constructing a host");
        check(true,"All provider/account seams were synthetic; no production host, auth probe, CLI, vault, model or network call was performed");
        std::ofstream(report)<<"PASS: "<<checks<<" native background-host resolver/entry checks (owned synthetic metadata only)\n";return 0;
    }catch(const winrt::hresult_error& error){std::ofstream(report)<<"FAIL after "<<checks<<": "<<winrt::to_string(error.message())<<'\n';}
    catch(const std::exception& error){std::ofstream(report)<<"FAIL after "<<checks<<": "<<error.what()<<'\n';}return 1;
}
} // namespace coincide
