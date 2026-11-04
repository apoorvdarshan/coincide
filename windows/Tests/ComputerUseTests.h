#pragma once
#include "../Runtime/ComputerUsePolicy.h"
#include <filesystem>
#include <fstream>

namespace coincide {
// Pure policy/injected backend fixtures. Never create a real UIA object, query windows, capture
// pixels, move the cursor, type input, prompt for permissions, or start a native helper.
inline int computer_use_tests(const std::filesystem::path& report){
    using namespace computer_use;
    struct Fake final:Backend {
        std::uint64_t epoch{1};unsigned calls{},actions{},stops{};bool huge{},too_many{},protected_image{},unrequested_image{};
        std::function<void()> before;std::vector<Object> requests;
        Object request(const Object& request,const std::function<bool()>& cancelled)override{
            ++calls;requests.push_back(Object::Parse(request.Stringify()));if(before)before();if(cancelled())throw std::runtime_error("Synthetic revocation");Object result;const auto operation=text(request,L"operation");
            if(operation=="get_window_state"){Array elements;for(unsigned index=0;index<(too_many?513u:1u);++index){Object item;put(item,L"native_token",std::string(32,'a'));put(item,L"name","Synthetic native button");elements.Append(item);}Object secret;secret.SetNamedValue(L"protected",Value::CreateBooleanValue(true));put(secret,L"name","SECRET-FIXTURE");put(secret,L"native_token",std::string(32,'b'));elements.Append(secret);result.SetNamedValue(L"elements",elements);
                if(request.GetNamedObject(L"arguments").GetNamedBoolean(L"include_screenshot",false)||unrequested_image){Object image;put(image,L"mimeType","image/png");put(image,L"data","SYNTHETIC-IMAGE-NOT-REAL-PIXELS");result.SetNamedValue(L"image",image);put(result,L"native_screenshot_token",std::string(32,'c'));}if(protected_image)result.SetNamedValue(L"protected_content",Value::CreateBooleanValue(true));
            }else if(operation=="list_windows"||operation=="list_apps"){Array list;Object window;window.SetNamedValue(L"pid",Value::CreateNumberValue(42));put(window,L"window_id","abc");put(window,L"title","Synthetic native window");list.Append(window);result.SetNamedValue(operation=="list_windows"?L"windows":L"apps",list);}
            else{++actions;result.SetNamedValue(L"dispatched",Value::CreateBooleanValue(true));}
            if(huge)put(result,L"oversized",std::string(4*1024*1024,'x'));return result;
        }
        std::uint64_t generation()const override{return epoch;}
        void stop()noexcept override{++stops;++epoch;}
    };
    int checks{};auto check=[&](bool condition,const char* message){++checks;if(!condition)throw std::runtime_error(message);};auto rejects=[&](auto operation,const char* message){bool denied{};try{operation();}catch(...){denied=true;}check(denied,message);};
    try{
        const std::string a="{65e2f1d1-cc61-40b5-95bd-d29c345c444c}",b="{05bd2cb4-5b1b-4dba-9a2c-89d9ea45801c}";std::uint64_t now=1000;auto backend=std::make_shared<Fake>();Controller controller(backend,[&]{return now;});
        auto call=[&](const std::string& thread,const std::string& name,Object args=Object{}){Object request;put(request,L"action","call");put(request,L"name",name);request.SetNamedValue(L"arguments",args);return controller.perform(thread,winrt::to_string(request.Stringify()));};
        auto args=[](){Object value;value.SetNamedValue(L"pid",Value::CreateNumberValue(42));put(value,L"window_id","abc");return value;};
        auto observe=[&](const std::string& thread,bool image=false){auto value=args();if(image)value.SetNamedValue(L"include_screenshot",Value::CreateBooleanValue(true));return call(thread,"get_window_state",value);};
        auto click=[&](const std::string& thread,const std::string& token){auto value=args();put(value,L"element_token",token);return call(thread,"click",value);};
        auto token=[&](const std::string& thread){return text(observe(thread).GetNamedArray(L"elements").GetObjectAt(0),L"element_token");};
        rejects([&]{controller.grant(a,{true,true,true});},"Disabled Computer Use must not grant a thread access");rejects([&]{call(a,"list_windows");},"Default-off requests must fail before reaching any backend");check(!backend->calls,"Default-off construction must not inspect the real desktop");
        controller.set_enabled(true);rejects([&]{call(a,"list_windows");},"Global enable must not silently grant any thread permission");
        rejects([&]{controller.grant(a,{false,true,false});},"Capture cannot imply window-read permission");rejects([&]{controller.grant(a,{false,false,true});},"Input cannot imply window-read permission");controller.grant(a,{true,false,false});
        const auto state=controller.snapshot(a);check(state.enabled&&state.granted&&state.permission.read_windows&&!state.permission.capture_windows&&!state.permission.input&&controller.snapshot(b).desktop=="free"&&!controller.snapshot(b).granted&&!backend->calls,"The native settings snapshot must expose only current permission/status metadata without touching the backend");
        const auto catalog=controller.perform(a,R"({"action":"tools"})").GetNamedArray(L"tools");check(catalog.Size()==6&&!backend->calls,"The explicit Windows tool catalog must not start a helper");
        for(const auto& raw:catalog){const auto tool=raw.GetObject();check(tool.HasKey(L"inputSchema")&&!tool.GetNamedObject(L"inputSchema").GetNamedBoolean(L"additionalProperties"),"Every implemented tool must expose a closed native argument schema");}
        check(call(a,"list_windows").GetNamedArray(L"windows").Size()==1&&call(a,"list_apps").GetNamedArray(L"apps").Size()==1,"A granted reader may inspect synthetic apps/windows without input permission");
        const auto observation=observe(a);const auto elements=observation.GetNamedArray(L"elements");const auto old=text(elements.GetObjectAt(0),L"element_token");
        check(old.size()==32&&!elements.GetObjectAt(0).HasKey(L"native_token"),"Native identifiers must be replaced with fresh per-thread public tokens");
        check(elements.GetObjectAt(1).Size()==1&&elements.GetObjectAt(1).GetNamedBoolean(L"protected")&&winrt::to_string(observation.Stringify()).find("SECRET-FIXTURE")==std::string::npos,"Protected controls must expose neither values/names nor actionable tokens");
        const auto before=backend->calls;rejects([&]{click(a,old);},"Read-only grants must not permit native input");rejects([&]{observe(a,true);},"Window capture requires its own explicit permission");check(backend->calls==before,"Permission denial must precede all backend activity");
        for(const auto* request:{R"({"action":"grant"})",R"({"action":"status","session":"other"})",R"({"action":"call","name":"run_script","arguments":{}})",R"({"action":"call","name":"browser_navigate","arguments":{"url":"https://example.invalid"}})",R"({"action":"call","name":"list_windows","arguments":{"ENV":{}}})",R"({"action":"call","name":"list_windows","arguments":{"_internal":true}})",R"({"action":"call","name":"get_window_state","arguments":{"pid":42,"window_id":"abc","max_elements":513}})",R"({"action":"call","name":"get_window_state","arguments":{"pid":42.5,"window_id":"abc"}})",R"({"action":"call","name":"get_window_state","arguments":{"pid":42,"window_id":"../other"}})",R"({"action":"call","name":"get_window_state","arguments":{"pid":42,"window_id":"abc","include_screenshot":"yes"}})"})rejects([&]{controller.perform(a,request);},"Reserved/script/browser/transport options and malformed bounds must fail before native dispatch");
        rejects([&]{controller.perform(a,std::string(262145,'x'));},"Oversized public requests must be rejected before parsing");check(backend->calls==before,"Malformed public requests must never reach the helper");
        controller.grant(a,{true,true,true});controller.grant(b,{true,true,true});const auto fresh=token(a);rejects([&]{click(a,old);},"Replacing a grant must invalidate its earlier observations");
        rejects([&]{click(b,fresh);},"An element capability must not transfer to another thread");auto wrong=args();wrong.SetNamedValue(L"pid",Value::CreateNumberValue(43));put(wrong,L"element_token",fresh);rejects([&]{call(a,"click",wrong);},"An element capability must be bound to the exact observed process");wrong=args();put(wrong,L"window_id","def");put(wrong,L"element_token",fresh);rejects([&]{call(a,"click",wrong);},"An element capability must be bound to the exact observed HWND");
        check(click(a,fresh).GetNamedBoolean(L"dispatched")&&backend->actions==1,"A fresh exact-window token may dispatch one approved native action");rejects([&]{click(a,fresh);},"An input token must be single-use and never replayed");
        const auto other=token(b);const auto busy_count=backend->calls;rejects([&]{click(b,other);},"Only one thread may hold the shared input lease");check(call(b,"list_windows").HasKey(L"windows")&&backend->calls==busy_count+1,"Another thread may still read while the desktop belongs to the action owner");
        controller.perform(a,R"({"action":"release"})");check(click(b,other).GetNamedBoolean(L"dispatched"),"Release must free the desktop without increasing any permission");controller.release(b);
        auto expiring=token(a);now+=30001;rejects([&]{click(a,expiring);},"Old element tokens must expire before native input");auto changed=token(a);++backend->epoch;rejects([&]{click(a,changed);},"A helper restart must invalidate every native observation");
        auto replaced=token(a);const auto newer=token(a);rejects([&]{click(a,replaced);},"Reobserving the same thread/window must invalidate its previous element snapshot");check(click(a,newer).GetNamedBoolean(L"dispatched"),"Only the latest observation may act");controller.release(a);
        const auto captured=observe(a,true);const auto screenshot=text(captured,L"screenshot_token");check(captured.HasKey(L"image")&&!captured.HasKey(L"native_screenshot_token"),"Explicit synthetic captures must get a fresh public screenshot token");
        auto pixel=args();put(pixel,L"screenshot_token",screenshot);pixel.SetNamedValue(L"x",Value::CreateNumberValue(10));pixel.SetNamedValue(L"y",Value::CreateNumberValue(20));now+=15001;rejects([&]{call(a,"click",pixel);},"Pixel input requires a newer exact-target screenshot than ordinary UIA input");
        auto both=args();put(both,L"element_token",token(a));put(both,L"screenshot_token",screenshot);rejects([&]{call(a,"click",both);},"Pixel and element action forms must not be mixed");
        backend->unrequested_image=true;rejects([&]{observe(a);},"A helper may not attach an unrequested screenshot");backend->unrequested_image=false;backend->protected_image=true;rejects([&]{observe(a,true);},"A helper capture containing protected content must be denied at the policy boundary too");backend->protected_image=false;
        backend->too_many=true;rejects([&]{observe(a);},"Helper element output must remain within its independent bound");backend->too_many=false;backend->huge=true;rejects([&]{call(a,"list_windows");},"Helper result size must be bounded independently of agent request size");backend->huge=false;
        const auto revoked=token(a);controller.revoke(a);rejects([&]{click(a,revoked);},"Revocation must end one thread's input capability immediately");check(call(b,"list_windows").HasKey(L"windows"),"Revoking one thread must preserve other explicit reader grants");
        controller.grant(a,{true,true,true});backend->before=[&]{controller.revoke(a);};rejects([&]{observe(a);},"Revocation during observation must suppress its result and tokens");backend->before={};controller.grant(a,{true,true,true});
        const auto interrupted=token(a);const auto actions=backend->actions;backend->before=[&]{controller.revoke(a);};rejects([&]{click(a,interrupted);},"A backend must see revocation before an in-flight action side effect");check(backend->actions==actions,"Cancelled native actions must not be automatically retried");backend->before={};
        controller.grant(a,{true,true,true});const auto idle=token(a);now+=120001;const auto stops=backend->stops;controller.idle_tick();check(backend->stops==stops+1,"An idle helper must stop without expanding or revoking saved explicit permissions");rejects([&]{click(a,idle);},"Idle helper stop must invalidate all outstanding observations");check(call(a,"list_windows").HasKey(L"windows"),"An explicit reader grant may start a fresh helper after idle stop");
        controller.set_enabled(false);rejects([&]{call(a,"list_windows");},"Turning Computer Use off must revoke all thread access");controller.set_enabled(true);rejects([&]{call(a,"list_windows");},"Re-enabling the master must not restore old thread grants implicitly");
        std::ofstream output(report);output<<"PASS: "<<checks<<" Windows Computer Use policy checks (synthetic backend; no UIA, capture or input)\n";return output?0:2;
    }catch(const winrt::hresult_error& error){std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<winrt::to_string(error.message())<<'\n';}catch(const std::exception& error){std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';}return 1;
}
} // namespace coincide
