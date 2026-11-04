#pragma once
#include "../App/WorkspaceStore.h"
#include "InstructionImportTests.h"
#include <atomic>
#include <barrier>
#include <thread>

namespace coincide {
inline int import_store_tests(const std::filesystem::path& report){
    std::size_t checks{};const auto check=[&](bool passed,const char* message){++checks;if(!passed)throw std::runtime_error(message);};const auto rejects=[&](auto action,const char* message){bool rejected{};try{action();}catch(...){rejected=true;}check(rejected,message);};
    const auto contents=[](const std::filesystem::path& file){std::ifstream stream(file,std::ios::binary);if(!stream)throw std::runtime_error("Owned import fixture file is missing");return std::string((std::istreambuf_iterator<char>(stream)),std::istreambuf_iterator<char>());};
    try{
        using namespace instruction_import_fixture;Directory fixture;const auto directory=fixture.path/L"store";const auto index=directory/L"workspace.json";
        const auto thread_path=[&](const std::string& id){return directory/L"threads"/winrt::to_hstring(id+".json").c_str();};
        const auto make_preview=[&](char digit){auto source=canonical();source.replace(source.find(session),session.size(),std::string(1,digit)+"0000000-0000-0000-0000-000000000001");return ImportService::preview(fixture.write(std::filesystem::path("source-"+std::to_string(digit)+".jsonl"),source));};
        const auto make_thread=[](const ImportPreview& source){Thread thread;thread.id=new_id();thread.title=source.title;thread.provider=source.provider;thread.model=source.model;thread.messages=source.messages;thread.sessions={{source.provider,source.session_id,source.messages.size()}};return thread;};
        const auto source=ImportService::preview(fixture.write(L"source.jsonl",canonical()));const auto original_source=contents(source.source_path);
        Thread original;original.id=new_id();original.title="Existing conversation";original.provider="claude";original.messages={{"original-user","user","Existing text","claude"}};original.sessions={{"claude","b0000000-0000-0000-0000-000000000001",1}};
        WorkspaceStore seed(directory);auto initial=seed.open();initial.add_thread(original);seed.load_thread(initial.thread(original.id));initial.thread(original.id)=original;seed.save_thread(original);seed.save_index(initial);
        auto index_json=json::JsonObject::Parse(winrt::to_hstring(contents(index)));index_json.SetNamedValue(L"futureWorkspaceField",json::JsonValue::CreateStringValue(L"preserve workspace future data"));fixture.write(L"store/workspace.json",winrt::to_string(index_json.Stringify()));
        const auto original_bytes=contents(thread_path(original.id));WorkspaceStore store(directory);auto workspace=store.open();
        check(workspace.thread(original.id).messages.empty()&&workspace.thread(original.id).sessions.empty(),"opening an import target workspace must leave other transcripts unloaded");
        auto imported=make_thread(source);auto provenance=ImportService::provenance(source);json::JsonObject future;future.SetNamedValue(L"keep",json::JsonValue::CreateStringValue(L"future provenance retained"));provenance.SetNamedValue(L"future",future);
        store.publish_import(workspace,imported,provenance);
        check(workspace.threads.size()==2&&workspace.thread(imported.id).messages.size()==source.messages.size()&&!workspace.thread(imported.id).full_access,"explicit import must publish all supported messages in approval mode after persistence");
        check(contents(thread_path(original.id))==original_bytes&&contents(source.source_path)==original_source,"import publication must never rewrite another transcript or its original CLI source");
        check(json::JsonObject::Parse(winrt::to_hstring(contents(index))).GetNamedString(L"futureWorkspaceField")==L"preserve workspace future data","atomic index publication must preserve unrelated unknown metadata");
        const auto imported_json=json::JsonObject::Parse(winrt::to_hstring(contents(thread_path(imported.id))));
        check(imported_json.GetNamedObject(L"importedSession").GetNamedObject(L"future").GetNamedString(L"keep")==L"future provenance retained","unknown safe provenance must remain inside the imported transcript");
        WorkspaceStore reopened(directory);auto metadata=reopened.open();std::vector<std::string> ids;for(const auto& thread:metadata.threads)ids.push_back(thread.id);
        const auto native=WorkspaceStore::session_snapshot(directory,ids);
        check(native.size()==2&&std::any_of(native.begin(),native.end(),[&](const auto& identity){return identity.thread_id==imported.id&&identity.session.id==source.session_id&&identity.imported_origin;}),"duplicate checks must see deduplicated current/origin identities from unopened transcripts without constructing message vectors");
        check(metadata.thread(imported.id).messages.empty()&&metadata.thread(imported.id).sessions.empty(),"static session snapshots must not mutate live workspace metadata or loaded caches");
        auto duplicate=make_thread(source);rejects([&]{reopened.publish_import(metadata,duplicate,ImportService::provenance(source));},"a native-session duplicate must be rejected even when the existing thread was never opened");
        check(metadata.threads.size()==2&&!std::filesystem::exists(thread_path(duplicate.id)),"duplicate rejection must not leave an index entry or orphan transcript");
        reopened.load_thread(metadata.thread(imported.id));check(metadata.thread(imported.id).sessions.front().acknowledged_messages==source.messages.size(),"an imported native session must acknowledge exactly the preserved history after reopening");
        metadata.thread(imported.id).draft="Post-import draft";reopened.save_thread(metadata.thread(imported.id));
        check(json::JsonObject::Parse(winrt::to_hstring(contents(thread_path(imported.id)))).GetNamedObject(L"importedSession").GetNamedObject(L"future").GetNamedString(L"keep")==L"future provenance retained","ordinary saves after import must retain unknown provenance");
        const auto next=make_preview('c');auto candidate=make_thread(next);const auto before_index=contents(index);const auto count=metadata.threads.size();
        local_file::Handle lock(CreateFileW(index.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));check(lock.value!=INVALID_HANDLE_VALUE,"the owned index-lock fixture must acquire its target");
        rejects([&]{reopened.publish_import(metadata,candidate,ImportService::provenance(next));},"an index replacement failure must reject the whole import transaction");
        check(metadata.threads.size()==count&&!std::filesystem::exists(thread_path(candidate.id))&&contents(index)==before_index,"index failure must roll back only the new transcript and leave caller workspace/index unchanged");
        check(contents(thread_path(original.id))==original_bytes,"failed imports must preserve unrelated transcript bytes");
        rejects([&]{reopened.save_thread(candidate);},"failed imports must not leak loaded/transcript cache entries");
        CloseHandle(lock.value);lock.value=INVALID_HANDLE_VALUE;reopened.publish_import(metadata,candidate,ImportService::provenance(next));
        check(metadata.threads.size()==count+1&&std::filesystem::exists(thread_path(candidate.id)),"the same import must be retryable after removing the owned index lock");
        const auto third=make_preview('d');auto orphan=make_thread(third);const auto orphan_path=thread_path(orphan.id);fixture.write(std::filesystem::path(L"store/threads")/winrt::to_hstring(orphan.id+".json").c_str(),"preserve externally created orphan bytes");
        rejects([&]{reopened.publish_import(metadata,orphan,ImportService::provenance(third));},"publication must never replace an existing unindexed transcript file");
        check(contents(orphan_path)=="preserve externally created orphan bytes","failed target creation must not remove or alter an existing file");
        auto access=make_thread(third);access.full_access=true;rejects([&]{reopened.publish_import(metadata,access,ImportService::provenance(third));},"source metadata must never grant full access to an imported conversation");
        auto unsafe=ImportService::provenance(third);unsafe.SetNamedValue(L"access_token",json::JsonValue::CreateStringValue(L"fixture-only-not-a-secret"));auto unsafe_thread=make_thread(third);
        rejects([&]{reopened.publish_import(metadata,unsafe_thread,unsafe);},"authentication fields must not be accepted as import provenance");
        rejects([&]{WorkspaceStore::session_snapshot(directory,{new_id()});},"missing conversation files must fail duplicate checking honestly");
        rejects([&]{WorkspaceStore::session_snapshot(directory,{original.id,original.id});},"duplicate snapshot IDs must be rejected before masking another conversation");
        local_file::Handle unreadable(CreateFileW(thread_path(original.id).c_str(),GENERIC_READ,0,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));check(unreadable.value!=INVALID_HANDLE_VALUE,"the owned unreadable-file fixture must lock its target");
        rejects([&]{WorkspaceStore::session_snapshot(directory,{original.id});},"unreadable transcripts must not silently disappear from duplicate detection");CloseHandle(unreadable.value);unreadable.value=INVALID_HANDLE_VALUE;
        const auto malformed=new_id();const auto malformed_relative=std::filesystem::path(L"store/threads")/winrt::to_hstring(malformed+".json").c_str();
        fixture.write(malformed_relative,"{\"version\":2,\"id\":\""+malformed+"\",\"messages\":[],\"sessions\":[]}");rejects([&]{WorkspaceStore::session_snapshot(directory,{malformed});},"unsupported transcript versions must fail snapshot validation");
        fixture.write(malformed_relative,"{\"version\":1,\"id\":\""+malformed+"\",\"messages\":[],\"sessions\":[{\"provider\":\"codex\",\"id\":\"native\",\"acknowledged\":1}]}");rejects([&]{WorkspaceStore::session_snapshot(directory,{malformed});},"acknowledgement counts beyond message history must fail snapshot validation");
        WorkspaceStore stale(directory);auto stale_workspace=stale.open();auto external=json::JsonObject::Parse(winrt::to_hstring(contents(index)));external.SetNamedValue(L"externalChange",json::JsonValue::CreateBooleanValue(true));const auto external_bytes=winrt::to_string(external.Stringify());fixture.write(L"store/workspace.json",external_bytes);auto fresh=make_thread(third);
        rejects([&]{stale.publish_import(stale_workspace,fresh,ImportService::provenance(third));},"a stale store must not overwrite an externally changed index during import");
        check(contents(index)==external_bytes&&!std::filesystem::exists(thread_path(fresh.id)),"external index changes must remain intact after rejected publication");
        rejects([&]{stale.save_index(stale_workspace);},"an ordinary stale index writer must not erase imports committed by another store");

        const auto history_source=make_preview('e');auto history=make_thread(history_source);history.sessions.clear();WorkspaceStore history_store(directory);auto history_workspace=history_store.open();
        history_store.publish_import(history_workspace,history,ImportService::provenance(history_source));const auto history_ids=WorkspaceStore::session_snapshot(directory,{history.id});
        check(history_ids.size()==1&&history_ids.front().imported_origin&&history_ids.front().session.id==history_source.session_id,"history-only imports must preserve immutable origin identities for later duplicate detection");
        history_workspace.thread(history.id).sessions={{"codex","f0000000-0000-0000-0000-000000000001",0}};history_store.save_thread(history_workspace.thread(history.id));
        const auto continued=WorkspaceStore::session_snapshot(directory,{history.id});
        check(continued.size()==2&&std::any_of(continued.begin(),continued.end(),[&](const auto& identity){return identity.imported_origin&&identity.session.id==history_source.session_id;}),"a later fresh native reference must not replace an imported history's origin identity");
        auto history_duplicate=make_thread(history_source);rejects([&]{history_store.publish_import(history_workspace,history_duplicate,ImportService::provenance(history_source));},"immutable origin identities must still prevent duplicate imports after starting a fresh native conversation");

        const auto normal_path=fixture.path/L"normal";WorkspaceStore normal(normal_path);auto normal_workspace=normal.open();const auto project=new_id();normal_workspace.add_project({project,"Original project","C:\\owned-fixture"});normal.save_index(normal_workspace);
        const auto normal_index=normal_path/L"workspace.json";const auto normal_before=contents(normal_index);const auto normal_state=normal_workspace;normal_workspace.rename_project(project,"Changed but not saved");
        local_file::Handle normal_lock(CreateFileW(normal_index.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));check(normal_lock.value!=INVALID_HANDLE_VALUE,"the ordinary-save cache fixture must lock its index");
        rejects([&]{normal.save_index(normal_workspace);},"an ordinary index save must report a locked replacement");CloseHandle(normal_lock.value);normal_lock.value=INVALID_HANDLE_VALUE;normal_workspace=normal_state;normal.save_index(normal_workspace);
        check(contents(normal_index)==normal_before,"failed ordinary saves must not mutate the cached original JSON or prevent a safe retry");
        const auto moved=fixture.path/L"normal-moved";std::filesystem::rename(normal_path,moved);std::filesystem::create_directory(normal_path);fixture.write(L"normal/workspace.json",normal_before);
        rejects([&]{normal.save_index(normal_workspace);},"equal JSON at a recreated storage path must not bypass physical directory identity binding");
        check(contents(normal_path/L"workspace.json")==normal_before&&contents(moved/L"workspace.json")==normal_before,"storage identity rejection must preserve both original and replacement folders");

        const auto concurrent=fixture.path/L"concurrent";WorkspaceStore concurrent_seed(concurrent);auto empty=concurrent_seed.open();concurrent_seed.save_index(empty);
        std::barrier start(2);std::atomic<unsigned> published{},rejected{};const auto concurrent_provenance=winrt::to_string(ImportService::provenance(source).Stringify());
        auto writer=[&]{bool arrived{};try{winrt::init_apartment(winrt::apartment_type::multi_threaded);struct Apartment{~Apartment(){winrt::uninit_apartment();}} apartment;WorkspaceStore writer_store(concurrent);auto snapshot=writer_store.open();auto imported_copy=make_thread(source);arrived=true;start.arrive_and_wait();writer_store.publish_import(snapshot,imported_copy,json::JsonObject::Parse(winrt::to_hstring(concurrent_provenance)));++published;}catch(...){if(!arrived)start.arrive_and_drop();++rejected;}};
        std::thread first(writer),second(writer);first.join();second.join();WorkspaceStore concurrent_result(concurrent);const auto committed=concurrent_result.open();
        check(published==1&&rejected==1&&committed.threads.size()==1,"cooperative concurrent importers must publish exactly one native session without dropping the winning index entry");
        std::size_t files{};for(const auto& entry:std::filesystem::directory_iterator(concurrent/L"threads"))if(entry.is_regular_file())++files;
        check(files==1,"a rejected concurrent importer must not leave an unindexed transcript");
        std::ofstream output(report);output<<"PASS: "<<checks<<" Windows atomic import store checks\n";return output?0:2;
    }catch(const std::exception& error){std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';return 1;}catch(const winrt::hresult_error& error){std::ofstream(report)<<"FAIL: Windows import store API error "<<static_cast<unsigned>(error.code())<<'\n';return 1;}
}
} // namespace coincide
