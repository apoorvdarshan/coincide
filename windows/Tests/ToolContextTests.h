#pragma once
#include "../Runtime/AgentFactory.h"
#include <fstream>

namespace coincide {
// Every provider uses a real owned child fixture. The child echoes only synthetic context so the
// test observes the actual wire payload, while accepted/queued transcript events stay unmodified.
inline int tool_context_tests(const std::filesystem::path& report){
    using namespace std::chrono_literals;using Kind=SessionEvent::Kind;unsigned checks{};
    const auto check=[&](bool value,const char* reason){++checks;if(!value)throw std::runtime_error(reason);};
    wchar_t module[32768]{};if(!GetModuleFileNameW(nullptr,module,32768))return 2;
    const auto folder=std::filesystem::temp_directory_path()/(L"coincide-context-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    struct Cleanup{std::filesystem::path path;bool owned{};~Cleanup(){if(owned){std::error_code error;std::filesystem::remove_all(path,error);}}}cleanup{folder};
    try{
        if(!std::filesystem::create_directory(folder))throw std::runtime_error("Synthetic context folder already exists; nothing was removed");cleanup.owned=true;
        const auto turn=[](std::string value){CodexTurn input;input.text=std::move(value);return input;};
        const auto has=[](const auto& events,Kind kind){return std::any_of(events.begin(),events.end(),[&](const auto& value){return value.kind==kind;});};
        const auto combined=[](const auto& events,Kind kind){std::string result;for(const auto& event:events)if(event.kind==kind)result+=event.text;return result;};
        const auto until=[&](AgentSession& session,const auto& predicate){std::vector<SessionEvent> events;const auto end=std::chrono::steady_clock::now()+6s;do{for(auto& event:session.take_events())events.push_back(std::move(event));if(predicate(events))return events;Sleep(2);}while(std::chrono::steady_clock::now()<end);std::string details;for(const auto& event:events)details+=" ["+std::to_string(static_cast<int>(event.kind))+":"+event.text.substr(0,300)+"]";throw std::runtime_error("Synthetic tool-context provider timed out; busy="+std::to_string(session.busy())+details);};
        const auto finished=[&](AgentSession& session){return until(session,[&](const auto& events){return has(events,Kind::completed)&&!session.busy();});};
        AgentLaunch defaults;const auto original=turn("Original user message 你好");check(with_current_tool_context(defaults,original).text==original.text,"An absent context callback must preserve all existing wire behavior");
        defaults.tool_context=[](){return std::string{};};check(with_current_tool_context(defaults,original).text.find("No app-tool connections")!=std::string::npos,"A current empty grant snapshot must invalidate previous connection references");
        for(const auto* provider:{"codex","claude","opencode","cursor","grok","antigravity"}){
            std::mutex context_mutex;std::string context="SYNTHETIC-ACCESS-A";unsigned reads{};
            AgentLaunch launch;launch.executable=module;launch.cwd=folder;launch.request_timeout=2s;launch.interrupt_grace=100ms;launch.fixture_account_reviewed=true;
            const std::string name=provider;const auto route=name=="codex"?L"--codex-session-fixture":name=="claude"?L"--claude-session-fixture":name=="opencode"?L"--opencode-http-fixture":L"--acp-session-fixture";launch.arguments={route,L"context"};
            launch.tool_context=[&]{std::lock_guard lock(context_mutex);++reads;return context;};
            ACPLaunchOptions options;if(name=="cursor"){const auto profile=folder/L"cursor";std::filesystem::create_directory(profile);options.cursor_settings_file=profile/L"cli-config.json";}
            std::unique_ptr<AgentSession> session;if(name=="cursor"||name=="grok"||name=="antigravity")session=std::make_unique<ACPSession>(name,launch,options);else session=make_agent_session(name,launch);
            check(session->send(original),"A context fixture must accept its original user input");const auto first=finished(*session);const auto wire=combined(first,Kind::text_complete);
            check(!has(first,Kind::error)&&wire.find("SYNTHETIC-ACCESS-A")!=std::string::npos&&wire.ends_with(original.text),"Every provider must deliver current app-tool context on its actual runtime wire");
            check(original.text=="Original user message 你好","Runtime context must never mutate the stored user message");
            check(session->send(turn("wait")),"A context fixture must accept its explicit queue barrier");until(*session,[&](const auto& events){return has(events,Kind::started);});
            check(session->queue(turn("Original queued draft"),"context-queued"),"The original queued draft must remain independently addressable");
            check(session->queued().size()==1&&session->queued().front().turn.text=="Original queued draft","Queued drafts must never cache tool context or private config paths");
            {std::lock_guard lock(context_mutex);context="SYNTHETIC-ACCESS-B";}
            session->interrupt();const auto stopped=finished(*session);check(combined(stopped,Kind::completed)=="interrupted"&&session->queue_paused(),"Stopping a barrier must retain a paused queued draft");
            check(session->resume_queue(),"A retained queue requires explicit resume");const auto queued=finished(*session);const auto delivered=combined(queued,Kind::text_complete);
            if(has(queued,Kind::error)||delivered.find("SYNTHETIC-ACCESS-B")==std::string::npos||delivered.find("SYNTHETIC-ACCESS-A")!=std::string::npos||!delivered.ends_with("Original queued draft"))throw std::runtime_error("Synthetic queued context mismatch for "+name+": "+combined(queued,Kind::error)+" / "+delivered.substr(0,300));++checks;
            check(std::any_of(queued.begin(),queued.end(),[](const auto& event){return event.kind==Kind::input&&event.id=="context-queued"&&event.text=="Original queued draft";}),"Accepted queued transcript events must retain the original text and delivery identity");
            {std::lock_guard lock(context_mutex);context.clear();}
            check(session->send(turn("after revocation")),"A provider may continue after app-tool access revocation");const auto revoked=finished(*session);check(!has(revoked,Kind::error)&&combined(revoked,Kind::text_complete).find("No app-tool connections")!=std::string::npos,"Revocation must be communicated on the very next provider delivery");
            {std::lock_guard lock(context_mutex);check(reads==4,"The callback must be evaluated once per actual delivery and never at enqueue time");}
            session->shutdown();
        }
        {
            std::atomic_uint revision{1};AgentLaunch launch;launch.executable=module;launch.cwd=folder;launch.arguments={L"--codex-session-fixture",L"context"};launch.fixture_account_reviewed=true;launch.interrupt_grace=100ms;launch.request_timeout=2s;
            launch.tool_context=[&]{return revision==1?"SYNTHETIC-OLD":"SYNTHETIC-STEER";};CodexSession session(launch);session.send(turn("wait"));until(session,[&](const auto& events){return has(events,Kind::started);});revision=2;
            check(session.steer(turn("Original follow-up"),"context-steered"),"Live Codex steering must accept its independent delivery identity");const auto accepted=until(session,[&](const auto& events){return has(events,Kind::input)&&has(events,Kind::text_complete);});
            check(combined(accepted,Kind::text_complete).find("SYNTHETIC-STEER")!=std::string::npos&&combined(accepted,Kind::text_complete).find("SYNTHETIC-OLD")==std::string::npos,"Live steering must retrieve context immediately before turn/steer");
            check(std::any_of(accepted.begin(),accepted.end(),[](const auto& event){return event.kind==Kind::input&&event.id=="context-steered"&&event.text=="Original follow-up"&&event.detail=="steered";}),"Steering acknowledgements must persist only the user's original follow-up");session.interrupt();(void)finished(session);
        }
        for(const auto invalid:{0,1,2}){
            std::atomic_uint invoked{};AgentLaunch launch;launch.executable=module;launch.cwd=folder;launch.arguments={L"--codex-session-fixture",L"context"};launch.fixture_account_reviewed=true;launch.request_timeout=2s;
            launch.tool_context=[&,invalid]()->std::string{++invoked;if(invalid==0)throw std::runtime_error("PRIVATE CALLBACK DETAIL");if(invalid==1)return std::string(512*1024+1,'x');return std::string("\xff",1);};
            CodexSession session(launch);session.send(original);const auto rejected=finished(session);check(invoked==1&&has(rejected,Kind::error)&&!has(rejected,Kind::started)&&combined(rejected,Kind::error).find("PRIVATE CALLBACK DETAIL")==std::string::npos,"Invalid or unavailable context must execute its callback and fail before delivery without exposing details");
        }
        std::ofstream output(report);output<<"PASS: "<<checks<<" per-delivery tool-context checks; synthetic child providers only\n";return output?0:2;
    }catch(const winrt::hresult_error&){std::ofstream(report)<<"FAIL after "<<checks<<" checks: native tool-context contract failure\n";}
    catch(const std::exception& error){std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';}return 1;
}
} // namespace coincide
