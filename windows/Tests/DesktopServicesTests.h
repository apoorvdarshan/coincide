#pragma once
#include "../Runtime/DesktopServices.h"
#include <fstream>
namespace coincide {
inline int desktop_services_tests(const std::filesystem::path& report){
    int checks{};auto check=[&](bool value,const char* message){++checks;if(!value)throw std::runtime_error(message);};
    const auto root=std::filesystem::temp_directory_path()/(L"Coincide-desktop-policy-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    struct Cleanup{std::filesystem::path value;~Cleanup(){std::error_code ignored;std::filesystem::remove_all(value,ignored);}} cleanup{root};
    try{
        check(power_demand({},true)==PowerDemand{}&&power_demand({},false)==PowerDemand{},"Disabled Keep Awake must make no sleep or display request");
        check(power_demand({true,false,false},true)==PowerDemand{true,false},"Charger-only Keep Awake must request system activity on AC");
        check(power_demand({true,false,true},false)==PowerDemand{},"Charger-only policy must release every request on battery");
        check(power_demand({true,true,true},false)==PowerDemand{true,true},"Battery and display requests require explicit independent options");
        check(power_demand({false,true,true},true)==PowerDemand{},"Dependent options must not enable a disabled master");
        PowerRequest request;request.update({});check(request.current()==PowerDemand{},"The actual native controller must leave power settings untouched by default");request.close();request.close();check(request.current()==PowerDemand{},"Repeated teardown must retain no sleep request");
        std::filesystem::create_directories(root);DesktopServices first(root);check(first.primary(),"A fresh user/data scope must own its instance");
        check(!first.tray_available(),"Background construction must not create a tray icon until a real owner is attached");
        DesktopServices duplicate(root/L".");check(!duplicate.primary(),"Canonical aliases must activate the existing data-folder instance");
        DesktopServices sibling(root/L"sibling");check(sibling.primary(),"Another data folder must retain an independent instance");
        duplicate.close();sibling.close();first.close();DesktopServices reopened(root);check(reopened.primary(),"Closing every owner handle must release the instance reservation");reopened.close();
        bool rejected{};try{DesktopServices invalid(L"relative");}catch(const std::invalid_argument&){rejected=true;}check(rejected,"Instance scope must not depend on the current working folder");
        std::ofstream output(report);output<<"PASS: "<<checks<<" Windows desktop lifetime/power checks\n";return output?0:2;
    }catch(const winrt::hresult_error& error){std::ofstream(report)<<"FAIL: "<<winrt::to_string(error.message())<<'\n';}catch(const std::exception& error){std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';}return 1;
}
}
