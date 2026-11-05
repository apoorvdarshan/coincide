#pragma once
#include "../Core/VoiceShortcutState.h"
#include <windows.h>
#include <functional>
#include <utility>

namespace coincide {
// RegisterHotKey supplies key-down; a bounded UI-thread timer observes release.
// No keyboard hook, microphone access, or input injection is involved here.
class GlobalVoiceShortcut {
public:
    struct Backend {
        std::function<bool(HWND,int,UINT,UINT)> add=[](HWND window,int id,UINT modifiers,UINT key){return RegisterHotKey(window,id,modifiers,key)!=FALSE;};
        std::function<bool(HWND,int)> remove=[](HWND window,int id){return UnregisterHotKey(window,id)!=FALSE;};
        std::function<bool(int)> down=[](int key){return (GetAsyncKeyState(key)&0x8000)!=0;};
    };
    using Command=std::function<bool(VoiceShortcutAction)>;
    using Active=std::function<bool()>;
    static constexpr int identifier=0x4349;
    static constexpr UINT modifiers=MOD_CONTROL|MOD_SHIFT,key=VK_SPACE;
private:
    Backend backend_;Command command_;Active active_;VoiceShortcutState state_;
    HWND window_{};bool registered_{},closed_{};
    static constexpr wchar_t window_class[]=L"Coincide.GlobalVoiceShortcut";
    static LRESULT CALLBACK procedure(HWND window,UINT message,WPARAM first,LPARAM second){
        auto self=reinterpret_cast<GlobalVoiceShortcut*>(GetWindowLongPtrW(window,GWLP_USERDATA));
        if(message==WM_NCCREATE){self=static_cast<GlobalVoiceShortcut*>(reinterpret_cast<CREATESTRUCTW*>(second)->lpCreateParams);SetWindowLongPtrW(window,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self));}
        if(self)try{
            if(message==WM_HOTKEY){if(first==static_cast<WPARAM>(identifier)&&(LOWORD(second)&~MOD_NOREPEAT)==modifiers&&HIWORD(second)==key&&self->registered_&&self->held())self->apply(self->state_.press(!self->active_||!self->active_()));return 0;}
            if(message==WM_TIMER&&first==1){self->poll();return 0;}
        }catch(...){self->cancel();}
        return DefWindowProcW(window,message,first,second);
    }
    bool held()const{return backend_.down&&backend_.down(VK_CONTROL)&&backend_.down(VK_SHIFT)&&backend_.down(VK_SPACE);}
    void apply(VoiceShortcutAction action){if(action==VoiceShortcutAction::none)return;if(!command_||!command_(action))state_.settled();}
    bool make_window(){
        if(window_)return true;const auto module=GetModuleHandleW(nullptr);WNDCLASSW type{};type.lpfnWndProc=procedure;type.hInstance=module;type.lpszClassName=window_class;
        if(!RegisterClassW(&type)&&GetLastError()!=ERROR_CLASS_ALREADY_EXISTS)return false;
        window_=CreateWindowExW(0,window_class,L"",0,0,0,0,0,HWND_MESSAGE,nullptr,module,this);return window_!=nullptr;
    }
    void unregister()noexcept{
        if(window_){KillTimer(window_,1);if(registered_)try{if(backend_.remove)backend_.remove(window_,identifier);}catch(...){}registered_=false;DestroyWindow(window_);window_=nullptr;}
    }
public:
    GlobalVoiceShortcut(Command command,Active active):GlobalVoiceShortcut(std::move(command),std::move(active),Backend{}){}
    GlobalVoiceShortcut(Command command,Active active,Backend backend):backend_(std::move(backend)),command_(std::move(command)),active_(std::move(active)){}
    ~GlobalVoiceShortcut(){close();}
    GlobalVoiceShortcut(const GlobalVoiceShortcut&)=delete;GlobalVoiceShortcut& operator=(const GlobalVoiceShortcut&)=delete;
    bool configure(bool enabled,VoiceShortcutMode mode){
        if(closed_)return false;if(!VoiceShortcutState::valid(mode))throw std::invalid_argument("Unsupported voice shortcut behavior");
        if(!registered_&&!enabled){state_.configure(false,mode);return true;}
        if(registered_&&enabled&&state_.mode()==mode)return true;
        cancel();unregister();state_.configure(false,mode);if(!enabled)return true;
        if(!make_window())return false;
        bool added{};try{added=backend_.add&&backend_.add(window_,identifier,modifiers|MOD_NOREPEAT,key);}catch(...){unregister();return false;}
        if(!added){unregister();return false;}registered_=true;
        if(!SetTimer(window_,1,25,nullptr)){unregister();return false;}
        state_.configure(true,mode);return true;
    }
    void poll(){if(!registered_||closed_)return;if(state_.pressed()&&!held())apply(state_.release());if(state_.recording()&&active_&&!active_())state_.settled();}
    void cancel()noexcept{
        const auto action=state_.cancel();try{if(action!=VoiceShortcutAction::none||(active_&&active_()))if(command_)command_(VoiceShortcutAction::cancel);}catch(...){}
    }
    void close()noexcept{if(closed_)return;closed_=true;cancel();unregister();}
    bool registered()const{return registered_;}
    HWND window()const{return window_;}
};
} // namespace coincide
