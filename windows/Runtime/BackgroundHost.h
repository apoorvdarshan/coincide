#pragma once
#include "BackgroundHostLedger.h"
#include <mutex>

namespace coincide::background_host {
class Core {
public:
    using Factory=std::function<std::unique_ptr<AgentSession>(const Key&,const Launch&)>;
private:
    struct Live {
        std::unique_ptr<AgentSession> runtime;
        std::vector<SessionEvent> pending;
        std::string direct_delivery,active_delivery;
        bool stopped{},review{};
        std::map<std::string,std::size_t> reserved;
        std::optional<Ledger::Facts> published;
    };
    std::shared_ptr<Scope> scope_;HostLease lease_;Ledger ledger_;Factory factory_;
    std::map<std::string,Live> live_;mutable std::mutex gate_;
    bool blocked_{},retire_{},quitting_{};std::size_t event_limit_,command_limit_;
    static Scope& required(const std::shared_ptr<Scope>& scope){if(!scope)throw std::invalid_argument("A host needs its physical data scope");return*scope;}
    static Object sessions(const Object& document){return document.GetNamedObject(L"sessions");}
    static Object commands(const Object& document){return document.GetNamedObject(L"commands");}
    static Object resolutions(const Object& document){if(!document.HasKey(L"owner_resolutions"))document.SetNamedValue(L"owner_resolutions",Object{});return document.GetNamedObject(L"owner_resolutions");}
    static std::string resolution_key(const Key& key,const std::string& epoch,const std::string& delivery){return local_file::sha256(key.name()+":"+epoch+":"+delivery);}
    static Object record(const Object& document,const Key& key,const std::string& epoch){const auto all=sessions(document);const auto name=winrt::to_hstring(key.name());if(!all.HasKey(name))throw std::runtime_error("This hosted session is unavailable");const auto value=all.GetNamedObject(name);if(text(value,L"epoch",38)!=epoch)throw std::runtime_error("The hosted generation changed; attach current state before sending input");return value;}
    static std::string command_key(const Command& value){return(value.operation==Operation::send||value.operation==Operation::steer||value.operation==Operation::queue)?"delivery:"+value.epoch+":"+value.delivery_id:"command:"+value.id;}
    static std::string digest(const Command& value){auto object=encode(value);object.Remove(L"id");return local_file::sha256(winrt::to_string(object.Stringify()));}
    static Object answer(std::string_view status){Object value;put(value,L"status",status);return value;}
    static void update_info(Object record,const SessionInfo& value){for(const auto& field:encode(value))record.SetNamedValue(field.Key(),field.Value());}
    // Published facts follow durable metadata only. If a narrow cache read fails after
    // commit, invalidate it without turning an already-persisted event into a retry.
    void remember_published()noexcept{for(auto& [name,live]:live_)try{live.published=ledger_.facts(name);}catch(...){live.published.reset();}}
    void commit(Object next){try{ledger_.commit(std::move(next));remember_published();}catch(...){blocked_=true;for(auto& [name,live]:live_){(void)name;live.review=true;live.runtime->interrupt();}throw;}}
    void mark_review(const std::string& name)noexcept{blocked_=true;const auto live=live_.find(name);if(live!=live_.end())live->second.review=true;try{auto next=ledger_.copy();auto entry=sessions(next).GetNamedObject(winrt::to_hstring(name));auto state=info(entry);state.review=true;update_info(entry,state);ledger_.commit(std::move(next));remember_published();}catch(...){} }
    static void snapshot_queue(SessionInfo& state,const Live& live){state.queued=live.runtime->queued();state.queued_count=state.queued.size();state.queue_paused=live.stopped||live.runtime->queue_paused();state.snapshots_included=true;}
    void drain(){
        for(auto& [name,live]:live_){
            try{
                if(live.pending.empty())live.pending=live.runtime->take_events();
                // Keep listening for events; cheap facts only gate the expensive transaction.
                // Durable prompts count as activity even when the native busy flag clears.
                if(live.pending.empty()&&live.published){
                    auto current=*live.published;current.live=!live.stopped;current.busy=current.live&&(live.runtime->busy()||current.has_prompts);current.queue_paused=live.stopped||live.runtime->queue_paused();current.queued_count=live.runtime->queued_count();current.review=current.review||live.review;
                    if(current==*live.published)continue;
                }
                auto next=ledger_.copy();auto entry=sessions(next).GetNamedObject(winrt::to_hstring(name));auto state=info(entry);const auto previous=encode(state).Stringify();auto events=entry.GetNamedArray(L"events",Array{});
                auto direct=live.direct_delivery,active=live.active_delivery;auto reserved=live.reserved;
                snapshot_queue(state,live);state.review=state.review||live.review;
                for(const auto& event:live.pending){
                    if(event.kind==SessionEvent::Kind::queue_changed&&(event.detail==stopped_queue_resolution_detail||event.detail==stopped_input_resolution_detail))throw std::runtime_error("A native runtime cannot forge an owner saved-work resolution");
                    if(events.Size()>=event_limit_||state.last>=9007199254740991ull)throw std::runtime_error("The unacknowledged host event ledger reached its cap");
                    std::string local;try{if(!event.id.empty())local=guid(event.id);}catch(...){}
                    if(event.kind==SessionEvent::Kind::started&&!direct.empty())active=direct;
                    if(event.kind==SessionEvent::Kind::input){if(!direct.empty()){active=std::move(direct);direct.clear();}else if(!local.empty())active=local;if(!local.empty())reserved.erase(local);}
                    if(event.kind==SessionEvent::Kind::delivery_failed||(event.kind==SessionEvent::Kind::queue_changed&&event.detail=="removed"))if(!local.empty())reserved.erase(local);
                    const auto delivery=(event.kind==SessionEvent::Kind::queued||event.kind==SessionEvent::Kind::queue_changed||event.kind==SessionEvent::Kind::delivery_failed)?local:(active.empty()?direct:active);
                    events.Append(encode(LoggedEvent{state.epoch,++state.last,event,delivery}));
                    if(event.kind==SessionEvent::Kind::prompt){std::erase_if(state.prompts,[&](const auto& old){return old.id==event.id;});if(state.prompts.size()>=64)throw std::runtime_error("Hosted prompt count exceeds its cap");state.prompts.push_back(event);}
                    else if(event.kind==SessionEvent::Kind::resolved)std::erase_if(state.prompts,[&](const auto& old){return old.id==event.id;});
                    else if(event.kind==SessionEvent::Kind::completed){state.prompts.clear();active.clear();direct.clear();}
                    else if(event.kind==SessionEvent::Kind::models){if(event.text.size()>512*1024)throw std::runtime_error("Hosted model catalog exceeds its bound");static_cast<void>(Object::Parse(winrt::to_hstring(event.text)));state.models=event.text;state.models_sequence=state.last;}
                    else if(event.kind==SessionEvent::Kind::account_scope){fingerprint(event.text);if(event.text.empty()||event.id.empty()||event.id.size()>80||(!state.profile_id.empty()&&state.profile_id!=event.id)||(!state.account_scope.empty()&&state.account_scope!=event.text))throw std::runtime_error("The verified hosted account/profile changed");state.profile_id=event.id;state.account_scope=event.text;}
                }
                state.live=!live.stopped;state.busy=!live.stopped&&(live.runtime->busy()||!state.prompts.empty());
                if(!live.pending.empty()||encode(state).Stringify()!=previous){update_info(entry,state);entry.SetNamedValue(L"events",events);commit(std::move(next));live.pending.clear();live.direct_delivery=std::move(direct);live.active_delivery=std::move(active);live.reserved.swap(reserved);}
            }catch(...){live.runtime->interrupt();mark_review(name);throw;}
        }
    }
    void recover(){
        auto next=ledger_.copy();bool changed{};if(sessions(next).Size()>128||commands(next).Size()>4096)throw std::runtime_error("Host runtime ledger exceeds its limits");
        for(const auto& item:sessions(next)){auto entry=item.Value().GetObject();auto state=info(entry);if(item.Key()!=winrt::to_hstring(state.key.name()))throw std::runtime_error("Host ledger session key mismatch");const auto events=entry.GetNamedArray(L"events",Array{});if(events.Size()>event_limit_)throw std::runtime_error("Host ledger backlog exceeds its cap");auto sequence=state.acknowledged;for(const auto& raw:events){const auto value=logged(raw.GetObject());if(value.epoch!=state.epoch||value.sequence!=++sequence)throw std::runtime_error("Host ledger event sequence is invalid");}if(sequence!=state.last)throw std::runtime_error("Host ledger events are incomplete");
            if(state.live||state.busy){state.live=false;state.busy=false;state.review=true;state.queue_paused=true;state.prompts.clear();if(events.Size()>=event_limit_)throw std::runtime_error("Interrupted host ledger is full; preserve it for recovery");events.Append(encode(LoggedEvent{state.epoch,++state.last,{SessionEvent::Kind::error,"","The background host stopped before the runtime outcome was confirmed. Review before starting another turn.","host_interrupted"},{}}));entry.SetNamedValue(L"events",events);update_info(entry,state);changed=true;}}
        for(const auto& item:commands(next)){auto value=item.Value().GetObject();const auto status=text(value,L"status",32);if(status!="intent"&&status!="accepted"&&status!="rejected"&&status!="uncertain")throw std::runtime_error("Invalid host delivery ledger status");if(status=="intent"){put(value,L"status","uncertain");changed=true;}}
        if(next.HasKey(L"owner_shutdown")){auto owner=next.GetNamedObject(L"owner_shutdown");(void)guid(text(owner,L"id",38));fingerprint(text(owner,L"digest",64));const auto status=text(owner,L"status",32);if(status!="intent"&&status!="accepted"&&status!="uncertain")throw std::runtime_error("Invalid host owner shutdown checkpoint");if(status=="intent"){put(owner,L"status","uncertain");changed=true;}}
        if(next.HasKey(L"owner_resolutions")){const auto all=next.GetNamedObject(L"owner_resolutions");if(all.Size()>8192)throw std::runtime_error("Owner resolution history exceeds its bound");for(const auto& item:all){const auto value=item.Value().GetObject();keys(value,{L"thread",L"provider",L"epoch",L"delivery_id",L"digest",L"status",L"receipt"});const auto selected=checked({text(value,L"thread",38),text(value,L"provider",32)});const auto epoch=guid(text(value,L"epoch",38)),delivery=guid(text(value,L"delivery_id",38));const auto hash=text(value,L"digest",64);fingerprint(hash);const auto receipt=logged(value.GetNamedObject(L"receipt"));const auto current=info(record(next,selected,epoch));if(hash.size()!=64||text(value,L"status",32)!="accepted"||item.Key()!=winrt::to_hstring(resolution_key(selected,epoch,delivery))||receipt.epoch!=epoch||!receipt.sequence||receipt.sequence>current.last||receipt.delivery_id!=delivery||receipt.value.id!=delivery||receipt.value.kind!=SessionEvent::Kind::queue_changed||((receipt.value.detail!=stopped_queue_resolution_detail||receipt.value.text!=stopped_queue_resolution_text)&&(receipt.value.detail!=stopped_input_resolution_detail||receipt.value.text!=stopped_input_resolution_text))||std::any_of(current.queued.begin(),current.queued.end(),[&](const auto& input){return input.id==delivery;}))throw std::runtime_error("Invalid durable owner saved-work resolution");if(receipt.sequence>current.acknowledged){bool found{};for(const auto& raw:record(next,selected,epoch).GetNamedArray(L"events")){const auto candidate=logged(raw.GetObject());if(candidate.sequence==receipt.sequence){found=encode(candidate).Stringify()==encode(receipt).Stringify();break;}}if(!found)throw std::runtime_error("Owner resolution receipt is missing from its unacknowledged prefix");}}}
        // Reserved administrative events must have their matching atomic owner proof. A
        // partial/corrupted checkpoint cannot manufacture a reviewed resolution receipt.
        for(const auto& item:sessions(next)){const auto entry=item.Value().GetObject();const auto state=info(entry);for(const auto& raw:entry.GetNamedArray(L"events",Array{})){const auto receipt=logged(raw.GetObject());if(receipt.value.kind!=SessionEvent::Kind::queue_changed||(receipt.value.detail!=stopped_queue_resolution_detail&&receipt.value.detail!=stopped_input_resolution_detail))continue;if(!next.HasKey(L"owner_resolutions"))throw std::runtime_error("Administrative receipt is missing its durable owner proof");const auto history=next.GetNamedObject(L"owner_resolutions");const auto identity=winrt::to_hstring(resolution_key(state.key,state.epoch,receipt.delivery_id));if(!history.HasKey(identity)||encode(logged(history.GetNamedObject(identity).GetNamedObject(L"receipt"))).Stringify()!=encode(receipt).Stringify())throw std::runtime_error("Administrative receipt does not match its atomic owner proof");}}
        if(changed)commit(std::move(next));
    }
    Object poll(const Command& value){auto batch=ledger_.poll(value.key,value.epoch,value.sequence);if(blocked_)batch.session.review=true;auto result=answer("ok");result.SetNamedValue(L"session",encode(batch.session));result.SetNamedValue(L"events",batch.events);return result;}
    Object acknowledge(const Command& value){auto next=ledger_.copy();auto entry=record(next,value.key,value.epoch);auto state=info(entry);if(value.sequence>state.last)throw std::invalid_argument("Cannot acknowledge an event the host has not persisted");if(value.sequence<=state.acknowledged)return answer("ok");Array retained;for(const auto& raw:entry.GetNamedArray(L"events",Array{}))if(integer(raw.GetObject(),L"sequence")>value.sequence)retained.Append(raw);state.acknowledged=value.sequence;update_info(entry,state);entry.SetNamedValue(L"events",retained);commit(std::move(next));if(blocked_){try{drain();blocked_=false;}catch(...){}}return answer("ok");}
    static bool all_applied(const Object& document){for(const auto& item:sessions(document)){const auto state=info(item.Value().GetObject());if(state.last!=state.acknowledged)return false;}return true;}
    Object shutdown_host(const Command& value){
        quitting_=true;const auto hash=digest(value);auto next=ledger_.copy();
        if(next.HasKey(L"owner_shutdown")){const auto old=next.GetNamedObject(L"owner_shutdown");if(text(old,L"id",38)==value.id&&text(old,L"digest",64)!=hash)throw std::runtime_error("Shutdown command ID was reused");}
        // A single separate owner intent reserves shutdown capacity even when delivery history
        // is full. Repeated/uncertain Quit retries checkpointing; stopped children never restart.
        Object intent;put(intent,L"id",value.id);put(intent,L"digest",hash);put(intent,L"status","intent");next.SetNamedValue(L"owner_shutdown",intent);try{commit(std::move(next));}catch(...){}
        for(auto& [name,live]:live_){(void)name;if(!live.stopped){live.runtime->shutdown();live.stopped=true;}}
        const bool needs_review=blocked_;try{drain();auto durable=ledger_.copy();for(const auto& item:sessions(durable)){auto entry=item.Value().GetObject();auto state=info(entry);state.live=false;state.busy=false;state.review=state.review||needs_review;state.queue_paused=true;state.prompts.clear();update_info(entry,state);}Object completed;put(completed,L"id",value.id);put(completed,L"digest",hash);put(completed,L"status","accepted");durable.SetNamedValue(L"owner_shutdown",completed);commit(std::move(durable));live_.clear();blocked_=false;}catch(...){blocked_=true;return answer("uncertain");}
        auto result=answer("accepted");const bool ready=all_applied(ledger_.copy());if(ready)retire_=true;result.SetNamedValue(L"needs_persistence",Value::CreateBooleanValue(!ready));result.SetNamedValue(L"retiring",Value::CreateBooleanValue(ready));return result;
    }
    Object resolve_stopped(const Command& value){
        auto next=ledger_.copy();auto entry=record(next,value.key,value.epoch);auto state=info(entry);
        if(!value.owner_reviewed||state.live||state.busy||live_.contains(value.key.name())||!state.queue_paused||state.launch_fingerprint!=value.expected_launch_fingerprint||state.profile_id!=value.expected_profile_id||state.account_scope!=value.expected_account_scope)throw std::runtime_error("Review the exact stopped original generation before cancelling future saved work");
        const auto ordinary=commands(next);const auto original_id=winrt::to_hstring("delivery:"+value.epoch+":"+value.delivery_id);std::string original_digest;
        if(ordinary.HasKey(original_id)){const auto original=ordinary.GetNamedObject(original_id);if(text(original,L"thread",38)!=value.key.thread||text(original,L"provider",32)!=value.key.provider||text(original,L"epoch",38)!=value.epoch)throw std::runtime_error("The original delivery belongs to another hosted key");original_digest=text(original,L"digest",64);}
        if(original_digest!=value.expected_delivery_digest)throw std::runtime_error("The reviewed original delivery proof changed; absence never implies non-delivery");
        const bool removes_saved=value.operation==Operation::cancel_stopped_queue;
        auto history=resolutions(next);const auto identity=winrt::to_hstring(resolution_key(value.key,value.epoch,value.delivery_id));const auto hash=digest(value);
        const auto reply=[&](const LoggedEvent& receipt){auto result=answer("accepted");put(result,L"resolution",removes_saved?"future_saved_work_cancelled":"stopped_input_reviewed");result.SetNamedValue(L"delivery_unknown",Value::CreateBooleanValue(true));result.SetNamedValue(L"resolution_receipt",encode(receipt));if(blocked_)state.review=true;result.SetNamedValue(L"session",encode(state));return result;};
        if(history.HasKey(identity)){const auto old=history.GetNamedObject(identity);if(text(old,L"digest",64)!=hash)throw std::runtime_error("A saved-work resolution cannot change its reviewed target or binding");return reply(logged(old.GetNamedObject(L"receipt")));}
        if(history.Size()>=8192)throw std::runtime_error("Owner resolution history reached its bound; no saved work was discarded");
        const auto target=std::find_if(state.queued.begin(),state.queued.end(),[&](const auto& input){return input.id==value.delivery_id;});if(removes_saved?(target==state.queued.end()||queued_fingerprint(*target)!=value.queued_fingerprint):(target!=state.queued.end()))throw std::runtime_error("The reviewed saved queue target is absent or changed; no cancellation was inferred");
        auto events=entry.GetNamedArray(L"events",Array{});if(events.Size()>=event_limit_||state.last>=9007199254740991ULL)throw std::runtime_error("Persist and acknowledge the existing receipt prefix before resolving more saved work");
        if(removes_saved)state.queued.erase(target);state.queued_count=state.queued.size();state.review=state.review||blocked_;
        LoggedEvent receipt{state.epoch,++state.last,{SessionEvent::Kind::queue_changed,value.delivery_id,std::string(removes_saved?stopped_queue_resolution_text:stopped_input_resolution_text),std::string(removes_saved?stopped_queue_resolution_detail:stopped_input_resolution_detail)},value.delivery_id};events.Append(encode(receipt));entry.SetNamedValue(L"events",events);update_info(entry,state);
        Object outcome;put(outcome,L"thread",value.key.thread);put(outcome,L"provider",value.key.provider);put(outcome,L"epoch",value.epoch);put(outcome,L"delivery_id",value.delivery_id);put(outcome,L"digest",hash);put(outcome,L"status","accepted");outcome.SetNamedValue(L"receipt",encode(receipt));history.SetNamedValue(identity,outcome);
        // The queue change, explicit administrative receipt and dedupe proof are one atomic
        // metadata commit. No runtime/factory is called, even if ordinary history is full.
        commit(std::move(next));return reply(receipt);
    }
    static std::size_t queue_bytes(const AgentQueuedTurn& value){return winrt::to_string(encode(value).Stringify()).size();}
    static std::optional<std::map<std::string,std::size_t>> queue_preflight(const Live& live,const Command& value,const SessionInfo& stored){
        auto queued=live.runtime->queued();auto reserved=live.reserved;const auto target=std::find_if(queued.begin(),queued.end(),[&](const auto& input){return input.id==value.delivery_id;});
        if(value.operation==Operation::edit_queue){if(target==queued.end())return{};target->turn=value.input;}else if(value.operation==Operation::queue)queued.push_back({value.delivery_id,value.input});
        reserved.insert_or_assign(value.delivery_id,queue_bytes({value.delivery_id,value.input}));std::set<std::string> included;std::size_t total{};for(const auto& input:queued){if(!included.insert(guid(input.id)).second)return{};total+=queue_bytes(input);}for(const auto& [id,size]:reserved)if(!included.contains(id)){included.insert(id);total+=size;}if(included.size()>64||total>1024*1024)return{};auto proposed=stored;proposed.queued=queued;proposed.queued_count=queued.size();proposed.snapshots_included=true;std::size_t extra{};for(const auto& [id,size]:reserved)if(std::none_of(queued.begin(),queued.end(),[&](const auto& input){return input.id==id;}))extra+=size+2;try{if(winrt::to_string(encode(proposed).Stringify()).size()+extra>2*1024*1024)return{};}catch(...){return{};}return reserved;
    }
public:
    Core(std::shared_ptr<Scope> scope,Factory factory,std::size_t byte_limit=16*1024*1024,std::size_t event_limit=2048,std::size_t command_limit=4096):scope_(std::move(scope)),lease_(required(scope_)),ledger_(required(scope_),byte_limit),factory_(std::move(factory)),event_limit_(event_limit),command_limit_(command_limit){if(!factory_||!event_limit||event_limit>10000||!command_limit||command_limit>4096)throw std::invalid_argument("A host requires a verified session factory and bounded ledger");recover();}
    Object perform(Command value){
        value=command(encode(value));std::lock_guard lock(gate_);
        if(value.operation==Operation::acknowledge)return acknowledge(value);if(value.operation==Operation::poll)return poll(value);
        if(value.operation==Operation::shutdown_host)return shutdown_host(value);
        if(value.operation==Operation::cancel_stopped_queue||value.operation==Operation::resolve_stopped_input)return resolve_stopped(value);
        if(value.operation==Operation::command_status){static_cast<void>(record(ledger_.copy(),value.key,value.epoch));const auto all=commands(ledger_.copy());const auto identity=winrt::to_hstring("command:"+value.target_command_id);if(!all.HasKey(identity))return answer("unknown");const auto old=all.GetNamedObject(identity);if(text(old,L"epoch",38)!=value.epoch||text(old,L"thread",38)!=value.key.thread||text(old,L"provider",32)!=value.key.provider||text(old,L"digest",64)!=value.expected_delivery_digest)throw std::runtime_error("The original control status does not match this exact command/key/epoch/digest");return answer(text(old,L"status",32));}
        if(value.operation==Operation::delivery_status){const auto all=commands(ledger_.copy());const auto id=winrt::to_hstring("delivery:"+value.epoch+":"+value.delivery_id);if(!all.HasKey(id))return answer("unknown");const auto entry=all.GetNamedObject(id);if(text(entry,L"epoch",38)!=value.epoch||text(entry,L"thread",38)!=value.key.thread||text(entry,L"provider",32)!=value.key.provider)throw std::runtime_error("Delivery status belongs to another hosted session");auto result=answer(text(entry,L"status",32));put(result,L"command_digest",text(entry,L"digest",64));return result;}
        if(value.operation==Operation::list){auto result=answer("ok");Array all;for(auto state:ledger_.summaries()){if(blocked_)state.review=true;all.Append(encode(state));}result.SetNamedValue(L"sessions",all);result.SetNamedValue(L"blocked",Value::CreateBooleanValue(blocked_));return result;}
        if(value.operation==Operation::status){if(!blocked_)try{drain();}catch(...){}auto state=ledger_.session(value.key,value.epoch);if(blocked_)state.review=true;auto result=answer("ok");result.SetNamedValue(L"session",encode(state));return result;}
        if(value.operation==Operation::retire){retire_=true;return answer("ok");}
        if(blocked_&&(value.operation==Operation::interrupt||value.operation==Operation::shutdown)){const auto at=live_.find(value.key.name());if(at!=live_.end()){static_cast<void>(record(ledger_.copy(),value.key,value.epoch));at->second.runtime->interrupt();if(value.operation==Operation::shutdown){at->second.runtime->shutdown();at->second.stopped=true;}try{drain();auto next=ledger_.copy();auto entry=record(next,value.key,value.epoch);auto state=info(entry);state.review=true;state.busy=false;if(value.operation==Operation::shutdown){state.live=false;state.prompts.clear();}update_info(entry,state);commit(std::move(next));if(value.operation==Operation::shutdown)live_.erase(at);blocked_=false;}catch(...){}return answer("uncertain");}}
        if(blocked_||quitting_)throw std::runtime_error("Host storage, review or owner shutdown pauses new runtime work");drain();auto next=ledger_.copy();auto all=sessions(next);const auto name=winrt::to_hstring(value.key.name());
        if(value.operation==Operation::review){auto entry=record(next,value.key,value.epoch);auto state=info(entry);if(state.live||state.busy)throw std::runtime_error("A live hosted session cannot be marked reviewed");state.review=false;update_info(entry,state);commit(std::move(next));return answer("ok");}
        const auto identity=winrt::to_hstring(command_key(value));const auto hash=digest(value);auto history=commands(next);if(history.HasKey(identity)){const auto old=history.GetNamedObject(identity);if(text(old,L"digest",64)!=hash)throw std::runtime_error("A hosted command/delivery ID cannot be reused for different input");auto result=answer(text(old,L"status",32));if(all.HasKey(name)&&text(all.GetNamedObject(name),L"epoch",38)==value.epoch)result.SetNamedValue(L"session",encode(info(all.GetNamedObject(name))));return result;}if(history.Size()>=command_limit_)throw std::runtime_error("Host durable delivery history is full");
        if(value.operation==Operation::start){
            if(all.HasKey(name)){const auto state=info(all.GetNamedObject(name));if(state.live&&state.epoch==value.epoch){if(state.launch_fingerprint!=launch_fingerprint(value.launch))throw std::runtime_error("The live session has another launch/account binding");auto result=answer("accepted");result.SetNamedValue(L"session",encode(state));return result;}if(state.live||state.busy||state.review||!state.prompts.empty()||!state.queued.empty()||state.queued_count||state.last!=state.acknowledged||state.epoch==value.epoch)throw std::runtime_error("Catch up/review the old host generation before a fresh explicit start");}else if(all.Size()>=128)throw std::runtime_error("Host session count reached its cap");
            // Replacing a fully ACKed/reviewed stopped generation also retires its bounded
            // administrative dedupe records. The old epoch can no longer accept commands.
            auto old_resolutions=resolutions(next);std::vector<winrt::hstring> retired;for(const auto& item:old_resolutions){const auto old=item.Value().GetObject();if(text(old,L"thread",38)==value.key.thread&&text(old,L"provider",32)==value.key.provider)retired.push_back(item.Key());}for(const auto& id:retired)old_resolutions.Remove(id);
            SessionInfo state{value.key,value.epoch,false,false,false,0,0,{}};state.profile_id=value.launch.profile_id;state.launch_fingerprint=launch_fingerprint(value.launch);Object entry=encode(state);entry.SetNamedValue(L"events",Array{});all.SetNamedValue(name,entry);
        }else{const auto state=info(record(next,value.key,value.epoch));if(!state.live||state.review||!live_.contains(value.key.name()))throw std::runtime_error("The hosted session is not live; uncertain work is never replayed");}
        Object intent;put(intent,L"digest",hash);put(intent,L"status","intent");put(intent,L"epoch",value.epoch);put(intent,L"thread",value.key.thread);put(intent,L"provider",value.key.provider);history.SetNamedValue(identity,intent);commit(std::move(next));bool accepted{},invoked{};
        try{
            if(value.operation==Operation::start){invoked=true;auto runtime=factory_(value.key,value.launch);if(!runtime)throw std::runtime_error("The verified runtime factory is unavailable");Live live;live.runtime=std::move(runtime);live_.emplace(value.key.name(),std::move(live));accepted=true;}
            else{
                auto& live=live_.at(value.key.name());auto& runtime=live.runtime;std::optional<std::map<std::string,std::size_t>> reserved;
                const bool preflight=value.operation==Operation::queue||value.operation==Operation::steer||value.operation==Operation::edit_queue;
                if(preflight)reserved=queue_preflight(live,value,info(record(ledger_.copy(),value.key,value.epoch)));
                if(!preflight||reserved){invoked=true;switch(value.operation){
                    case Operation::send:live.direct_delivery=value.delivery_id;accepted=runtime->send_identified(value.input,value.delivery_id);if(!accepted)live.direct_delivery.clear();break;
                    case Operation::steer:accepted=runtime->steer(value.input,value.delivery_id);break;
                    case Operation::queue:accepted=runtime->queue(value.input,value.delivery_id);break;
                    case Operation::edit_queue:accepted=runtime->edit_queued(value.delivery_id,value.input);break;
                    case Operation::remove_queue:accepted=runtime->remove_queued(value.delivery_id);if(accepted)live.reserved.erase(value.delivery_id);break;
                    case Operation::pause_queue:accepted=runtime->pause_queue();break;
                    case Operation::resume_queue:accepted=runtime->resume_queue();break;
                    case Operation::refresh_models:accepted=runtime->refresh_models();break;
                    case Operation::respond:runtime->respond(value.prompt_id,value.result);accepted=true;break;
                    case Operation::interrupt:runtime->interrupt();accepted=true;break;
                    case Operation::shutdown:runtime->shutdown();live.stopped=true;accepted=true;break;
                    default:throw std::invalid_argument("Unsupported host mutation");}
                    if(accepted&&reserved)live.reserved.swap(*reserved);
                }
            }
            auto durable=ledger_.copy();auto entry=record(durable,value.key,value.epoch);auto state=info(entry);auto& live=live_.at(value.key.name());state.live=!live.stopped;if(!state.live)state.prompts.clear();state.busy=state.live&&live.runtime->busy();snapshot_queue(state,live);update_info(entry,state);put(commands(durable).GetNamedObject(identity),L"status",accepted?"accepted":"rejected");commit(std::move(durable));drain();if(value.operation==Operation::shutdown)live_.erase(value.key.name());auto result=answer(accepted?"accepted":"rejected");result.SetNamedValue(L"session",encode(info(record(ledger_.copy(),value.key,value.epoch))));return result;
        }catch(...){if(invoked){for(auto& [key,live]:live_){(void)key;live.runtime->interrupt();}mark_review(value.key.name());try{auto durable=ledger_.copy();put(commands(durable).GetNamedObject(identity),L"status","uncertain");ledger_.commit(std::move(durable));remember_published();}catch(...){}return answer("uncertain");}throw;}
    }
    void pump(){std::lock_guard lock(gate_);if(!blocked_)drain();}
    bool busy()const{std::lock_guard lock(gate_);if(blocked_)return true;for(const auto& [name,live]:live_){(void)name;if(!live.stopped&&live.runtime->busy())return true;}return ledger_.has_pending_prompts();}
    Ledger::Activity ledger_activity()const{std::lock_guard lock(gate_);return ledger_.activity();}
    bool retire_requested()const{std::lock_guard lock(gate_);return retire_;}bool blocked()const{std::lock_guard lock(gate_);return blocked_;}
    ~Core(){
        try{std::lock_guard lock(gate_);for(auto& [name,live]:live_){const bool uncertain=blocked_||live.runtime->busy();live.runtime->shutdown();live.stopped=true;if(uncertain){auto next=ledger_.copy();auto entry=sessions(next).GetNamedObject(winrt::to_hstring(name));auto state=info(entry);state.review=true;update_info(entry,state);ledger_.commit(std::move(next));}}drain();auto next=ledger_.copy();for(const auto& item:sessions(next)){auto entry=item.Value().GetObject();auto state=info(entry);state.live=false;state.busy=false;state.queue_paused=true;update_info(entry,state);}ledger_.commit(std::move(next));}catch(...){for(auto& [name,live]:live_){(void)name;live.runtime->shutdown();}}
    }
};
} // namespace coincide::background_host
