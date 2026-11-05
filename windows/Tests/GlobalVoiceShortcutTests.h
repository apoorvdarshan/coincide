#pragma once
#include "../Runtime/GlobalVoiceShortcut.h"
#include <filesystem>
#include <fstream>
#include <vector>

namespace coincide {
inline int global_voice_shortcut_tests(const std::filesystem::path& report){
    unsigned checks{};const auto check=[&](bool value,const char* reason){++checks;if(!value)throw std::runtime_error(reason);};
    try{
        using A=VoiceShortcutAction;using M=VoiceShortcutMode;bool pressed{},active{},conflict{};unsigned added{},removed{};std::vector<A> commands;
        GlobalVoiceShortcut::Backend backend;
        backend.add=[&](HWND window,int id,UINT modifiers,UINT key){++added;check(window&&id==GlobalVoiceShortcut::identifier&&modifiers==(MOD_CONTROL|MOD_SHIFT|MOD_NOREPEAT)&&key==VK_SPACE,"Native registration must bind the exact non-repeating opt-in chord");return !conflict;};
        backend.remove=[&](HWND,int){++removed;return true;};backend.down=[&](int){return pressed;};
        GlobalVoiceShortcut shortcut([&](A action){commands.push_back(action);if(action==A::begin)active=true;else active=false;return true;},[&]{return active;},backend);
        const auto key_down=[&](WPARAM id=GlobalVoiceShortcut::identifier,LPARAM chord=MAKELPARAM(MOD_CONTROL|MOD_SHIFT,VK_SPACE)){SendMessageW(shortcut.window(),WM_HOTKEY,id,chord);};
        check(!shortcut.registered()&&!shortcut.window()&&commands.empty()&&added==0,"Constructing a global shortcut must reserve no key or capture");
        check(shortcut.configure(false,M::hold)&&!shortcut.window()&&added==0,"Disabled Voice must not create a native message window or register a shortcut");
        check(shortcut.configure(true,M::hold)&&shortcut.registered()&&added==1,"Opt-in must register without invoking capture");
        key_down();check(commands.empty(),"A posted hotkey without the physical chord must not start capture");
        pressed=true;key_down(3);key_down(GlobalVoiceShortcut::identifier,MAKELPARAM(MOD_ALT,VK_SPACE));check(commands.empty(),"Foreign hotkey identities or modifiers must be ignored");
        key_down();key_down();check(commands==std::vector<A>{A::begin},"An exact synthetic press must invoke once and ignore repeat messages");
        pressed=false;shortcut.poll();shortcut.poll();check(commands==std::vector<A>{A::begin,A::finish},"Native release polling must finish a hold exactly once");
        check(shortcut.configure(true,M::hold)&&added==1&&removed==0,"An unchanged configuration must not churn key registration");
        shortcut.configure(true,M::toggle);pressed=true;key_down();pressed=false;shortcut.poll();check(active&&commands.back()==A::begin,"Tap mode must remain active after key-up");
        pressed=true;key_down();pressed=false;shortcut.poll();check(!active&&commands.back()==A::finish,"A second tap must finish the latched capture");
        pressed=true;key_down();pressed=false;shortcut.poll();check(active,"The next explicit tap may begin another capture");
        const auto before=commands.size();shortcut.configure(false,M::toggle);check(!shortcut.registered()&&!shortcut.window()&&!active&&commands.size()==before+1&&commands.back()==A::cancel,"Disabling must unregister and cancel, never transcribe, an active recording");
        conflict=true;const auto before_conflict=commands.size();check(!shortcut.configure(true,M::hold)&&!shortcut.registered()&&!shortcut.window()&&commands.size()==before_conflict,"Registration conflicts must leave the shortcut inactive without capture");
        conflict=false;check(shortcut.configure(true,M::hold)&&shortcut.registered(),"An explicit later configuration can recover from a registration conflict");
        pressed=true;key_down();active=false;shortcut.poll();const auto after_failure=commands.size();key_down();check(commands.size()==after_failure,"An externally failed capture must not auto-restart while its key remains held");
        pressed=false;shortcut.poll();pressed=true;key_down();check(active&&commands.back()==A::begin,"A released and freshly pressed key may recover after capture failure");
        shortcut.close();const auto after_close=commands.size();shortcut.close();check(!shortcut.registered()&&!shortcut.window()&&!active&&commands.size()==after_close,"Repeated close must release the native resource and cancel only once");
        check(!shortcut.configure(true,M::hold),"A closed shortcut owner must not register another native window");
        std::ofstream output(report);output<<"PASS: "<<checks<<" injected Windows global dictation shortcut checks; no actual hotkey registration, microphone or engine\n";return output?0:2;
    }catch(const std::exception& error){std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';return 1;}
}
} // namespace coincide
