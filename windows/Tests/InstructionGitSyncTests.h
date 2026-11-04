#pragma once
#include "../Runtime/InstructionGitSync.h"
#include <fstream>

namespace coincide {
inline int instruction_git_sync_tests(const std::filesystem::path& report){
    namespace git=instruction_git;unsigned checks{};bool owned{};
    const auto root=std::filesystem::temp_directory_path()/(L"Coincide-Instruction-Git-"+git::wide(background_host::new_guid()));
    struct Cleanup{std::filesystem::path path;bool& owned;~Cleanup(){if(owned){std::error_code error;std::filesystem::remove_all(path,error);}}}cleanup{root,owned};
    const auto check=[&](bool result,const char* message){++checks;if(!result)throw std::runtime_error(message);};const auto rejects=[&](auto action,const char* message){bool rejected{};try{action();}catch(...){rejected=true;}check(rejected,message);};
    try{
        if(!std::filesystem::create_directory(root))throw std::runtime_error("Owned instruction Git fixture setup unavailable");owned=true;
        check(git::copy_step({}, {}, {})==git::CopyStep::in_step,"Two absent copies need no overwrite");
        check(git::copy_step("source",{}, {})==git::CopyStep::update_copy,"A missing Git copy receives local instructions");
        check(git::copy_step({},"copy",{})==git::CopyStep::update_source,"A missing source requires explicit incoming review");
        check(git::copy_step("same","same",{})==git::CopyStep::in_step,"Identical copies are already synchronized");
        check(git::copy_step("new","old",local_file::sha256("old"))==git::CopyStep::update_copy,"Only local changes should update the Git copy");
        check(git::copy_step("old","new",local_file::sha256("old"))==git::CopyStep::update_source,"Only incoming changes need local-master approval");
        check(git::copy_step("local","incoming",local_file::sha256("old"))==git::CopyStep::conflict,"Two-sided changes must never pick a winner implicitly");
        check(!git::remote_address("https://user:password@example.invalid/repo.git")&&!git::remote_address("https://example.invalid/repo?token=secret")&&!git::remote_address("ext::malicious helper"),"Credential URLs, query strings and custom remote helpers must be refused");
        check(git::remote_address("https://github.com/fixture/instructions.git")&&git::remote_address("git@github.com:fixture/instructions.git"),"Ordinary noncredential HTTPS and Git SSH addresses remain supported");
        check(git::suspected_secret(std::string("sk-proj-")+std::string(32,'x'))&&!git::suspected_secret("Keep API keys and passwords out of instructions."),"Credential checks must detect secret-shaped material without flagging policy prose");
        check(!git::copy_name("NUL.md")&&!git::copy_name("../Global.md")&&!git::copy_name(".git")&&git::copy_name("Project.md"),"Copy paths must be ordinary bounded Markdown leaves, never device aliases or traversal");
        const auto source_dir=root/L"source",data=root/L"app-data",repo=root/L"repository",remote=root/L"remote.git";std::filesystem::create_directory(source_dir);
        const auto source=source_dir/L"AGENTS.md";std::ofstream(source,std::ios::binary)<<"Original synthetic instructions — 你好\n";
        auto file=InstructionService::project_files(source_dir).files.front();unsigned calls{},mutations{},private_calls{},pushes{};auto native=git::native_runner();
        git::Runner runner=[&](git::Command command,const auto& cancel){++calls;if(command.mutation)++mutations;
            if(command.tool==code_hosting::Tool::gh){++private_calls;check(false,"The ordinary fixture must never discover or call GitHub CLI");}
            if(std::find(command.arguments.begin(),command.arguments.end(),L"push")!=command.arguments.end())++pushes;
            command.isolated_fixture=true;command.arguments.insert(command.arguments.begin(),{L"-c",L"user.name=Coincide Synthetic Fixture",L"-c",L"user.email=fixture@example.invalid"});return native(command,cancel);
        };
        const auto run=[&](const std::filesystem::path& cwd,std::vector<std::wstring> args,std::string input={}){const auto result=runner({code_hosting::Tool::git,cwd,std::move(args),std::move(input),true,{}},{});if(result.status)throw std::runtime_error("An owned local Git fixture command failed");return git::trim(result.output);};
        git::Service service(data,runner);check(calls==0&&!std::filesystem::exists(data),"Service construction must not discover Git, contact remotes or write settings");
        check(service.bindings().empty()&&service.tick(60000).empty()&&calls==0,"Default-off automatic sync must stay inert without configured links");
        auto setup=service.setup(file,repo,"Global.md",git::SetupKind::local);check(!std::filesystem::exists(repo)&&calls==0,"Setup must present concrete review before creating any repository or copy");
        const auto original=local_file::read(source,1024).bytes;std::ofstream(source,std::ios::binary)<<"changed after review\n";
        rejects([&]{service.apply(setup);},"A changed source must reject reviewed setup before creating folders");check(!std::filesystem::exists(repo),"Stale setup must preserve the untouched destination");std::ofstream(source,std::ios::binary)<<original;
        setup=service.setup(file,repo,"Global.md",git::SetupKind::local);check(service.apply(setup).changed,"Explicit local setup should create and commit only the reviewed Git copy");
        const auto id=service.bindings().front().id;check(service.bindings().size()==1&&!service.bindings().front().automatic&&!service.bindings().front().push_automatically,"New instruction links must default to manual synchronization");
        check(local_file::read(source,1024).bytes==original&&local_file::read(repo/L"Global.md",1024).bytes==original,"Local setup must preserve the source and create an exact UTF-8 Git copy");
        check(run(repo,{L"log",L"-1",L"--format=",L"--name-only"})=="Global.md","The initial commit may contain only the instruction copy");
        check(service.status(id).step==git::CopyStep::in_step,"A newly committed equal copy must record the agreed digest");
        rejects([&]{service.apply(setup);},"A setup confirmation must be single-use");
        rejects([&]{service.attach(file,repo,"Global.md");},"Duplicate source or copy links must never become independent conflicting sync jobs");
        std::ofstream(source,std::ios::binary)<<"Local synthetic change\n";auto to_copy=service.preview(id,git::Action::use_source);
        check(local_file::read(repo/L"Global.md",1024).bytes==original,"Previewing local changes must not write the Git copy");
        std::ofstream(source,std::ios::binary)<<"Newer local change\n";rejects([&]{service.apply(to_copy);},"A changed local source must invalidate an outgoing text confirmation");
        to_copy=service.preview(id,git::Action::use_source);check(service.apply(to_copy).changed,"Explicit local-copy approval should apply the reviewed text");
        check(local_file::read(source,1024).bytes=="Newer local change\n"&&local_file::read(repo/L"Global.md",1024).bytes=="Newer local change\n","Copy synchronization must never overwrite the master on an outgoing action");
        check(std::filesystem::exists(data/L"instruction-backups")&&std::filesystem::directory_iterator(data/L"instruction-backups")!=std::filesystem::directory_iterator{},"An overwritten Git copy must retain a backup outside the repository");
        std::ofstream(repo/L"other.txt",std::ios::binary)<<"Unrelated staged work\n";run(repo,{L"add",L"--",L"other.txt"});
        const auto staged=run(repo,{L"diff",L"--cached",L"--name-only"});service.apply(service.preview(id,git::Action::commit));
        check(run(repo,{L"diff",L"--cached",L"--name-only"})==staged&&staged=="other.txt","Instruction commits must retain unrelated staged entries byte-for-byte");
        check(run(repo,{L"log",L"-1",L"--format=",L"--name-only"})=="Global.md","A copy commit must exclude unrelated staged or unstaged files");
        run(root,{L"init",L"--bare",L"--initial-branch=main",remote.wstring()});run(repo,{L"remote",L"add",L"origin",remote.wstring()});
        const auto push=service.preview(id,git::Action::push);check(pushes==0&&push->detail.find(git::narrow(remote))!=std::string::npos,"Push review must show the concrete noncredential destination without sending anything");
        service.apply(push);check(pushes==1&&service.status(id).outgoing.empty(),"Explicit reviewed instruction-only push must reach the owned local bare remote");
        check(run(repo,{L"diff",L"--cached",L"--name-only"})=="other.txt","A push must preserve unrelated staged work");
        run(repo,{L"commit",L"-m",L"Synthetic unrelated file"});rejects([&]{service.preview(id,git::Action::push);},"Outgoing history touching another file must never be pushed by instruction sync");
        const auto clone=root/L"second",second_data=root/L"second-data";git::Service second(second_data,runner);
        auto clone_plan=second.setup(file,clone,"Global.md",git::SetupKind::clone,git::narrow(remote));check(!std::filesystem::exists(clone),"Clone must wait for explicit confirmation");second.apply(clone_plan);
        const auto second_id=second.bindings().front().id;check(second.status(second_id).step==git::CopyStep::in_step,"A cloned equal copy should establish its agreed baseline");
        std::ofstream(clone/L"Global.md",std::ios::binary)<<"Incoming instructions need approval\n";second.apply(second.preview(second_id,git::Action::commit));second.apply(second.preview(second_id,git::Action::push));
        // A third clean clone exercises FF-only pull and incoming-master review without
        // clearing or moving any unrelated work in the first repository.
        const auto third=root/L"third",third_data=root/L"third-data";git::Service third_service(third_data,runner);third_service.apply(third_service.setup(file,third,"Global.md",git::SetupKind::clone,git::narrow(remote)));
        const auto third_id=third_service.bindings().front().id;
        check(third_service.status(third_id).step==git::CopyStep::conflict,"An unagreed incoming copy must require explicit owner choice");
        const auto before_master=git::files::read(source);{
            background_host::Handle reader(CreateFileW(source.c_str(),GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));OVERLAPPED shared{};
            if(!reader||!LockFileEx(reader.value,LOCKFILE_FAIL_IMMEDIATELY,0,MAXDWORD,MAXDWORD,&shared))throw std::runtime_error("Owned shared-reader fixture lock unavailable");
            rejects([&]{third_service.apply(third_service.preview(third_id,git::Action::use_copy));},"An instruction file held by another reader lock must refuse before overwriting its text");UnlockFileEx(reader.value,0,MAXDWORD,MAXDWORD,&shared);
            check(local_file::read(source,1024).bytes==before_master.bytes,"A busy source target must retain the original bytes and agreed-state safety");
        }third_service.apply(third_service.preview(third_id,git::Action::use_copy));const auto after_master=git::files::read(source);
        check(after_master.bytes=="Incoming instructions need approval\n"&&before_master.identity==after_master.identity,"Explicit incoming approval must update the source in place, preserving its file identity");
        check(std::filesystem::directory_iterator(third_data/L"instruction-backups")!=std::filesystem::directory_iterator{},"Incoming overwrite must retain the losing original outside source/repository folders");
        third_service.apply(third_service.preview(third_id,git::Action::enable_automatic));const auto denied_calls=calls;check(third_service.tick(900000,{},[](const auto&){return false;}).empty()&&calls==denied_calls&&!third_service.bindings().front().paused,"A live-workspace permit must defer autosync without a Git call or implicit permanent pause");const auto first_auto=third_service.tick(1000000);const auto before_calls=calls;
        check(first_auto.size()==1&&third_service.tick(1010000).empty()&&calls==before_calls,"Configured autosync fetches on its bounded cadence and does nothing between minute checks");
        std::ofstream(clone/L"Global.md",std::ios::binary)<<"Another incoming change\n";second.apply(second.preview(second_id,git::Action::commit));second.apply(second.preview(second_id,git::Action::push));
        const auto preserved=local_file::read(source,1024).bytes;const auto auto_results=third_service.tick(1400000);
        check(!auto_results.empty()&&third_service.bindings().front().paused&&local_file::read(source,1024).bytes==preserved,"Autosync must pause for incoming approval without silently overwriting the local master");
        check(third_service.tick(2000000).empty(),"Paused automatic work must not replay itself");
        check(third_service.preview(third_id,git::Action::use_copy)->preview=="Another incoming change\n"&&local_file::read(source,1024).bytes==preserved,"Incoming text remains reviewable and cannot apply itself while paused");
        // Persisted unknown fields and stale-writer policy are independent of Git execution.
        const auto settings=third_data/L"instruction-git-sync.json";auto json=git::Object::Parse(winrt::to_hstring(local_file::read(settings,2*1024*1024).bytes));json.SetNamedValue(L"future",git::Value::CreateStringValue(L"preserved"));std::ofstream(settings,std::ios::binary)<<winrt::to_string(json.Stringify());
        git::Store one(third_data),two(third_data);auto first=one.open();auto stale=two.open();one.save(first);check(git::Object::Parse(winrt::to_hstring(local_file::read(settings,2*1024*1024).bytes)).GetNamedString(L"future")==L"preserved","Unknown instruction settings fields must survive a save");
        first.front().paused=!first.front().paused;one.save(first);rejects([&]{two.save(stale);},"A stale settings writer must never overwrite newer synchronization approval state");
        run(repo,{L"config",L"remote.origin.pushurl",(root/L"other-destination.git").wstring()});rejects([&]{service.status(id);},"A separate push destination must never inherit the fetch remote's allowed-history proof");run(repo,{L"config",L"--unset",L"remote.origin.pushurl"});
        run(repo,{L"remote",L"add",L"alternate",remote.wstring()});run(repo,{L"config",L"branch.main.remote",L"alternate"});rejects([&]{service.status(id);},"Outgoing history may only be compared with the selected destination's upstream");run(repo,{L"config",L"branch.main.remote",L"origin"});
        const auto alias=source_dir/L"alias.md";check(CreateHardLinkW(alias.c_str(),source.c_str(),nullptr)!=FALSE,"Owned source hardlink fixture must be available");rejects([&]{service.preview(id,git::Action::use_source);},"Hardlinked masters must not enter an instruction write transaction");DeleteFileW(alias.c_str());
        const auto stale_action=service.preview(id,git::Action::use_source);const auto kept_copy=local_file::read(repo/L"Global.md",1024).bytes;git::Store foreign(data);auto foreign_bindings=foreign.open();foreign_bindings.front().paused=true;foreign.save(foreign_bindings);
        rejects([&]{service.apply(stale_action);},"A settings/approval change in another process must invalidate a file or remote action before dispatch");check(local_file::read(repo/L"Global.md",1024).bytes==kept_copy,"Stale synchronization approval must not modify the Git copy");service.reload();
        check(DeleteFileW(source.c_str())!=FALSE,"The owned missing-master fixture must be available");check(service.status(id).step==git::CopyStep::update_source,"A missing direct master should offer its existing Git copy for explicit recovery");service.apply(service.preview(id,git::Action::use_copy));check(local_file::read(source,1024).bytes==kept_copy,"Explicit missing-master recovery must restore the copy without moving its configured path");
        std::ofstream(source,std::ios::binary)<<std::string(1024*1024+1,'a');rejects([&]{service.preview(id,git::Action::use_source);},"Oversized instruction sources must fail before copy, commit or remote operations");std::ofstream(source,std::ios::binary)<<kept_copy;
        const auto bad_data=root/L"bad-data";std::filesystem::create_directory(bad_data);const auto bad_file=bad_data/L"instruction-git-sync.json";std::ofstream(bad_file,std::ios::binary)<<"{malformed";git::Store malformed(bad_data);
        rejects([&]{malformed.open();},"Malformed instruction settings must remain read only and preserve their bytes");rejects([&]{malformed.save({});},"A failed settings open must never overwrite unknown or malformed data");check(local_file::read(bad_file,128).bytes=="{malformed","Malformed settings must remain byte-for-byte intact");
        const auto private_repo=root/L"private",private_data=root/L"private-data";unsigned gh_injected{};const auto pushes_before=pushes;
        git::Runner private_runner=[&](git::Command command,const auto& cancel)->git::Result{
            if(command.tool!=code_hosting::Tool::gh)return runner(std::move(command),cancel);++gh_injected;
            if(command.arguments==std::vector<std::wstring>{L"auth",L"status",L"--hostname",L"github.com"})return {0,{}};
            if(command.arguments.size()>1&&command.arguments[1]==L"create"){
                check(std::find(command.arguments.begin(),command.arguments.end(),L"--private")!=command.arguments.end()&&std::find(command.arguments.begin(),command.arguments.end(),L"--push")==command.arguments.end(),"Private repository creation must explicitly request privacy and keep push as a separate review");
                run(command.cwd,{L"remote",L"add",L"origin",remote.wstring()});return {0,{}};
            }
            check(command.arguments==std::vector<std::wstring>{L"repo",L"view",L"--json",L"isPrivate,nameWithOwner"},"Creation must verify only the exact nonsecret repository identity/privacy metadata");return {0,R"({"isPrivate":true,"nameWithOwner":"fixture/synthetic-instructions"})"};
        };
        git::Service private_service(private_data,private_runner);const auto private_plan=private_service.setup(file,private_repo,"Global.md",git::SetupKind::private_github,"fixture/synthetic-instructions");
        check(gh_injected==0&&!std::filesystem::exists(private_repo),"Private GitHub setup must wait for its concrete owner review");private_service.apply(private_plan);
        check(gh_injected==3&&pushes==pushes_before&&private_service.bindings().size()==1,"Injected auth metadata, creation and privacy verification must not call real GitHub/auth or an implicit push");
        git::Store offline_store(root/L"offline-data");offline_store.open();auto offline_binding=service.bindings().front();offline_binding.repository=root/L"missing-repository";offline_binding.automatic=true;offline_store.save({offline_binding});
        git::Service offline(root/L"offline-data",runner);const auto calls_before_offline=calls;const auto offline_pause=offline.preview(offline_binding.id,git::Action::disable_automatic);offline.apply(offline_pause);
        check(!offline.bindings().front().automatic&&calls==calls_before_offline,"Pausing automatic sync must work without reading an unavailable repository or running Git");offline.apply(offline.preview(offline_binding.id,git::Action::unlink));check(offline.bindings().empty()&&calls==calls_before_offline,"Unlink must remain available offline and retain all source data");
        const auto eol_source=root/L"eol-source",eol_repo=root/L"eol-repo";std::filesystem::create_directory(eol_source);std::filesystem::create_directory(eol_repo);std::ofstream(eol_source/L"AGENTS.md",std::ios::binary)<<"Windows synthetic text\r\n";
        run(eol_repo,{L"init",L"--initial-branch=main"});std::ofstream(eol_repo/L".gitattributes",std::ios::binary)<<"Global.md text eol=lf\n";run(eol_repo,{L"add",L"--",L".gitattributes"});run(eol_repo,{L"commit",L"-m",L"Synthetic attribute baseline"});
        git::Service eol_service(root/L"eol-data",runner);eol_service.apply(eol_service.attach(InstructionService::project_files(eol_source).files.front(),eol_repo,"Global.md"));const auto eol_id=eol_service.bindings().front().id;eol_service.apply(eol_service.preview(eol_id,git::Action::use_source));eol_service.apply(eol_service.preview(eol_id,git::Action::commit));
        check(eol_service.status(eol_id).git.files.empty()&&local_file::read(eol_source/L"AGENTS.md",1024).bytes=="Windows synthetic text\r\n","Built-in Git LF normalization must produce a clean isolated commit while preserving original Windows instruction bytes");
        git::Service case_alias(root/L"case-data",runner);rejects([&]{case_alias.attach(InstructionService::project_files(eol_source).files.front(),eol_repo,"GLOBAL.md");},"Case aliases must not create colliding Git index entries for the same Windows instruction file");
        std::ofstream(eol_repo/L".gitattributes",std::ios::binary)<<"Global.md filter=fixture-unconfigured\n";rejects([&]{eol_service.status(eol_id);},"Custom clean/smudge filters must be refused before status or instruction data can invoke them");std::ofstream(eol_repo/L".gitattributes",std::ios::binary)<<"Global.md text eol=lf\n";
        const auto link_count=service.bindings().size();service.apply(service.preview(id,git::Action::unlink));check(service.bindings().size()+1==link_count&&std::filesystem::exists(source)&&std::filesystem::exists(repo/L"Global.md")&&std::filesystem::exists(repo/L".git"),"Unlink must retain master, copy and complete repository history");
        check(private_calls==0&&mutations>0,"Ordinary native tests used local Git only, never GitHub auth, accounts, model calls or network remotes");
        std::ofstream(report,std::ios::binary)<<"PASS: "<<checks<<" instruction Git sync checks (owned temporary trees and local bare remote only)\n";return 0;
    }catch(const winrt::hresult_error& error){std::ofstream(report,std::ios::binary)<<"FAIL after "<<checks<<": "<<winrt::to_string(error.message())<<'\n';}
    catch(const std::exception& error){std::ofstream(report,std::ios::binary)<<"FAIL after "<<checks<<": "<<error.what()<<'\n';}return 1;
}
} // namespace coincide
