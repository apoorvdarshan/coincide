#include "../Core/VoiceShortcutState.h"
#include <iostream>

namespace {unsigned checks{};void check(bool value,const char* reason){++checks;if(!value)throw std::runtime_error(reason);}}
int main(){using namespace coincide;using A=VoiceShortcutAction;using M=VoiceShortcutMode;try{
    VoiceShortcutState state;
    check(!state.enabled()&&!state.recording()&&state.press(true)==A::none,"An unconfigured shortcut must never request capture");
    check(state.configure(true,M::hold)==A::none&&state.enabled(),"Opting in must register behavior without starting capture");
    check(state.press(true)==A::begin&&state.pressed()&&state.recording(),"A fresh enabled hold must begin only one capture");
    check(state.press(true)==A::none,"Auto-repeat must not create another recording");
    check(state.release()==A::finish&&!state.recording()&&!state.pressed(),"Releasing a hold must request transcription once");
    check(state.release()==A::none,"An extra key-up must not finish twice");
    check(state.press(false)==A::none&&state.pressed()&&!state.recording(),"An unavailable destination must not capture even while its chord is held");
    check(state.press(true)==A::none,"A destination becoming available during a held key is not a new user gesture");
    check(state.release()==A::none&&state.press(true)==A::begin,"A new physical press can start after an unavailable gesture ends");
    state.settled();check(!state.recording()&&state.press(true)==A::none,"A failed capture must not restart from repeat before release");state.release();
    state.configure(true,M::toggle);check(state.press(true)==A::begin&&state.release()==A::none&&state.recording(),"The first tap must keep capture active after physical release");
    check(state.press(false)==A::finish&&!state.recording(),"A second tap must stop existing capture even when no new destination is available");
    check(state.press(true)==A::none&&state.release()==A::none,"Repeating the stop tap must not start a replacement recording");
    check(state.press(true)==A::begin&&state.cancel()==A::cancel&&!state.recording()&&!state.pressed(),"Explicit cancellation must discard capture and its gesture state");
    check(state.cancel()==A::none,"Cancellation must be idempotent when no capture exists");
    state.press(true);state.release();check(state.configure(false,M::toggle)==A::cancel&&!state.enabled(),"Disabling a latched shortcut must cancel without transcription");
    check(state.press(true)==A::none,"Disabled state must reject future presses");
    state.configure(true,M::hold);state.press(true);check(state.configure(true,M::toggle)==A::cancel&&!state.recording(),"Changing shortcut behavior must cancel the old held gesture");
    bool rejected{};try{state.configure(true,static_cast<M>(5));}catch(const std::invalid_argument&){rejected=true;}check(rejected&&state.enabled()&&state.mode()==M::toggle,"Invalid modes must preserve existing configuration");
    std::cout<<"PASS: "<<checks<<" voice shortcut gesture checks\n";return 0;
}catch(const std::exception& error){std::cerr<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';return 1;}}
