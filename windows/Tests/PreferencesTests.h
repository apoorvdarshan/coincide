#pragma once
#include "../Runtime/Preferences.h"
#include <fstream>
namespace coincide {
inline int preferences_tests(const std::filesystem::path& report){
    using Object=winrt::Windows::Data::Json::JsonObject;
    int checks{};auto check=[&](bool value,const char* message){++checks;if(!value)throw std::runtime_error(message);};
    auto rejects=[&](auto operation,const char* message){bool refused{};try{operation();}catch(...){refused=true;}check(refused,message);};
    const auto folder=std::filesystem::temp_directory_path()/(L"Coincide preferences 会話 "+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    struct Cleanup{std::filesystem::path value;~Cleanup(){std::error_code ignored;std::filesystem::remove_all(value,ignored);}} cleanup{folder};
    auto write=[&](std::string value){std::ofstream stream(folder/L"settings.json",std::ios::binary|std::ios::trunc);stream<<value;};
    auto bytes=[&]{std::ifstream stream(folder/L"settings.json",std::ios::binary);return std::string((std::istreambuf_iterator<char>(stream)),{});};
    try{
        check(std::filesystem::create_directory(folder),"The preference fixture directory must be unique");
        PreferencesStore store(folder);auto prefs=store.open();check(prefs.default_provider=="codex"&&!prefs.keep_awake&&!prefs.notifications&&prefs.background,"Safe defaults must not enable power changes or unsolicited notifications");
        prefs.providers.at("cursor").profile_id="6f9fdb19-df2e-49b7-a81a-a9a5fafb8da6";
        prefs.appearance="dark";prefs.language="hi";prefs.reply_font="serif";prefs.font_size=21;prefs.send_on_return=true;
        prefs.providers.at("codex").favorites={"fixture/model"};prefs.providers.at("codex").hidden={"fixture/hidden"};prefs.providers.at("codex").defaults={"codex","fixture/model","high","fast",true,false};
        const auto project=std::string("{cb787346-08f5-4dde-b01c-9a48a3a0ceac}");prefs.projects[project].provider="claude";prefs.projects[project].models["claude"]={"claude","project/model","medium","",false,false};
        store.save(prefs);PreferencesStore reopened(folder);const auto restored=reopened.open();
        check(restored.appearance=="dark"&&restored.language=="hi"&&restored.reply_font=="serif"&&restored.font_size==21&&restored.send_on_return,"Appearance and input preferences must round-trip");
        check(restored.providers.at("codex").favorites==std::vector<std::string>{"fixture/model"}&&restored.providers.at("codex").hidden==std::vector<std::string>{"fixture/hidden"},"Model visibility preferences must round-trip");
        check(restored.model_defaults({},"codex").model=="fixture/model"&&restored.model_defaults(project,"claude").model=="project/model"&&restored.provider_default(project)=="claude","Project defaults must override only their own providers");
        check(restored.providers.at("cursor").profile_id==prefs.providers.at("cursor").profile_id,"An explicitly chosen profile must round-trip separately from its verified account identity");
        auto invalid=prefs;invalid.providers.at("cursor").profile_id="../other-user";rejects([&]{store.save(invalid);},"Provider profile preferences must reject filesystem paths");
        const auto inherited_folder=folder/L"inheritance";PreferencesStore inherited(inherited_folder);auto overrides=inherited.open();overrides.providers.at("claude").defaults.model="global-model";overrides.projects[project].models["claude"]={"claude","project-model","","",false,false};inherited.save(overrides);overrides.projects[project].models.erase("claude");inherited.save(overrides);PreferencesStore inheritance_reader(inherited_folder);check(inheritance_reader.open().model_defaults(project,"claude").model=="global-model","Removing a project override must remain inherited after saving and reopening");
        invalid=prefs;invalid.font_size=500;rejects([&]{store.save(invalid);},"Font bounds must be validated before writing");
        invalid=prefs;invalid.language="unsupported";rejects([&]{store.save(invalid);},"Unsupported languages must be rejected");
        invalid=prefs;invalid.providers.at("codex").hidden.push_back("fixture/model");rejects([&]{store.save(invalid);},"Favorites must not also be hidden");
        invalid=prefs;invalid.providers.at("codex").enabled=false;rejects([&]{store.save(invalid);},"The default provider must remain enabled");
        invalid=prefs;invalid.shortcuts["browser"]="Ctrl+n";rejects([&]{store.save(invalid);},"Shortcut conflicts must use case-insensitive normalized keys");
        invalid=prefs;invalid.shortcuts["quit"]="Alt+F4";rejects([&]{store.save(invalid);},"OS-reserved accelerators must not be overridden");
        invalid=prefs;invalid.providers.at("codex").executable="./codex.exe";rejects([&]{store.save(invalid);},"Provider paths cannot depend on the current directory");
        invalid=prefs;invalid.providers.at("codex").custom_models={"same","same"};rejects([&]{store.save(invalid);},"Custom model duplicates must fail explicitly");
        invalid=prefs;invalid.providers.at("codex").defaults.model=std::string("x\0y",3);rejects([&]{store.save(invalid);},"Model IDs must not contain embedded NULs");
        const auto shortcut=parse_shortcut("Ctrl+Shift+T");check(shortcut.control&&shortcut.shift&&!shortcut.alt&&shortcut.key=='T',"Shortcut parsing must preserve modifiers and virtual key");
        check(parse_shortcut("").key==0&&parse_shortcut("F12").key==VK_F12,"Shortcuts may be disabled or use bounded function keys");
        rejects([&]{parse_shortcut("Ctrl+Ctrl+A");},"Repeated shortcut modifiers must be rejected");rejects([&]{parse_shortcut("F99999999999999999999999999999999999999999");},"Function keys must reject overflow before arithmetic");rejects([&]{parse_shortcut("Win+Q");},"Global Windows shortcuts must not be captured");rejects([&]{parse_shortcut("A");},"Typing ordinary text must not invoke app actions");
        auto stale=reopened.open();prefs.font_size=20;store.save(prefs);const auto latest=bytes();rejects([&]{reopened.save(stale);},"Concurrent settings changes must not be overwritten");check(bytes()==latest,"A stale save must leave the complete current file intact");
        auto document=Object::Parse(winrt::to_hstring(bytes()));document.SetNamedValue(L"future",Object::Parse(LR"({"preserve":true})"));auto providers=document.GetNamedObject(L"providers");auto codex=providers.GetNamedObject(L"codex");codex.SetNamedValue(L"futureProvider",Object::Parse(LR"({"keep":7})"));providers.SetNamedValue(L"codex",codex);write(winrt::to_string(document.Stringify()));
        PreferencesStore future(folder);auto known=future.open();known.appearance="light";future.save(known);auto preserved=Object::Parse(winrt::to_hstring(bytes()));check(preserved.GetNamedObject(L"future").GetNamedBoolean(L"preserve")&&preserved.GetNamedObject(L"providers").GetNamedObject(L"codex").GetNamedObject(L"futureProvider").GetNamedNumber(L"keep")==7,"Unknown root and provider fields must survive known edits");
        const auto before_lock=bytes();HANDLE lock=CreateFileW((folder/L"settings.lock").c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);check(lock!=INVALID_HANDLE_VALUE,"The fixture save lock must open");
        rejects([&]{future.save(known);},"An active writer lock must prevent overlapping updates");CloseHandle(lock);check(bytes()==before_lock,"A lock conflict must preserve the original settings file");
        write("{\"format\":\"coincide.windows.settings\",\"version\":2}");const auto unsupported=bytes();rejects([&]{future.open();},"Future versions must preserve the source and revoke writes");rejects([&]{future.save(known);},"Failed reopen must not retain an old write grant");check(bytes()==unsupported,"Unsupported preferences must never be replaced with defaults");
        write("{\"format\":\"coincide.windows.settings\",\"version\":1,\"background\":\"yes\"}");rejects([&]{PreferencesStore wrong(folder);wrong.open();},"Permission and lifetime booleans must not silently coerce strings");
        std::ofstream output(report);output<<"PASS: "<<checks<<" Windows preferences checks\n";return output?0:2;
    }catch(const winrt::hresult_error& error){std::ofstream(report)<<"FAIL: "<<winrt::to_string(error.message())<<'\n';}catch(const std::exception& error){std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';}return 1;
}
}
