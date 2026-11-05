#pragma once
#include <stdexcept>

namespace coincide {
enum class VoiceShortcutMode { hold,toggle };
enum class VoiceShortcutAction { none,begin,finish,cancel };
// A key gesture owns only dictation capture, never message sending. Physical
// release is tracked separately so repeats cannot restart a failed/canceled hold.
class VoiceShortcutState {
    bool enabled_{},pressed_{},recording_{};
    VoiceShortcutMode mode_=VoiceShortcutMode::hold;
public:
    static bool valid(VoiceShortcutMode mode){return mode==VoiceShortcutMode::hold||mode==VoiceShortcutMode::toggle;}
    bool enabled()const{return enabled_;}bool pressed()const{return pressed_;}bool recording()const{return recording_;}
    VoiceShortcutMode mode()const{return mode_;}
    VoiceShortcutAction configure(bool enabled,VoiceShortcutMode mode){
        if(!valid(mode))throw std::invalid_argument("Unsupported voice shortcut behavior");
        const auto action=cancel();enabled_=enabled;mode_=mode;return action;
    }
    VoiceShortcutAction press(bool available){
        if(!enabled_||pressed_)return VoiceShortcutAction::none;pressed_=true;
        if(recording_){recording_=false;return VoiceShortcutAction::finish;}
        if(!available)return VoiceShortcutAction::none;recording_=true;return VoiceShortcutAction::begin;
    }
    VoiceShortcutAction release(){
        if(!pressed_)return VoiceShortcutAction::none;pressed_=false;
        if(mode_==VoiceShortcutMode::hold&&recording_){recording_=false;return VoiceShortcutAction::finish;}
        return VoiceShortcutAction::none;
    }
    void settled(){recording_=false;}
    VoiceShortcutAction cancel(){const bool active=recording_;recording_=false;pressed_=false;return active?VoiceShortcutAction::cancel:VoiceShortcutAction::none;}
};
} // namespace coincide
