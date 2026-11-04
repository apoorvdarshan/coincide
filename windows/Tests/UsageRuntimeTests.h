#pragma once
#include "../Runtime/AgentFactory.h"
#include "UsageTests.h"

namespace coincide {
inline int usage_runtime_tests(const std::filesystem::path& report){
    using namespace std::chrono_literals;using Kind=SessionEvent::Kind;unsigned checks{};const auto check=[&](bool value,const char* reason){++checks;if(!value)throw std::runtime_error(reason);};
    const auto folder=std::filesystem::temp_directory_path()/(L"Coincide-usage-runtime-fixture-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));bool owned{};struct Cleanup{std::filesystem::path folder;bool& owned;~Cleanup(){if(owned){std::error_code error;std::filesystem::remove_all(folder,error);}}}cleanup{folder,owned};
    try{
        if(!std::filesystem::create_directory(folder))throw std::runtime_error("Usage runtime fixture directory must be unique");owned=true;wchar_t module[32768]{};if(!GetModuleFileNameW(nullptr,module,32768))throw std::runtime_error("Missing usage fixture executable");
        for(const auto* provider:{"codex","claude","opencode","cursor","grok","antigravity"}){
            const std::string name=provider;AgentLaunch launch;launch.executable=module;launch.cwd=folder;launch.fixture_account_reviewed=true;launch.request_timeout=2s;launch.interrupt_grace=100ms;launch.arguments={name=="codex"?L"--codex-session-fixture":name=="claude"?L"--claude-session-fixture":name=="opencode"?L"--opencode-http-fixture":L"--acp-session-fixture",L"usage"};
            ACPLaunchOptions options;if(name=="cursor"){const auto profile=folder/L"cursor";std::filesystem::create_directory(profile);options.cursor_settings_file=profile/L"cli-config.json";}
            std::unique_ptr<AgentSession> session;if(name=="cursor"||name=="grok"||name=="antigravity")session=std::make_unique<ACPSession>(name,launch,options);else session=make_agent_session(name,launch);
            for(unsigned sequence=0;sequence<2;++sequence){
                CodexTurn input;input.text="usage fixture";check(session->send(input),"A usage fixture provider must accept a normal synthetic turn");std::vector<SessionEvent> events;const auto end=std::chrono::steady_clock::now()+6s;bool completed{};
                do{for(auto& value:session->take_events())events.push_back(std::move(value));completed=std::any_of(events.begin(),events.end(),[](const auto& value){return value.kind==Kind::completed;})&&!session->busy();if(!completed)Sleep(2);}while(!completed&&std::chrono::steady_clock::now()<end);
                check(completed&&!std::any_of(events.begin(),events.end(),[](const auto& value){return value.kind==Kind::error;}),"Malformed/foreign provider metrics must be ignored locally while a normal conversation still completes");
                std::string session_id,turn_id,scope,reply;for(const auto& event:events){if(event.kind==Kind::session)session_id=event.id;if(event.kind==Kind::started)turn_id=event.id;if(event.kind==Kind::account_scope)scope=event.text;if(event.kind==Kind::text_complete)reply+=event.text;}
                std::vector<UsageObservation> observations;for(const auto& event:events)if(event.kind==Kind::usage){check(!event.id.empty()&&event.id==turn_id&&!event.detail.empty(),"Usage events must identify their current provider turn and source without guessing a local transcript ID");auto value=UsageProtocol::decode_text(event.text);check(value.turn_id==turn_id&&!value.native_session.empty(),"Normalized usage must preserve its native session and turn ownership");if(session_id.empty())session_id=value.native_session;check(value.native_session==session_id,"Every usage event must belong to the session reported by its provider");observations.push_back(std::move(value));}
                check(!observations.empty(),"Each implemented provider adapter must emit normalized usage only when its child actually reports it");auto owner=usage_fixture_owner({},name);owner.native_session.clear();owner.turn_id.clear();owner.delivery_id="usage-local-"+std::to_string(sequence);owner.account_scope.clear();UsageTurn accounting(owner,1000);if(!scope.empty())check(accounting.bind_account_scope(scope),"Verified fixture account scope must bind before collecting usage");check(accounting.bind_session(session_id)&&accounting.bind_native_turn(turn_id),"The local delivery must bind its actual provider session and turn once");for(const auto& value:observations)check(accounting.observe(value),"An owned normalized metric must be accepted by the local turn accumulator");const auto record=accounting.finish("completed",2000);
                if(name=="codex")check(!record.tokens&&!record.cost_usd&&record.context_tokens==125,"Codex context snapshots must remain unavailable as additive billing totals");
                else check(record.tokens&&record.tokens->total()==20,"Duplicate/current snapshots and late previous-turn metrics must never double count a provider request");
                if(name=="claude")check(!record.cost_usd&&record.session_cost_usd==12.75&&reply=="usage reply","Claude cumulative cost and retired assistant snapshots must never become another turn's cost or reply");
                else if(name=="opencode")check(record.cost_usd&&std::abs(*record.cost_usd-0.01)<0.00000001&&record.session_cost_usd==25,"OpenCode duplicate/retired steps must be counted once while session cost remains separate");
                else if(name=="grok")check(record.cost_usd&&std::abs(*record.cost_usd-0.001)<0.00000001,"Grok prompt cost ticks must emit additive USD only from its explicit prompt result");
                else check(!record.cost_usd,"Providers without explicit per-request/turn costs must not fabricate a charge");
            }session->shutdown();
        }
        std::ofstream output(report);output<<"PASS: "<<checks<<" provider usage emission checks; synthetic child providers only\n";return output?0:2;
    }catch(const winrt::hresult_error&){std::ofstream(report)<<"FAIL after "<<checks<<" checks: native provider usage contract failure\n";}catch(const std::exception& error){std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';}return 1;
}
} // namespace coincide
