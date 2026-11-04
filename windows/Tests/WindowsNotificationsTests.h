#pragma once
#include "../Runtime/WindowsNotifications.h"
#include <winrt/Windows.Data.Xml.Dom.h>
#include <fstream>

namespace coincide {
inline int windows_notifications_tests(const std::filesystem::path& report){
    using Object=winrt::Windows::Data::Json::JsonObject;using Value=winrt::Windows::Data::Json::JsonValue;
    struct FixtureTransport final:WindowsNotificationTransport {
        Invoked invoked;int starts{},stops{};bool allowed{true},fail_show{},fail_remove{};HANDLE removal_gate{};
        std::vector<WindowsNotificationPayload> shown;std::vector<std::pair<std::string,std::string>> removed;std::vector<std::string> groups;
        std::function<void(const WindowsNotificationPayload&)> before_show;
        void start(Invoked value)override{++starts;invoked=std::move(value);}
        void stop()noexcept override{++stops;invoked={};}
        bool permitted()override{return allowed;}
        void show(const WindowsNotificationPayload& value)override{if(before_show)before_show(value);if(fail_show)throw std::runtime_error("Synthetic notification send failure");shown.push_back(value);}
        winrt::Windows::Foundation::IAsyncAction remove(std::string tag,std::string group)override{removed.emplace_back(std::move(tag),std::move(group));if(fail_remove)throw std::runtime_error("Synthetic removal failure");if(removal_gate)co_await winrt::resume_on_signal(removal_gate);}
        winrt::Windows::Foundation::IAsyncAction remove_group(std::string group)override{groups.push_back(std::move(group));if(fail_remove)throw std::runtime_error("Synthetic group removal failure");co_return;}
    };
    int checks{};auto check=[&](bool condition,const char* message){++checks;if(!condition)throw std::runtime_error(message);};
    auto rejects=[&](auto operation,const char* message){bool rejected{};try{operation();}catch(...){rejected=true;}check(rejected,message);};
    const auto root=std::filesystem::temp_directory_path()/(L"Coincide-notification-fixtures-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    struct Cleanup{std::filesystem::path path;~Cleanup(){std::error_code ignored;std::filesystem::remove_all(path,ignored);}} cleanup{root};
    const std::string first="{65e2f1d1-cc61-40b5-95bd-d29c345c444c}",second="{05bd2cb4-5b1b-4dba-9a2c-89d9ea45801c}";
    const auto a=root/L"scope-a",b=root/L"scope-b",file=a/L"notification-routes.json";
    auto bytes=[&](const std::filesystem::path& path){std::ifstream input(path,std::ios::binary);return std::string((std::istreambuf_iterator<char>(input)),{});};
    auto write=[&](const std::filesystem::path& path,std::string text){std::ofstream output(path,std::ios::binary|std::ios::trunc);output<<text;};
    std::int64_t clock=1800000000;std::vector<std::string> activated;std::set<std::string> denied;std::vector<std::function<void()>> posted;
    auto post=[&](std::function<void()> action){posted.push_back(std::move(action));return true;};
    auto eligible=[&](const std::string& thread){return !denied.contains(thread);};
    auto activate=[&](std::string thread){activated.push_back(std::move(thread));};
    auto transport=std::make_shared<FixtureTransport>();
    try{
        auto controller=WindowsNotifications::create(a,post,activate,eligible,transport,[&]{return clock;});
        check(!controller->enabled()&&transport->starts==0&&transport->shown.empty(),"Default-off construction must not register or send OS notifications");
        check(!controller->notify(first,L"Title",L"Body")&&!std::filesystem::exists(file),"Disabled delivery must not create routing state");
        rejects([&]{WindowsNotifications::create(L"relative",post,activate,eligible,transport);},"Data scope must not depend on a current working folder");
        transport->allowed=false;rejects([&]{controller->set_enabled(true).get();},"An OS permission denial must be explicit when enabling");check(!controller->enabled()&&transport->shown.empty(),"A denied native registration must leave delivery disabled");transport->allowed=true;
        controller->set_enabled(true).get();check(controller->enabled()&&transport->starts==2,"Explicit enable must register only the injected transport");
        controller->set_enabled(true).get();check(transport->starts==2,"Repeated enable must retain a single native registration");
        bool prepared_before_send{};transport->before_show=[&](const auto&){const auto document=Object::Parse(winrt::to_hstring(bytes(file)));prepared_before_send=!document.GetNamedArray(L"routes").GetObjectAt(0).GetNamedBoolean(L"delivered");};
        const std::wstring title=L"会話 & <text> \"double\" 'single'",body=L"A literal </text><actions/> and emoji \U0001f680";
        check(controller->notify(first,title,body),"An eligible conversation must create a synthetic notification");
        check(prepared_before_send,"Routing must be durable but not activatable before the sender accepts it");
        transport->before_show={};const auto first_payload=transport->shown.back();
        check(first_payload.argument.size()==122&&first_payload.group.size()==16&&first_payload.tag.size()==16,"Activation arguments and OS tag/group identifiers must be bounded");
        check(first_payload.thread_id==first&&first_payload.argument.find(first)==std::string::npos&&first_payload.argument.find("scope-a")==std::string::npos,"Untrusted activation text must contain no path or arbitrary thread arguments");
        winrt::Windows::Data::Xml::Dom::XmlDocument xml;xml.LoadXml(first_payload.xml);
        check(xml.DocumentElement().GetAttribute(L"launch")==winrt::to_hstring(first_payload.argument)&&xml.DocumentElement().GetAttribute(L"activationType")==L"foreground","The native payload must request only the strict foreground activation route");
        const auto texts=xml.GetElementsByTagName(L"text");
        check(texts.Size()==2&&texts.GetAt(0).InnerText()==title&&texts.GetAt(1).InnerText()==body,"XML escaping must preserve Unicode/text without injecting actions");
        check(xml.GetElementsByTagName(L"actions").Size()==0&&xml.GetElementsByTagName(L"audio").Item(0).Attributes().GetNamedItem(L"silent").NodeValue().as<winrt::hstring>()==L"true","Payloads must contain no action or audible-sound instruction");
        check(bytes(file).find("会話")==std::string::npos&&bytes(file).find("Body")==std::string::npos,"Persistent routing metadata must not retain message/title text");
        const auto initial=bytes(file);rejects([&]{controller->notify(first,std::wstring(257,L'x'),L"Body");},"Oversized titles must fail before delivery");
        rejects([&]{controller->notify(first,L"Title",std::wstring(L"bad\0text",8));},"Embedded NUL must never enter notification XML");
        rejects([&]{controller->notify(first,L"Title",std::wstring(1,static_cast<wchar_t>(0xd800)));},"Malformed UTF-16 must fail safely");
        rejects([&]{controller->notify(first,std::wstring(256,L'<'),std::wstring(1024,L'&'));},"Escaped payload size must be bounded after expansion");
        rejects([&]{controller->notify("../../other",L"Title",L"Body");},"Conversation identity must not be a path or shell argument");
        check(bytes(file)==initial&&transport->shown.size()==1,"Malformed payloads must preserve existing notification state");
        denied.insert(second);check(!controller->notify(second,L"Hidden",L"Body"),"Unavailable conversation targets must never be sent");denied.clear();
        transport->allowed=false;rejects([&]{controller->notify(second,L"Title",L"Body");},"A changed OS permission must fail explicitly before delivery");check(transport->shown.size()==1,"OS notification denial must not save or send a route");transport->allowed=true;
        check(controller->notify(second,L"Second",L"Body"),"A second conversation must have an independent notification");const auto second_payload=transport->shown.back();
        check(second_payload.group==first_payload.group&&second_payload.tag!=first_payload.tag,"Per-thread tags must share only their scoped app-data group");
        controller->notify(first,L"Replaced",L"Body");const auto replacement=transport->shown.back();
        check(replacement.tag==first_payload.tag&&replacement.argument!=first_payload.argument&&!controller->activate(first_payload.argument),"Replacement must invalidate the older token without changing its per-thread tag");
        check(!controller->activate("https://example.invalid/")&&!controller->activate(replacement.argument+"&command=quit"),"Arbitrary URLs and appended activation fields must be denied");
        auto malformed=replacement.argument;malformed.back()='G';check(!controller->activate(malformed),"Tokens must accept only canonical lowercase hexadecimal");
        malformed=replacement.argument;malformed[25]=malformed[25]=='0'?'1':'0';check(!controller->activate(malformed),"Another data/user scope must never activate the current window");
        malformed=replacement.argument;malformed.replace(90,32,std::string(32,'a'));check(!controller->activate(malformed),"Unknown capabilities must not route merely because their shape is valid");
        transport->invoked(second_payload.argument);check(activated.empty()&&posted.size()==1,"Native callbacks must post to the UI dispatcher instead of touching state on their event thread");
        auto work=std::move(posted.back());posted.clear();work();check(activated==std::vector<std::string>{second},"A notification click must select its own conversation rather than the latest balloon");
        check(!controller->activate(second_payload.argument)&&Object::Parse(winrt::to_hstring(bytes(file))).GetNamedArray(L"routes").Size()==1,"Consumed activation must be persisted once before any caller callback");
        denied.insert(first);check(!controller->activate(replacement.argument),"Archived/deleted/missing targets must be denied at activation too");denied.clear();
        check(!controller->activate(replacement.argument),"Restoring an unavailable target must not resurrect the discarded notification capability");
        controller->notify(first,L"Dismiss",L"Body");const auto dismissed=transport->shown.back();controller->dismiss(first).get();
        check(transport->removed.back()==std::pair{dismissed.tag,dismissed.group}&&!controller->activate(dismissed.argument),"Dismiss must invalidate and remove only its own thread tag/group");
        controller->notify(first,L"Pending removal",L"Body");transport->removal_gate=CreateEventW(nullptr,TRUE,FALSE,nullptr);if(!transport->removal_gate)winrt::throw_last_error();
        auto pending_removal=controller->dismiss(first);const bool blocked=!controller->notify(first,L"Replacement must wait",L"Body");
        auto removal_done=std::make_shared<winrt::handle>(CreateEventW(nullptr,TRUE,FALSE,nullptr));if(!*removal_done)winrt::throw_last_error();
        pending_removal.Completed([removal_done](const auto&,const auto&){SetEvent(removal_done->get());});SetEvent(transport->removal_gate);
        HANDLE done_handle=removal_done->get();DWORD completed_index{};const auto wait=CoWaitForMultipleHandles(COWAIT_DISPATCH_CALLS|COWAIT_DISPATCH_WINDOW_MESSAGES,5000,1,&done_handle,&completed_index);
        const bool removed_in_time=SUCCEEDED(wait)&&pending_removal.Status()!=winrt::Windows::Foundation::AsyncStatus::Started;
        if(removed_in_time){pending_removal.get();CloseHandle(transport->removal_gate);transport->removal_gate=nullptr;}
        check(removed_in_time&&blocked,"Pending native dismissal must block a same-tag replacement until completion");
        controller->notify(first,L"Removal failure",L"Body");const auto removal_failure=transport->shown.back();transport->fail_remove=true;
        rejects([&]{controller->dismiss(first).get();},"Native removal failures must remain visible to the caller");
        check(!controller->activate(removal_failure.argument),"A failed OS removal must still deny the stale persisted activation");transport->fail_remove=false;
        transport->fail_show=true;rejects([&]{controller->notify(first,L"Send failure",L"Body");},"Native send failures must remain explicit");
        check(Object::Parse(winrt::to_hstring(bytes(file))).GetNamedArray(L"routes").Size()==0,"A failed delivery must revoke its prepared routing token");transport->fail_show=false;
        controller->notify(first,L"Reopen",L"Body");const auto reopened_payload=transport->shown.back();const auto group=controller->group();controller->close();
        check(!controller->activate(reopened_payload.argument),"Closed controllers must ignore delayed native activation callbacks");
        auto reopened_transport=std::make_shared<FixtureTransport>();controller=WindowsNotifications::create(a/L".",post,activate,eligible,reopened_transport,[&]{return clock;});controller->set_enabled(true).get();
        check(controller->group()==group&&controller->activate(reopened_payload.argument),"The same physical user/data scope must validate a durable unexpired click after restart");
        auto sibling_transport=std::make_shared<FixtureTransport>();auto sibling=WindowsNotifications::create(b,post,activate,eligible,sibling_transport,[&]{return clock;});sibling->set_enabled(true).get();
        controller->notify(first,L"Scoped",L"Body");const auto scoped=reopened_transport->shown.back();
        check(sibling->group()!=group&&!sibling->activate(scoped.argument),"Independent data roots must not accept one another's capabilities");sibling->close();
        clock+=86400;check(!controller->activate(scoped.argument),"A notification at its exact expiration must not activate");clock-=86400;
        --clock;check(!controller->activate(scoped.argument),"A clock rollback must not accept a notification before its creation");++clock;
        const auto before_lock=bytes(file);HANDLE lock=CreateFileW((a/L"notification-routes.lock").c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
        check(lock!=INVALID_HANDLE_VALUE,"The notification fixture writer lock must open");const auto sent_count=reopened_transport->shown.size(),activation_count=activated.size();
        rejects([&]{controller->notify(second,L"Locked",L"Body");},"A storage lock must fail before any OS delivery");
        rejects([&]{controller->activate(scoped.argument);},"An activation cannot route before its consumption is durable");
        check(reopened_transport->shown.size()==sent_count&&activated.size()==activation_count&&bytes(file)==before_lock,"Storage failure must leave current routes and callbacks unchanged");
        rejects([&]{controller->set_enabled(false).get();},"Disable must report a metadata write failure explicitly");
        check(!controller->enabled()&&!controller->activate(scoped.argument),"A failed disable write must still stop current-process activation immediately");CloseHandle(lock);
        controller->set_enabled(true).get();check(!controller->activate(scoped.argument),"Recovery must clear uncertain old routes before registering again");
        controller->notify(first,L"Disable",L"Body");const auto disabled=reopened_transport->shown.back();controller->set_enabled(false).get();
        check(!controller->enabled()&&!controller->activate(disabled.argument)&&reopened_transport->groups.back()==group,"Disable must invalidate every owned route and remove only the matching scoped group");
        controller->set_enabled(true).get();check(!controller->activate(disabled.argument),"Re-enabling must not resurrect dismissed notifications");
        controller->notify(first,L"Unknown fields",L"Body");controller->close();auto document=Object::Parse(winrt::to_hstring(bytes(file)));document.SetNamedValue(L"future",Value::CreateBooleanValue(true));
        document.GetNamedArray(L"routes").GetObjectAt(0).SetNamedValue(L"futureRoute",Value::CreateNumberValue(7));write(file,winrt::to_string(document.Stringify()));
        auto final_transport=std::make_shared<FixtureTransport>();controller=WindowsNotifications::create(a,post,activate,eligible,final_transport,[&]{return clock;});controller->set_enabled(true).get();controller->notify(first,L"Preserve",L"Body");
        auto preserved=Object::Parse(winrt::to_hstring(bytes(file)));check(preserved.GetNamedBoolean(L"future")&&preserved.GetNamedArray(L"routes").GetObjectAt(0).GetNamedNumber(L"futureRoute")==7,"Unknown root and per-route fields must survive known updates");
        auto stale_transport=std::make_shared<FixtureTransport>();auto stale=WindowsNotifications::create(a,post,activate,eligible,stale_transport,[&]{return clock;});stale->set_enabled(true).get();controller->notify(second,L"Changed",L"Body");const auto latest=bytes(file);
        rejects([&]{stale->notify(first,L"Stale",L"Body");},"A stale controller must not overwrite another process's route changes");check(stale_transport->shown.empty()&&bytes(file)==latest,"Stale-writer failure must precede delivery and preserve all current metadata");stale->close();
        // Simulate a crash after Show accepted but before the sent-marker commit. A prepared
        // route is never valid on restart, even when cleanup itself could not acquire storage.
        HANDLE send_lock=INVALID_HANDLE_VALUE;final_transport->before_show=[&](const auto&){send_lock=CreateFileW((a/L"notification-routes.lock").c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);};
        rejects([&]{controller->notify(first,L"Uncertain delivery",L"Body");},"A post-send commit failure must not silently advertise successful delivery");
        check(send_lock!=INVALID_HANDLE_VALUE&&!controller->enabled(),"Uncertain delivery plus failed cleanup must disable this controller");CloseHandle(send_lock);final_transport->before_show={};const auto uncertain=final_transport->shown.back();controller->close();
        auto recovered_transport=std::make_shared<FixtureTransport>();controller=WindowsNotifications::create(a,post,activate,eligible,recovered_transport,[&]{return clock;});controller->set_enabled(true).get();
        check(!controller->activate(uncertain.argument),"A restart must prune every prepared-but-unconfirmed delivery capability");controller->close();
        const auto good=bytes(file);document=Object::Parse(winrt::to_hstring(good));auto duplicate=document.GetNamedArray(L"routes");duplicate.Append(duplicate.GetAt(0));write(file,winrt::to_string(document.Stringify()));
        rejects([&]{WindowsNotifications::create(a,post,activate,eligible,recovered_transport);},"Duplicate persisted route identities must fail closed");
        document=Object::Parse(winrt::to_hstring(good));document.GetNamedArray(L"routes").GetObjectAt(0).SetNamedValue(L"delivered",Value::CreateStringValue(L"yes"));write(file,winrt::to_string(document.Stringify()));
        rejects([&]{WindowsNotifications::create(a,post,activate,eligible,recovered_transport);},"Persisted permission/confirmation booleans must never be coerced");
        document=Object::Parse(winrt::to_hstring(good));document.SetNamedValue(L"version",Value::CreateNumberValue(2));write(file,winrt::to_string(document.Stringify()));const auto future=bytes(file);
        rejects([&]{WindowsNotifications::create(a,post,activate,eligible,recovered_transport);},"Unknown metadata versions must fail closed");check(bytes(file)==future,"Unsupported notification state must remain unchanged");
        write(file,good);document=Object::Parse(winrt::to_hstring(good));document.SetNamedValue(L"scope",Value::CreateStringValue(L"other-user-or-data-root"));write(file,winrt::to_string(document.Stringify()));
        rejects([&]{WindowsNotifications::create(a,post,activate,eligible,recovered_transport);},"Routing files copied from another scope must not be trusted");
        write(file,std::string(256*1024+1,' '));rejects([&]{WindowsNotifications::create(a,post,activate,eligible,recovered_transport);},"Oversized route files must be rejected within a fixed bound");
        std::ofstream output(report);output<<"PASS: "<<checks<<" Windows notification payload/routing/storage checks (injected transport; no native registration or delivery)\n";return output?0:2;
    }catch(const winrt::hresult_error& error){std::ofstream(report)<<"FAIL: "<<winrt::to_string(error.message())<<'\n';}catch(const std::exception& error){std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';}return 1;
}
} // namespace coincide
