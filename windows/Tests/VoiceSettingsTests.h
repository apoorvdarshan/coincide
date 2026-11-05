#pragma once
#include "../Runtime/OfflineVoiceSettings.h"
#include <fstream>

namespace coincide {
inline int voice_settings_tests(const std::filesystem::path& report){
    std::size_t checks{};const auto check=[&](bool value,const char* message){++checks;if(!value)throw std::runtime_error(message);};const auto rejects=[&](auto action,const char* message){bool rejected{};try{action();}catch(...){rejected=true;}check(rejected,message);};
    struct Directory{std::filesystem::path path;Directory(){winrt::guid id;winrt::check_hresult(CoCreateGuid(reinterpret_cast<GUID*>(&id)));path=std::filesystem::temp_directory_path()/(L"Coincide-Voice-Settings-Fixture-"+std::wstring(winrt::to_hstring(id)));std::filesystem::create_directory(path);}~Directory(){std::error_code error;std::filesystem::remove_all(path,error);}};
    try{
        Directory fixture;const auto root=fixture.path/L"Voice",file=root/L"voice.json";OfflineVoiceSettingsStore store(root);auto settings=store.open();
        check(!settings.enabled&&settings.language=="auto"&&settings.threads==4&&!std::filesystem::exists(root),"missing Voice settings must remain disabled without creating any files");
        check(store.models().empty(),"missing optional model folders must return no installed models");
        rejects([&]{store.options(settings);},"disabled Voice settings must not produce recording options");
        settings.enabled=true;rejects([&]{store.save(settings);},"Voice cannot be enabled without explicit engine/model selection");check(!std::filesystem::exists(root),"invalid settings must be rejected before creating app files");
        std::filesystem::create_directories(root/L"models");const auto engine=fixture.path/L"owned engine.exe",model=root/L"models"/L"model 你好.bin";std::ofstream(engine)<<"owned metadata fixture";std::ofstream(model)<<std::string(32,'m');std::ofstream(root/L"models"/L"empty.bin");std::ofstream(root/L"models"/L"ignored.txt")<<std::string(32,'x');
        settings.executable=winrt::to_string(engine.wstring());settings.model=winrt::to_string(model.filename().wstring());settings.language="hi";settings.threads=2;store.save(settings);const auto saved=local_file::read(file,64*1024).bytes;
        OfflineVoiceSettingsStore reopened(root);const auto restored=reopened.open();check(restored.enabled&&restored.executable==settings.executable&&restored.model==settings.model&&restored.language=="hi"&&restored.threads==2,"explicit Voice settings must survive reopening without normalizing away Unicode paths");
        const auto options=reopened.options(restored);check(options.model==model&&options.working_root==root/L"working"&&options.models_root==root/L"models","recording options must remain inside app-owned models and working folders");
        const auto models=reopened.models();check(models.size()==1&&models.front()==settings.model,"model discovery must only list bounded regular nonempty .bin files");
        auto invalid=settings;invalid.model="../other.bin";rejects([&]{reopened.save(invalid);},"model selection must not escape its app-owned model folder");invalid=settings;invalid.language="--file";rejects([&]{reopened.save(invalid);},"unsupported voice languages must not become CLI argument text");invalid=settings;invalid.threads=17;rejects([&]{reopened.save(invalid);},"voice CPU threads must remain bounded");
        local_file::Handle locked(CreateFileW(file.c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr));check(locked.value!=INVALID_HANDLE_VALUE,"the owned Voice settings failure fixture must lock the target");auto changed=settings;changed.language="en";rejects([&]{reopened.save(changed);},"locked Voice settings replacements must fail without overwriting the old file");CloseHandle(locked.value);locked.value=INVALID_HANDLE_VALUE;
        check(local_file::read(file,64*1024).bytes==saved,"failed settings saves must preserve original bytes");reopened.save(settings);check(local_file::read(file,64*1024).bytes==saved,"failed settings saves must leave caches safe for retry");
        auto future=winrt::Windows::Data::Json::JsonObject::Parse(winrt::to_hstring(saved));future.SetNamedValue(L"futureField",winrt::Windows::Data::Json::JsonValue::CreateStringValue(L"keep future metadata"));{std::ofstream output(file,std::ios::binary|std::ios::trunc);output<<winrt::to_string(future.Stringify());}
        rejects([&]{reopened.save(settings);},"a stale Voice settings window must not erase externally added metadata");OfflineVoiceSettingsStore current(root);auto latest=current.open();latest.enabled=false;current.save(latest);
        check(winrt::Windows::Data::Json::JsonObject::Parse(winrt::to_hstring(local_file::read(file,64*1024).bytes)).GetNamedString(L"futureField")==L"keep future metadata","normal Voice saves must retain unknown safe future metadata");
        {std::ofstream output(file,std::ios::trunc);output<<"{\"version\":99,\"format\":\"future voice\"}";}OfflineVoiceSettingsStore unsupported(root);rejects([&]{unsupported.open();},"unknown voice formats must fail honestly");rejects([&]{unsupported.save(settings);},"a failed load must revoke settings writes");check(local_file::read(file,64*1024).bytes=="{\"version\":99,\"format\":\"future voice\"}","unsupported settings must remain byte-for-byte unchanged");
        std::ofstream output(report);output<<"PASS: "<<checks<<" Windows offline voice settings checks\n";return output?0:2;
    }catch(const std::exception& error){std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';return 1;}catch(const winrt::hresult_error& error){std::ofstream(report)<<"FAIL: Windows Voice settings API error "<<static_cast<unsigned>(error.code())<<'\n';return 1;}
}
} // namespace coincide
