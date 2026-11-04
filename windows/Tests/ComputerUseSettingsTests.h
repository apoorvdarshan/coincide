#pragma once
#include "../Runtime/ComputerUseSettings.h"
#include <fstream>

namespace coincide {
inline int computer_use_settings_tests(const std::filesystem::path& report){
    using namespace computer_use;int checks{};auto check=[&](bool condition,const char* message){++checks;if(!condition)throw std::runtime_error(message);};auto rejects=[&](auto operation,const char* message){bool rejected{};try{operation();}catch(...){rejected=true;}check(rejected,message);};
    const auto folder=std::filesystem::temp_directory_path()/(L"Coincide CU settings fixture "+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    struct Cleanup{std::filesystem::path value;~Cleanup(){std::error_code ignored;std::filesystem::remove_all(value,ignored);}}cleanup{folder};const auto root=folder/L"data",file=root/L"computer-use.json";
    auto read=[&]{std::ifstream input(file,std::ios::binary);return std::string((std::istreambuf_iterator<char>(input)),{});};auto write=[&](const std::string& bytes){std::ofstream output(file,std::ios::binary|std::ios::trunc);output<<bytes;};
    try{
        rejects([&]{SettingsStore invalid(L"relative");},"Computer Use settings must require an absolute local data root");
        SettingsStore store(root);rejects([&]{store.save({true});},"A master switch cannot save before a successful load");check(!store.open().enabled&&!std::filesystem::exists(root),"Missing settings must default off without creating data or helper state");
        store.save({false});const auto disabled=Object::Parse(winrt::to_hstring(read()));check(disabled.Size()==3&&!disabled.GetNamedBoolean(L"enabled")&&disabled.GetNamedString(L"format")==L"coincide.windows.computer-use","Only the versioned master setting may be persisted by default");
        store.save({true});SettingsStore reopened(root/L".");check(reopened.open().enabled,"The explicit master switch must survive an app data-root alias/reopen");
        auto original=Object::Parse(winrt::to_hstring(read()));original.SetNamedValue(L"future",Object::Parse(LR"({"appearance":"compact","revision":7})"));write(winrt::to_string(original.Stringify()));SettingsStore future(root);(void)future.open();future.save({false});auto kept=Object::Parse(winrt::to_hstring(read()));
        check(!kept.GetNamedBoolean(L"enabled")&&kept.GetNamedObject(L"future").GetNamedString(L"appearance")==L"compact","Unknown safe fields must survive master changes");
        const auto latest=read();rejects([&]{reopened.save({false});},"A stale settings writer must not overwrite another window's changes");check(read()==latest,"Stale writer failure must preserve the complete current file");
        const auto lock_path=root/L"computer-use.lock";HANDLE lock=CreateFileW(lock_path.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);check(lock!=INVALID_HANDLE_VALUE,"The isolated writer lock must open");
        rejects([&]{future.save({true});},"An overlapping writer must fail before publishing a new master setting");CloseHandle(lock);check(read()==latest,"Lock conflicts must leave current settings untouched");future.save({true});check(Object::Parse(winrt::to_hstring(read())).GetNamedBoolean(L"enabled"),"A failed lock attempt must not corrupt the store cache or prevent explicit retry");
        const auto before_replace=read();HANDLE destination=CreateFileW(file.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);check(destination!=INVALID_HANDLE_VALUE,"The fixture destination lock must open");rejects([&]{future.save({false});},"Failed atomic replacement must report a storage failure");CloseHandle(destination);
        std::size_t temporary_files{};for(const auto& entry:std::filesystem::directory_iterator(root))if(entry.path().extension()==L".tmp")++temporary_files;
        check(read()==before_replace&&temporary_files==0,"Failed publication must preserve the old file and remove only its owned temporary file");future.save({false});check(!Object::Parse(winrt::to_hstring(read())).GetNamedBoolean(L"enabled"),"The same store must remain usable after atomic replacement failure");
        const auto good=read();auto backward=Object::Parse(winrt::to_hstring(good));backward.Remove(L"enabled");write(winrt::to_string(backward.Stringify()));check(!future.open().enabled,"Missing legacy master values must stay disabled");
        auto wrong=Object::Parse(winrt::to_hstring(good));wrong.SetNamedValue(L"enabled",Value::CreateStringValue(L"yes"));write(winrt::to_string(wrong.Stringify()));const auto malformed=read();rejects([&]{future.open();},"Permission booleans must never coerce strings");rejects([&]{future.save({true});},"A failed reopen must revoke the previous write grant");check(read()==malformed,"Malformed master settings must be preserved without default overwrite");
        auto unsupported=Object::Parse(winrt::to_hstring(good));unsupported.SetNamedValue(L"version",Value::CreateNumberValue(2));write(winrt::to_string(unsupported.Stringify()));const auto version=read();rejects([&]{future.open();},"Future settings versions must fail closed");check(read()==version,"An unsupported version must not be rewritten");
        for(const auto* field:{L"token",L"permissions",L"grants"}){auto credential=Object::Parse(winrt::to_hstring(good));credential.SetNamedValue(field,Value::CreateStringValue(L"synthetic-disallowed-data"));write(winrt::to_string(credential.Stringify()));const auto before=read();rejects([&]{future.open();},"Computer Use settings must not import credentials or persisted thread grants");check(read()==before,"Rejected sensitive metadata must stay unchanged and never enter a save cache");}
        write(std::string(64*1024+1,' '));rejects([&]{future.open();},"Settings reads must have a hard byte limit");write("{");rejects([&]{future.open();},"Malformed JSON must fail closed");
        write(good);check(!future.open().enabled,"Correcting the original file must permit a new explicit load");
        const auto new_root=folder/L"first-save";SettingsStore waiting(new_root);check(!waiting.open().enabled,"A fresh missing directory must retain disabled defaults");std::filesystem::create_directory(new_root);std::ofstream(new_root/L"computer-use.json")<<"{\"format\":\"coincide.windows.computer-use\",\"version\":1,\"enabled\":true}";
        rejects([&]{waiting.save({false});},"A file created after open must not be overwritten on the first save");
        std::ofstream output(report);output<<"PASS: "<<checks<<" Computer Use settings persistence checks (no desktop service)\n";return output?0:2;
    }catch(const winrt::hresult_error& error){std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<winrt::to_string(error.message())<<'\n';}catch(const std::exception& error){std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';}return 1;
}
} // namespace coincide
