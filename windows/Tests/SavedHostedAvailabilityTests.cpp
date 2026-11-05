#include "../Core/SavedHostedAvailability.h"
#include <iostream>
#include <stdexcept>

namespace {unsigned checks{};void check(bool value,const char* why){++checks;if(!value)throw std::runtime_error(why);}}
int main(){using coincide::SavedHostedAvailability;try{
    SavedHostedAvailability state;
    check(!state.needs_review(),"Ordinary conversations must not be blocked by hosted-only availability policy");
    state.enabled=true;check(!state.needs_review(),"A fresh conversation without a saved generation needs no recovery");
    state.saved_epoch="original-epoch";check(state.needs_review(),"An initial saved marker without a journal must preserve uncertainty and block new input");
    state.journal_epoch="original-epoch";check(!state.needs_review(),"Matching saved routing must retain normal verified-runtime behavior");
    state.runtime_unmatched=true;check(state.needs_review(),"A restored generation absent from the current host must not authorize a new provider");
    state.runtime_unmatched=false;state.journal_epoch="other-epoch";check(state.needs_review(),"Mismatched journal and saved epochs require review rather than silent rebinding");
    state.saved_epoch.reset();check(state.needs_review(),"A saved journal without its matching transcript cursor must not be treated as fresh");
    state.journal_retired=true;check(!state.needs_review(),"An explicitly retired journal must preserve the existing separate fresh-start contract");
    state.metadata_available=false;check(state.needs_review(),"Unreadable metadata cannot become a retired-or-fresh shortcut");
    state.enabled=false;check(!state.needs_review(),"Non-hosted providers must not acquire hosted metadata dependencies");
    state.enabled=true;state.metadata_available=true;state.journal_retired=false;state.saved_epoch="";state.journal_epoch="";
    check(state.needs_review(),"Present but empty routing epochs must not be accepted as matching proof");
    const auto before=state.saved_epoch;check(state.needs_review()&&state.saved_epoch==before,"Availability inspection must not erase or change the original saved marker");
    std::cout<<"PASS: "<<checks<<" saved hosted availability checks\n";return 0;
}catch(const std::exception& error){std::cerr<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';return 1;}}
