#pragma once
#include "../App/WorkspaceStore.h"

namespace coincide {
inline int host_persistence_tests(const std::filesystem::path& report){
    const auto directory=std::filesystem::temp_directory_path()/winrt::to_hstring("CoincideHostPersistence-"+new_id()).c_str();std::size_t checks{};
    const auto check=[&](bool value,const char* message){if(!value)throw std::runtime_error(message);++checks;};
    const auto rejects=[&](auto action,const char* message){bool failed{};try{action();}catch(...){failed=true;}check(failed,message);};
    const auto read=[](const std::filesystem::path& path){std::ifstream stream(path,std::ios::binary);return json::JsonObject::Parse(winrt::to_hstring(std::string(std::istreambuf_iterator<char>(stream),{})));};
    const auto write=[](const std::filesystem::path& path,const json::JsonObject& value){std::ofstream stream(path,std::ios::binary);stream<<winrt::to_string(value.Stringify());};
    try{
        std::filesystem::create_directories(directory);WorkspaceStore store(directory);auto workspace=store.open();Thread thread;thread.id=new_id();thread.title="Owned hosted conversation";thread.provider="codex";workspace.add_thread(thread);store.load_thread(workspace.thread(thread.id));store.save_thread(workspace.thread(thread.id));store.save_index(workspace);
        const auto index=directory/L"workspace.json",transcript=directory/L"threads"/winrt::to_hstring(thread.id+".json").c_str();
        check(read(index).GetNamedNumber(L"version")==1&&read(transcript).GetNamedNumber(L"version")==1,"Ordinary workspaces must retain their existing format until hosting is explicitly armed");
        const auto epoch=new_id();workspace.requires_background_host=true;workspace.thread(thread.id).host_cursors.push_back({"codex",epoch,0});store.save_thread(workspace.thread(thread.id));store.save_index(workspace);
        check(read(index).GetNamedNumber(L"version")==2&&read(transcript).GetNamedNumber(L"version")==2,"Arming a hosted session must upgrade both durable files so old clients refuse duplicate in-process providers");
        WorkspaceStore restarted(directory);auto restored=restarted.open();check(restored.requires_background_host&&restored.thread(thread.id).host_cursors.front().sequence==0,"Startup must discover hosted ownership without eagerly loading every transcript");restarted.load_thread(restored.thread(thread.id));
        auto& target=restored.thread(thread.id);target.messages.push_back({new_id(),"assistant","Durable prefix","codex"});target.host_cursors.front().sequence=7;restarted.save_thread(target);
        // The transcript/cursor are one atomic file. Simulate an index failure after this save.
        WorkspaceStore recovered(directory);auto interrupted=recovered.open();recovered.load_thread(interrupted.thread(thread.id));
        check(interrupted.thread(thread.id).host_cursors.front().sequence==7&&interrupted.thread(thread.id).messages.front().text=="Durable prefix","A transcript ahead of its index must restore its exact applied event prefix without replaying deltas");
        recovered.save_index(interrupted);const auto consistent=read(index).Stringify();
        auto& owned=interrupted.thread(thread.id);owned.host_cursors.front().sequence=9;recovered.save_index(interrupted);
        rejects([&]{WorkspaceStore next(directory);auto invalid=next.open();next.load_thread(invalid.thread(thread.id));},"An index ahead of its transcript must stop adoption instead of acknowledging unapplied events");
        check(read(transcript).GetNamedArray(L"messages").Size()==1,"A mismatched receipt must leave the saved history unchanged");
        write(index,json::JsonObject::Parse(consistent));
        auto doc=read(transcript);doc.GetNamedArray(L"hostEventCursors").GetAt(0).GetObject().SetNamedValue(L"epoch",json::JsonValue::CreateStringValue(winrt::to_hstring(new_id())));write(transcript,doc);
        rejects([&]{WorkspaceStore next(directory);auto invalid=next.open();next.load_thread(invalid.thread(thread.id));},"A mismatched host epoch must require review rather than joining another generation");
        doc.GetNamedArray(L"hostEventCursors").GetAt(0).GetObject().SetNamedValue(L"epoch",json::JsonValue::CreateStringValue(winrt::to_hstring(epoch)));write(transcript,doc);
        auto original=read(index);auto cursor=original.GetNamedArray(L"threads").GetAt(0).GetObject().GetNamedArray(L"hostEventCursors").GetAt(0).GetObject();cursor.SetNamedValue(L"sequence",json::JsonValue::CreateNumberValue(0.5));write(index,original);
        rejects([&]{WorkspaceStore next(directory);next.open();},"Fractional hosted sequence numbers must be rejected before any agent can start");
        write(index,json::JsonObject::Parse(consistent));original=read(index);auto cursors=original.GetNamedArray(L"threads").GetAt(0).GetObject().GetNamedArray(L"hostEventCursors");cursors.Append(cursors.GetAt(0));write(index,original);
        rejects([&]{WorkspaceStore next(directory);next.open();},"Duplicate provider receipts must never provide ambiguous adoption cursors");
        write(index,json::JsonObject::Parse(consistent));original=read(index);original.SetNamedValue(L"version",json::JsonValue::CreateNumberValue(1));write(index,original);
        rejects([&]{WorkspaceStore next(directory);next.open();},"Hosted metadata in an unguarded legacy index must fail closed");
        write(index,json::JsonObject::Parse(consistent));original=read(index);original.GetNamedArray(L"threads").GetAt(0).GetObject().GetNamedArray(L"hostEventCursors").GetAt(0).GetObject().SetNamedValue(L"futureReceipt",json::JsonValue::CreateBooleanValue(true));write(index,original);
        doc=read(transcript);doc.GetNamedArray(L"hostEventCursors").GetAt(0).GetObject().SetNamedValue(L"futureReceipt",json::JsonValue::CreateBooleanValue(true));write(transcript,doc);
        WorkspaceStore forward(directory);auto current=forward.open();forward.load_thread(current.thread(thread.id));forward.save_thread(current.thread(thread.id));forward.save_index(current);
        check(read(transcript).GetNamedArray(L"hostEventCursors").GetAt(0).GetObject().GetNamedBoolean(L"futureReceipt")&&read(index).GetNamedArray(L"threads").GetAt(0).GetObject().GetNamedArray(L"hostEventCursors").GetAt(0).GetObject().GetNamedBoolean(L"futureReceipt"),"Receipt updates must preserve unknown future metadata in both durable files");
        current.requires_background_host=false;current.thread(thread.id).host_cursors.clear();forward.save_thread(current.thread(thread.id));forward.save_index(current);
        check(read(index).GetNamedNumber(L"version")==2&&read(transcript).GetNamedNumber(L"version")==2,"Removing a retired receipt must never silently downgrade a host-aware workspace");
        rejects([&]{auto invalid=current.thread(thread.id);invalid.host_cursors={{"codex",epoch,9007199254740992ULL}};forward.save_thread(invalid);},"A sequence beyond exact JSON integer precision must not be persisted");
        std::filesystem::remove_all(directory);std::ofstream output(report);output<<"PASS: "<<checks<<" hosted conversation persistence checks\n";return output?0:2;
    }catch(const winrt::hresult_error& error){std::ofstream(report)<<"FAIL: "<<winrt::to_string(error.message())<<'\n';}
    catch(const std::exception& error){std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';}
    std::error_code ignored;std::filesystem::remove_all(directory,ignored);return 1;
}
} // namespace coincide
