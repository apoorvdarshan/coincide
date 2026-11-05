#pragma once
#include "../App/NativeUserPrompt.h"
#include "InstructionImportPanelTests.h"
#include <atomic>
#include <filesystem>
#include <fstream>

namespace coincide {
inline int native_user_prompt_tests(const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& root){
    namespace f=instruction_import_panel_fixture;using Status=winrt::Windows::Foundation::AsyncStatus;std::size_t checks{};
    const auto check=[&](bool value,const char* message){if(!value)throw std::runtime_error(message);++checks;};
    try{
        auto cancelled=std::make_shared<std::atomic<bool>>(true);auto before=native_user_prompt(root,L"Owned handoff",L"Synthetic only",L"Done",GetTickCount64()+5000,[cancelled]{return cancelled->load();});
        check(f::until([&]{return before.Status()!=Status::Started;})&&before.GetResults()==L"cancelled","A revoked request must never open an actionable handoff");
        cancelled->store(false);auto timeout=native_user_prompt(root,L"Owned timeout",L"Synthetic only",L"Done",GetTickCount64()+150);
        check(f::until([&]{return timeout.Status()!=Status::Started;})&&timeout.GetResults()==L"timeout","An unattended handoff must time out without approving an action");
        auto pending=native_user_prompt(root,L"Owned cancellation",L"Synthetic only",L"Done",GetTickCount64()+5000,[cancelled]{return cancelled->load();});f::pump();cancelled->store(true);
        check(f::until([&]{return pending.Status()!=Status::Started;})&&pending.GetResults()==L"cancelled","Revocation must dismiss a pending handoff without an owner decision");
        std::ofstream output(report);output<<"PASS: "<<checks<<" native owner-handoff cancellation/timeout checks\n";return output?0:2;
    }catch(const winrt::hresult_error& error){std::ofstream(report)<<"FAIL: "<<winrt::to_string(error.message())<<'\n';}
    catch(const std::exception& error){std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';}return 1;
}
} // namespace coincide
