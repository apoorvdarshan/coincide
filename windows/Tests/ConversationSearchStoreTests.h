#pragma once
#include "../App/WorkspaceStore.h"

namespace coincide {
inline int conversation_search_store_tests(const std::filesystem::path& report){
    const auto root=std::filesystem::temp_directory_path()/("coincide-message-search-"+new_id());
    ConversationSearch::Reader reader;unsigned checks{};
    const auto check=[&](bool condition,const char* why){++checks;if(!condition)throw std::runtime_error(why);};
    const auto rejects=[&](auto action,const char* why){bool failed{};try{action();}catch(...){failed=true;}check(failed,why);};
    const auto bytes=[](const std::filesystem::path& file){std::ifstream stream(file,std::ios::binary);return std::string(std::istreambuf_iterator<char>(stream),std::istreambuf_iterator<char>());};
    const auto write=[](const std::filesystem::path& file,const std::string& value){std::ofstream stream(file,std::ios::binary|std::ios::trunc);stream<<value;if(!stream)throw std::runtime_error("Owned search fixture write failed");};
    try{
        std::filesystem::create_directories(root);WorkspaceStore initial(root);auto workspace=initial.open();const auto id=new_id(),second=new_id();
        for(const auto& key:{id,second}){Thread thread;thread.id=key;thread.title="Same title";workspace.add_thread(thread);auto& live=workspace.thread(key);initial.load_thread(live);live.messages={{"first","user","Straße needle","codex"},{"last","assistant","saved body","codex"}};live.draft="private draft";QueuedInput queued;queued.id="queued-first";queued.text="private outbox";live.queued_inputs.push_back(queued);initial.save_thread(live);}initial.save_index(workspace);
        const auto file=root/L"threads"/winrt::to_hstring(id+".json").c_str(),second_file=root/L"threads"/winrt::to_hstring(second+".json").c_str();
        const auto original=bytes(file),second_original=bytes(second_file),index=bytes(root/L"workspace.json");
        WorkspaceStore live(root);auto lazy=live.open();reader=live.message_search_reader();std::size_t total{};const auto documents=reader(id,total,{});
        check(documents.size()==2&&documents[0].id=="first"&&documents[0].text=="Straße needle","Read-only search must parse saved message bodies and identities");
        check(total==original.size(),"Read-only search must account for actual bytes read");
        check(TranscriptFind::search(documents,"private").matches().empty(),"Drafts and queued input must not appear as saved messages");
        check(lazy.thread(id).messages.empty()&&lazy.thread(id).draft.empty(),"Search must not load or mutate a live lazy conversation");
        check(bytes(file)==original&&bytes(root/L"workspace.json")==index,"Search must not write transcript or index files");
        auto changed=json::JsonObject::Parse(winrt::to_hstring(original));changed.GetNamedArray(L"messages").GetAt(0).GetObject().SetNamedValue(L"text",json::JsonValue::CreateStringValue(L"changed after search"));write(file,winrt::to_string(changed.Stringify()));
        live.load_thread(lazy.thread(id));check(lazy.thread(id).messages[0].text=="changed after search","Search must not prime the live store cache with a stale snapshot");write(file,original);
        rejects([&]{std::size_t count{};reader("../../outside",count,{});},"Transcript identities must not permit path traversal");
        rejects([&]{std::size_t count{};reader(new_id(),count,{});},"Missing saved transcripts must be reported rather than fabricated");
        bool stopped{};try{std::size_t count{};reader(id,count,[]{return true;});}catch(const TranscriptFind::Cancelled&){stopped=true;}check(stopped,"Cancellation must stop a saved-file read");
        bool bounded{};try{std::size_t count=ConversationSearch::maximum_total_bytes-1;reader(id,count,{});}catch(const ConversationSearch::ReadLimit&){bounded=true;}check(bounded,"Aggregate read budget must be checked before reading a saved file");
        write(second_file,"not JSON");rejects([&]{std::size_t count{};reader(second,count,{});},"Malformed saved JSON must not be searched");write(second_file,second_original);
        auto wrong=json::JsonObject::Parse(winrt::to_hstring(second_original));wrong.SetNamedValue(L"id",json::JsonValue::CreateStringValue(winrt::to_hstring(id)));write(second_file,winrt::to_string(wrong.Stringify()));rejects([&]{std::size_t count{};reader(second,count,{});},"Saved transcript identity must match the selected conversation");
        wrong=json::JsonObject::Parse(winrt::to_hstring(second_original));wrong.SetNamedValue(L"version",json::JsonValue::CreateNumberValue(999));write(second_file,winrt::to_string(wrong.Stringify()));rejects([&]{std::size_t count{};reader(second,count,{});},"Future saved formats must fail without interpretation");
        wrong=json::JsonObject::Parse(winrt::to_hstring(second_original));wrong.SetNamedValue(L"version",json::JsonValue::CreateNumberValue(2));write(second_file,winrt::to_string(wrong.Stringify()));rejects([&]{std::size_t count{};reader(second,count,{});},"Hosted format markers must be verified before searching version 2");
        wrong=json::JsonObject::Parse(winrt::to_hstring(second_original));wrong.GetNamedArray(L"messages").GetAt(1).GetObject().SetNamedValue(L"id",json::JsonValue::CreateStringValue(L"first"));write(second_file,winrt::to_string(wrong.Stringify()));rejects([&]{std::size_t count{};reader(second,count,{});},"Duplicate message identities cannot authorize ambiguous navigation");
        std::filesystem::remove(second_file);check(CreateHardLinkW(second_file.c_str(),file.c_str(),nullptr)!=FALSE,"The real hard-link fixture must be created");rejects([&]{std::size_t count{};reader(id,count,{});},"Search must refuse hard-linked transcript files");std::filesystem::remove(second_file);write(second_file,second_original);
        {std::ofstream oversized(second_file,std::ios::binary|std::ios::trunc);oversized.seekp(static_cast<std::streamoff>(ConversationSearch::maximum_file_bytes));oversized.put('x');}
        rejects([&]{std::size_t count{};reader(second,count,{});},"Oversized saved transcripts must be refused before allocation");write(second_file,second_original);
        check(bytes(file)==original&&bytes(root/L"workspace.json")==index,"Rejected inputs must leave other saved state unchanged");
        reader={};std::filesystem::remove_all(root);std::ofstream output(report);output<<"PASS: "<<checks<<" saved conversation search isolation checks\n";return output?0:2;
    }catch(const winrt::hresult_error& error){std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<winrt::to_string(error.message())<<'\n';}catch(const std::exception& error){std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';}
    reader={};std::error_code ignored;std::filesystem::remove_all(root,ignored);return 1;
}
} // namespace coincide
