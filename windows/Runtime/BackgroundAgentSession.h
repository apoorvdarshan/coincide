#pragma once
#include "HostIPC.h"
#include <condition_variable>
#include <deque>
#include <future>
#include <unordered_map>
#include <thread>

namespace coincide {
enum class BackgroundAgentPhase {connecting,ready,review,unavailable,ended,detached};
enum class BackgroundDeliveryDisposition {pending,accepted,rejected,not_submitted,uncertain};
struct BackgroundDelivery {std::string id,operation;BackgroundDeliveryDisposition disposition{BackgroundDeliveryDisposition::pending};};
struct BackgroundAgentStart {std::string epoch; background_host::Launch launch;};
struct BackgroundAgentOptions {
    std::shared_ptr<background_host::Scope> scope; background_host::Key key;
    std::optional<background_host::FileIdentity> expected_host_image;
    std::optional<AgentEventCursor> restored_cursor;
    std::optional<BackgroundAgentStart> authorized_start;
    // Root must verify the saved epoch/profile/account binding before opting into adoption.
    bool allow_adoption{},host_owns_current_tool_context{};
    std::string expected_profile_id{"default"},expected_account_scope,expected_launch_fingerprint;
    std::vector<std::string> reconcile_delivery_ids;
    std::chrono::milliseconds request_timeout{1000},action_timeout{10000},poll_interval{100},reconnect_interval{500};
};
struct BackgroundAgentSnapshot {
    background_host::Ownership ownership{background_host::Ownership::unavailable};
    BackgroundAgentPhase phase{BackgroundAgentPhase::connecting};
    std::string epoch,profile_id,account_scope,launch_fingerprint,models;
    bool live{},busy{},review{},queue_paused{true},queue_known{},models_known{};
    std::uint64_t last{},acknowledged{},revision{};std::size_t queued_count{};
    std::vector<SessionEvent> prompts;std::vector<AgentQueuedTurn> queued;std::vector<BackgroundDelivery> outbox;
};

// This proxy never creates a provider or host process, changes global settings, or appends tool
// references to queued input. Root's verified HOST factory supplies current tool_context on the
// actual native provider worker. Closing this UI proxy detaches; explicit shutdown stops its key.
// Blocking acceptance methods are for background callers only and fail closed on STA/XAML.
class BackgroundAgentSession final:public AgentSession {
    using Operation=background_host::Operation;using Command=background_host::Command;using Info=background_host::SessionInfo;using Object=background_host::Object;
    struct Work {
        Command command;std::shared_ptr<std::promise<BackgroundDeliveryDisposition>> reply;
        std::chrono::steady_clock::time_point deadline;bool in_flight{},cancelled{};std::optional<BackgroundDeliveryDisposition> result;
    };
    struct State {
        BackgroundAgentOptions options;mutable std::mutex gate;std::condition_variable cv;
        std::deque<std::shared_ptr<Work>> work;std::vector<SessionEvent> events;std::deque<background_host::LoggedEvent> retained;
        BackgroundAgentSnapshot snapshot;std::unordered_map<std::string,std::string> attempted;
        std::optional<AgentEventCursor> fetched,issued,durable,acknowledged;
        std::size_t event_bytes{},retained_bytes{};bool stop{},shutdown_requested{},attached{},start_attempted{},own_start{},reconcile_done{},needs_status{true};
        std::atomic<bool> finished{},busy{true};std::string snapshot_json,last_notice;std::uint64_t ack_target{};
        explicit State(BackgroundAgentOptions value):options(std::move(value)){if(options.restored_cursor){fetched=issued=durable=options.restored_cursor;}if(options.authorized_start&&!fetched){const AgentEventCursor cursor{options.authorized_start->epoch,0};fetched=issued=durable=cursor;}snapshot.epoch=fetched?fetched->epoch:std::string{};}
    };
    std::shared_ptr<State> state_;
    static constexpr std::size_t maximum_events=512,maximum_event_bytes=8*1024*1024,maximum_work=64,maximum_outbox=256;
public:
    explicit BackgroundAgentSession(BackgroundAgentOptions options){
        if(!options.scope)throw std::invalid_argument("A background session needs its physical app data scope");options.key=background_host::checked(std::move(options.key));options.expected_profile_id=canonical_profile(options.expected_profile_id);
        if(!options.host_owns_current_tool_context)throw std::invalid_argument("The verified host factory must own current per-delivery app-tool context");
        if(!options.restored_cursor&&!options.authorized_start)throw std::invalid_argument("A hosted session needs a restored cursor or explicit start authorization");
        if(options.restored_cursor){options.restored_cursor->epoch=background_host::guid(options.restored_cursor->epoch);if(options.restored_cursor->sequence>9007199254740991ull)throw std::invalid_argument("Invalid restored host cursor");}
        if(options.authorized_start){options.authorized_start->epoch=background_host::guid(options.authorized_start->epoch);background_host::validate(options.authorized_start->launch);if(options.restored_cursor&&options.restored_cursor->epoch!=options.authorized_start->epoch)throw std::invalid_argument("Start authorization and restored host generation differ");if((options.authorized_start->launch.profile_id!="default"&&options.authorized_start->launch.profile_id.size()!=36)||canonical_profile(options.authorized_start->launch.profile_id)!=options.expected_profile_id)throw std::invalid_argument("Host start profile differs from the verified selection");}
        for(const auto* digest:{&options.expected_account_scope,&options.expected_launch_fingerprint})if(!digest->empty()&&(digest->size()!=64||digest->find_first_not_of("0123456789abcdef")!=std::string::npos))throw std::invalid_argument("Invalid nonsecret hosted account/launch fingerprint");
        if(options.allow_adoption&&(!options.restored_cursor||options.expected_account_scope.empty()))throw std::invalid_argument("Unknown or legacy hosted account bindings require explicit owner review");
        if(options.reconcile_delivery_ids.size()>64)throw std::invalid_argument("Too many pending host delivery identities");std::set<std::string> deliveries;for(auto& id:options.reconcile_delivery_ids){id=background_host::guid(id);if(!deliveries.insert(id).second)throw std::invalid_argument("Duplicate pending host delivery identity");}
        if(options.request_timeout<std::chrono::milliseconds(50)||options.request_timeout>std::chrono::seconds(5)||options.action_timeout<options.request_timeout||options.action_timeout>std::chrono::seconds(30)||options.poll_interval<std::chrono::milliseconds(25)||options.poll_interval>std::chrono::seconds(5)||options.reconnect_interval<std::chrono::milliseconds(50)||options.reconnect_interval>std::chrono::seconds(5))throw std::invalid_argument("Invalid bounded host proxy timing");
        state_=std::make_shared<State>(std::move(options));auto state=state_;std::thread([state]{run(std::move(state));}).detach();
    }
    ~BackgroundAgentSession()override{close();}
    bool send(CodexTurn input)override{return send_identified(std::move(input),background_host::new_guid());}
    bool send_identified(CodexTurn input,std::string id)override{return deliver(Operation::send,std::move(input),std::move(id));}
    bool busy()const noexcept override{return state_->busy.load();}
    bool queue(CodexTurn input,std::string id)override{return deliver(Operation::queue,std::move(input),std::move(id));}
    bool steer(CodexTurn input,std::string id)override{return deliver(Operation::steer,std::move(input),std::move(id));}
    bool refresh_models()override{return optional_action(models_operation());}
    bool remove_queued(const std::string& id)override{return optional_action(remove_operation(),id);}
    bool edit_queued(const std::string& id,CodexTurn input)override{return optional_action(edit_operation(),id,std::move(input));}
    bool resume_queue()override{return optional_action(resume_operation());}
    bool pause_queue()override{return optional_action(pause_operation());}
    std::vector<AgentQueuedTurn> queued()const override{std::lock_guard lock(state_->gate);return state_->snapshot.queued;}
    std::size_t queued_count()const override{std::lock_guard lock(state_->gate);return state_->snapshot.queued_count;}
    bool queue_paused()const override{std::lock_guard lock(state_->gate);return state_->snapshot.queue_paused;}
    void respond(std::string id,std::string result)override{Command value;value.operation=Operation::respond;value.prompt_id=std::move(id);value.result=std::move(result);if(invoke(std::move(value))!=BackgroundDeliveryDisposition::accepted)throw RpcError("The hosted response was not confirmed. The prompt remains pending; do not assume approval was delivered.");}
    void interrupt()noexcept override{try{enqueue_control(Operation::interrupt);}catch(...){} }
    void shutdown()noexcept override{try{enqueue_control(Operation::shutdown);}catch(...){} }
    void close()noexcept override{
        const auto state=state_;{std::lock_guard lock(state->gate);if(!state->shutdown_requested)state->stop=true;for(const auto& work:state->work)if(!work->in_flight&&work->command.operation!=Operation::shutdown)work->cancelled=true;}state->cv.notify_all();
    }
    std::vector<SessionEvent> take_events()override{
        std::lock_guard lock(state_->gate);auto result=std::move(state_->events);state_->events.clear();state_->event_bytes=0;for(const auto& event:result)if(event.receipt&&(!state_->issued||event.receipt->sequence>state_->issued->sequence))state_->issued=AgentEventCursor{event.receipt->epoch,event.receipt->sequence};state_->cv.notify_all();return result;
    }
    std::optional<AgentEventCursor> pending_persistence()const override{std::lock_guard lock(state_->gate);if(state_->issued&&(!state_->durable||state_->issued->sequence>state_->durable->sequence))return state_->issued;return {};}
    bool confirm_persisted(AgentPersistReceipt receipt)override{
        if(!receipt.transcript_durable||!receipt.index_durable)return false;std::lock_guard lock(state_->gate);if(!state_->issued||!state_->durable||receipt.cursor.epoch!=state_->issued->epoch||receipt.cursor.sequence>state_->issued->sequence||receipt.cursor.sequence<state_->durable->sequence)return false;
        state_->durable=receipt.cursor;state_->ack_target=std::max(state_->ack_target,receipt.cursor.sequence);while(!state_->retained.empty()&&state_->retained.front().sequence<=receipt.cursor.sequence){state_->retained_bytes-=event_size(state_->retained.front().value);state_->retained.pop_front();}state_->cv.notify_all();return true;
    }
    std::optional<AgentEventCursor> acknowledged_persistence()const override{std::lock_guard lock(state_->gate);return state_->acknowledged;}
    BackgroundAgentSnapshot snapshot()const{std::lock_guard lock(state_->gate);return state_->snapshot;}
    std::optional<BackgroundDeliveryDisposition> delivery_disposition(const std::string& id)const{std::lock_guard lock(state_->gate);for(const auto& value:state_->snapshot.outbox)if(value.id==id)return value.disposition;return {};}
    bool worker_finished()const noexcept{return state_->finished.load();}
    // Read-only replay after Root rolls back a failed in-memory apply. No input is submitted and no ACK is sent.
    bool replay_unpersisted(){std::lock_guard lock(state_->gate);if(state_->stop||!state_->events.empty())return false;for(const auto& value:state_->retained)append_hosted_locked(*state_,value);state_->cv.notify_all();return true;}
private:
    static std::string canonical_profile(std::string value){if(value=="default")return value;if(value.size()==36)value="{"+value+"}";const auto id=background_host::guid(std::move(value));if(id=="{00000000-0000-0000-0000-000000000000}")throw std::invalid_argument("Invalid hosted profile identity");return id.substr(1,36);}
    template<class E=Operation>static std::optional<E> models_operation(){if constexpr(requires{E::refresh_models;}){return E::refresh_models;}else{return {};}}
    template<class E=Operation>static std::optional<E> remove_operation(){if constexpr(requires{E::remove_queue;}){return E::remove_queue;}else{return {};}}
    template<class E=Operation>static std::optional<E> edit_operation(){if constexpr(requires{E::edit_queue;}){return E::edit_queue;}else{return {};}}
    template<class E=Operation>static std::optional<E> resume_operation(){if constexpr(requires{E::resume_queue;}){return E::resume_queue;}else{return {};}}
    template<class E=Operation>static std::optional<E> pause_operation(){if constexpr(requires{E::pause_queue;}){return E::pause_queue;}else{return {};}}
    template<class T>static std::string profile(const T& value){if constexpr(requires{value.profile_id;}){return value.profile_id;}else{return {};}}
    template<class T>static std::string account(const T& value){if constexpr(requires{value.account_scope;}){return value.account_scope;}else{return {};}}
    template<class T>static std::string fingerprint(const T& value){if constexpr(requires{value.launch_fingerprint;}){return value.launch_fingerprint;}else{return {};}}
    template<class T>static bool snapshots_included(const T& value){if constexpr(requires{value.snapshots_included;}){return value.snapshots_included;}else{return true;}}
    template<class C>static std::optional<Info> full_status(C& client,const background_host::Key& key,const std::string& epoch){if constexpr(requires{client.status(key,epoch);}){return client.status(key,epoch);}else{return {};}}
    template<class T>static std::size_t queue_size(const T& value){if constexpr(requires{value.queued_count;}){return static_cast<std::size_t>(value.queued_count);}else{return 0;}}
    template<class T>static void extra_snapshot(BackgroundAgentSnapshot& target,const T& value){if constexpr(requires{value.queued;value.queue_paused;}){target.queued=value.queued;target.queue_paused=value.queue_paused;target.queue_known=true;}if constexpr(requires{value.models;}){target.models=value.models;target.models_known=true;}}
    static bool caller_may_wait(){APTTYPE type{};APTTYPEQUALIFIER qualifier{};const auto status=CoGetApartmentType(&type,&qualifier);return FAILED(status)||(type!=APTTYPE_STA&&type!=APTTYPE_MAINSTA);}
    static bool valid_input(const CodexTurn& input){
        if(input.image_paths.size()>64)return false;std::size_t total{};const auto add=[&](const std::string& value,std::size_t cap){if(value.size()>cap||value.find('\0')!=std::string::npos||!local_file::utf8(value)||value.size()>512*1024-total)return false;total+=value.size();return true;};
        if(!add(input.text,512*1024)||!add(input.cwd,32768)||!add(input.model,512)||!add(input.effort,80)||!add(input.service_tier,80))return false;for(const auto& path:input.image_paths)if(!add(path,32768))return false;return !input.text.empty()||!input.image_paths.empty();
    }
    static std::size_t event_size(const SessionEvent& value){return value.id.size()+value.text.size()+value.detail.size()+128;}
    static bool input_operation(Operation value){return value==Operation::send||value==Operation::queue||value==Operation::steer;}
    static std::string operation_text(Operation value){return winrt::to_string(background_host::operation_name(value));}
    static void local_event_locked(State& state,SessionEvent value){const auto bytes=event_size(value);if(state.events.size()<maximum_events&&bytes<=maximum_event_bytes-state.event_bytes){state.event_bytes+=bytes;state.events.push_back(std::move(value));}}
    static void notice_locked(State& state,std::string message,std::string detail){if(state.last_notice==detail)return;state.last_notice=detail;local_event_locked(state,{SessionEvent::Kind::status,{},std::move(message),std::move(detail)});}
    static void disposition_locked(State& state,const Command& command,BackgroundDeliveryDisposition value){
        if(command.delivery_id.empty())return;auto& outbox=state.snapshot.outbox;auto found=std::find_if(outbox.begin(),outbox.end(),[&](const auto& item){return item.id==command.delivery_id;});if(found==outbox.end()){if(outbox.size()>=maximum_outbox){const auto removable=std::find_if(outbox.begin(),outbox.end(),[](const auto& item){return item.disposition==BackgroundDeliveryDisposition::accepted||item.disposition==BackgroundDeliveryDisposition::rejected||item.disposition==BackgroundDeliveryDisposition::not_submitted;});if(removable==outbox.end())return;outbox.erase(removable);}outbox.push_back({command.delivery_id,operation_text(command.operation),value});++state.snapshot.revision;}else if(found->disposition!=value){found->disposition=value;++state.snapshot.revision;}
    }
    static void finish(State& state,const std::shared_ptr<Work>& work,BackgroundDeliveryDisposition result){
        {std::lock_guard lock(state.gate);work->result=result;if(input_operation(work->command.operation))disposition_locked(state,work->command,result);if(work->command.operation==Operation::shutdown)state.stop=true;if(input_operation(work->command.operation)&&(result==BackgroundDeliveryDisposition::rejected||result==BackgroundDeliveryDisposition::not_submitted))local_event_locked(state,{SessionEvent::Kind::delivery_failed,work->command.delivery_id,result==BackgroundDeliveryDisposition::rejected?"The host rejected this input; it was not accepted.":"This input was not submitted to the host.",operation_text(work->command.operation)});if(result==BackgroundDeliveryDisposition::uncertain){state.snapshot.phase=BackgroundAgentPhase::review;++state.snapshot.revision;notice_locked(state,"Delivery was not confirmed. Keep its local ID and review the host's durable status; this input will not be resent.","host_delivery_uncertain");}}
        if(work->reply)try{work->reply->set_value(result);}catch(const std::future_error&){}
    }
    BackgroundDeliveryDisposition invoke(Command command){
        const auto state=state_;if(!caller_may_wait()){std::lock_guard lock(state->gate);notice_locked(*state,"The hosted action requires background dispatch. No input was submitted.","host_action_requires_background");return BackgroundDeliveryDisposition::not_submitted;}
        auto work=std::make_shared<Work>();work->command=std::move(command);work->reply=std::make_shared<std::promise<BackgroundDeliveryDisposition>>();auto future=work->reply->get_future();work->deadline=std::chrono::steady_clock::now()+state->options.action_timeout;
        {std::lock_guard lock(state->gate);if(state->stop||state->shutdown_requested||state->work.size()>=maximum_work||state->snapshot.phase==BackgroundAgentPhase::review||state->snapshot.phase==BackgroundAgentPhase::ended||state->snapshot.phase==BackgroundAgentPhase::detached)return BackgroundDeliveryDisposition::not_submitted;if(input_operation(work->command.operation)){if(state->attempted.size()>=4096||state->attempted.contains(work->command.delivery_id))return BackgroundDeliveryDisposition::not_submitted;state->attempted.emplace(work->command.delivery_id,std::string{});disposition_locked(*state,work->command,BackgroundDeliveryDisposition::pending);}state->work.push_back(work);}state->cv.notify_all();
        if(future.wait_until(work->deadline+state->options.request_timeout)==std::future_status::ready)return future.get();std::lock_guard lock(state->gate);if(work->result)return *work->result;work->cancelled=true;const auto result=work->in_flight?BackgroundDeliveryDisposition::uncertain:BackgroundDeliveryDisposition::not_submitted;disposition_locked(*state,work->command,result);return result;
    }
    bool deliver(Operation operation,CodexTurn input,std::string id){try{if(!valid_input(input))return false;id=background_host::guid(std::move(id));Command command;command.operation=operation;command.delivery_id=std::move(id);command.input=std::move(input);return invoke(std::move(command))==BackgroundDeliveryDisposition::accepted;}catch(...){return false;}}
    bool optional_action(std::optional<Operation> operation,std::string id={},CodexTurn input={}){if(!operation)return false;if(operation==edit_operation()&&!valid_input(input))return false;try{Command command;command.operation=*operation;command.delivery_id=id.empty()?std::string{}:background_host::guid(std::move(id));command.input=std::move(input);return invoke(std::move(command))==BackgroundDeliveryDisposition::accepted;}catch(...){return false;}}
    void enqueue_control(Operation operation){const auto state=state_;auto work=std::make_shared<Work>();work->command.operation=operation;work->deadline=std::chrono::steady_clock::now()+state->options.action_timeout;{std::lock_guard lock(state->gate);if(state->stop||state->shutdown_requested)return;if(operation==Operation::shutdown)state->shutdown_requested=true;for(const auto& pending:state->work)if(input_operation(pending->command.operation)&&!pending->in_flight)pending->cancelled=true;state->work.push_front(std::move(work));}state->cv.notify_all();}
    static void append_hosted_locked(State& state,const background_host::LoggedEvent& logged){auto value=logged.value;value.receipt=AgentEventReceipt{logged.epoch,logged.sequence,logged.delivery_id};const auto bytes=event_size(value);if(state.events.size()>=maximum_events||bytes>maximum_event_bytes-state.event_bytes)throw std::runtime_error("Hosted UI events reached their bounded buffer");state.event_bytes+=bytes;state.events.push_back(std::move(value));}
    static bool same_event(const SessionEvent& a,const SessionEvent& b){return a.kind==b.kind&&a.id==b.id&&a.text==b.text&&a.detail==b.detail;}
    static bool same_prompts(const std::vector<SessionEvent>& a,const std::vector<SessionEvent>& b){return a.size()==b.size()&&std::equal(a.begin(),a.end(),b.begin(),same_event);}
    static void update_snapshot_locked(State& state,const Info& info,bool snapshots_allowed){
        const auto previous_prompts=state.snapshot.prompts;const auto previous_models=state.snapshot.models;const auto previous_profile=state.snapshot.profile_id,previous_scope=state.snapshot.account_scope,previous_hash=state.snapshot.launch_fingerprint;
        const bool metadata_changed=state.snapshot.epoch!=info.epoch||state.snapshot.live!=info.live||state.snapshot.busy!=info.busy||state.snapshot.review!=info.review||state.snapshot.last!=info.last||state.snapshot.acknowledged!=info.acknowledged||previous_profile!=profile(info)||previous_scope!=account(info)||previous_hash!=fingerprint(info)||state.snapshot.queued_count!=queue_size(info);
        state.snapshot.epoch=info.epoch;state.snapshot.live=info.live;state.snapshot.busy=info.busy;state.snapshot.review=info.review;state.snapshot.last=info.last;state.snapshot.acknowledged=info.acknowledged;state.snapshot.profile_id=profile(info);state.snapshot.account_scope=account(info);state.snapshot.launch_fingerprint=fingerprint(info);if(state.snapshot.queued_count!=queue_size(info)){state.snapshot.queue_known=false;state.needs_status=true;}state.snapshot.queued_count=queue_size(info);if(metadata_changed)++state.snapshot.revision;
        if(!state.acknowledged||state.acknowledged->sequence<info.acknowledged)state.acknowledged=AgentEventCursor{info.epoch,info.acknowledged};
        if(snapshots_allowed&&snapshots_included(info)){const auto serialized=winrt::to_string(background_host::encode(info).Stringify());if(state.snapshot_json!=serialized){state.snapshot_json=serialized;++state.snapshot.revision;}extra_snapshot(state.snapshot,info);
            if(!same_prompts(previous_prompts,info.prompts)){for(const auto& old:previous_prompts)if(std::none_of(info.prompts.begin(),info.prompts.end(),[&](const auto& value){return value.id==old.id;}))local_event_locked(state,{SessionEvent::Kind::resolved,old.id,{},"host_prompt_snapshot"});for(const auto& prompt:info.prompts)if(std::none_of(previous_prompts.begin(),previous_prompts.end(),[&](const auto& old){return same_event(old,prompt);}))local_event_locked(state,prompt);}state.snapshot.prompts=info.prompts;if(state.snapshot.models_known&&state.snapshot.models!=previous_models&&!state.snapshot.models.empty())local_event_locked(state,{SessionEvent::Kind::models,{},state.snapshot.models,"host_model_snapshot"});
        }
        if(info.review)state.snapshot.phase=BackgroundAgentPhase::review;else if(!info.live)state.snapshot.phase=BackgroundAgentPhase::ended;else if(state.snapshot.phase!=BackgroundAgentPhase::review)state.snapshot.phase=BackgroundAgentPhase::ready;state.busy.store(info.busy||state.snapshot.phase==BackgroundAgentPhase::connecting||state.snapshot.phase==BackgroundAgentPhase::unavailable);
    }

    static bool binding_ok(const State& state,const Info& info,bool own_start){
        const auto profile_id=profile(info),scope=account(info),hash=fingerprint(info);if(!profile_id.empty()&&canonical_profile(profile_id)!=state.options.expected_profile_id)return false;if(!state.options.expected_account_scope.empty()&&scope!=state.options.expected_account_scope&&!(own_start&&scope.empty()&&state.options.authorized_start&&state.options.authorized_start->launch.saved_account_scope==state.options.expected_account_scope))return false;if(!state.options.expected_launch_fingerprint.empty()&&hash!=state.options.expected_launch_fingerprint)return false;
        if(own_start)return true;return state.options.allow_adoption&&state.options.restored_cursor&&state.options.restored_cursor->epoch==info.epoch&&!profile_id.empty()&&!scope.empty();
    }
    static bool bind(State& state,const Info& info,bool own_start){
        std::lock_guard lock(state.gate);if(info.key!=state.options.key||!binding_ok(state,info,own_start)||!state.fetched||state.fetched->epoch!=info.epoch||state.fetched->sequence<info.acknowledged||state.fetched->sequence>info.last){state.snapshot.phase=BackgroundAgentPhase::review;++state.snapshot.revision;notice_locked(state,"The hosted generation, account binding or durable cursor does not match this conversation. Review it before sending input.","host_binding_review");return false;}state.attached=true;state.own_start=own_start;state.needs_status=true;state.last_notice.clear();update_snapshot_locked(state,info,false);notice_locked(state,"Connected to the owned background session.","host_connected");if(state.durable&&state.durable->sequence>info.acknowledged)state.ack_target=state.durable->sequence;return true;
    }
    static bool attach(State& state,background_host::Client& client){
        const auto ownership=background_host::ownership(*state.options.scope);{std::lock_guard lock(state.gate);if(state.snapshot.ownership!=ownership){state.snapshot.ownership=ownership;++state.snapshot.revision;}}
        const auto sessions=client.list();const Info* found{};for(const auto& item:sessions)if(item.key==state.options.key){if(found)throw std::runtime_error("Duplicate hosted session identity");found=&item;}
        if(found){if(state.own_start)return bind(state,*found,true);if(state.options.authorized_start&&found->epoch==state.options.authorized_start->epoch&&!state.start_attempted){state.start_attempted=true;Command verify;verify.operation=Operation::start;verify.key=state.options.key;verify.epoch=found->epoch;verify.launch=state.options.authorized_start->launch;const auto response=client.call(verify);if(background_host::text(response,L"status",32)=="accepted")return bind(state,background_host::info(response.GetNamedObject(L"session")),true);}return bind(state,*found,false);}
        if(!state.options.authorized_start||state.start_attempted){std::lock_guard lock(state.gate);state.snapshot.phase=BackgroundAgentPhase::review;++state.snapshot.revision;notice_locked(state,"The saved hosted session is unavailable. No provider or input was recreated.","host_session_missing");return false;}
        state.start_attempted=true;Command start;start.operation=Operation::start;start.key=state.options.key;start.epoch=state.options.authorized_start->epoch;start.launch=state.options.authorized_start->launch;const auto result=client.call(start);if(background_host::text(result,L"status",32)!="accepted")throw background_host::OutcomeUncertain();return bind(state,background_host::info(result.GetNamedObject(L"session")),true);
    }
    static BackgroundDeliveryDisposition known_status(std::string_view value){if(value=="accepted")return BackgroundDeliveryDisposition::accepted;if(value=="rejected")return BackgroundDeliveryDisposition::rejected;return BackgroundDeliveryDisposition::uncertain;}
    static void reconcile(State& state,background_host::Client& client){if(state.reconcile_done)return;for(const auto& id:state.options.reconcile_delivery_ids){std::string epoch;{std::lock_guard lock(state.gate);epoch=state.snapshot.epoch;}const auto status=client.delivery_status(state.options.key,epoch,id);Command reference;reference.operation=Operation::send;reference.delivery_id=id;std::lock_guard lock(state.gate);disposition_locked(state,reference,known_status(status));if(status!="accepted"&&status!="rejected"){state.snapshot.phase=BackgroundAgentPhase::review;notice_locked(state,"A previous input has an unknown or uncertain host outcome. It will not be resent.","host_previous_delivery_uncertain");}}state.reconcile_done=true;}
    static void perform(State& state,background_host::Client& client,const std::shared_ptr<Work>& work){
        {std::lock_guard lock(state.gate);work->command.key=state.options.key;work->command.epoch=state.snapshot.epoch;work->in_flight=true;}
        BackgroundDeliveryDisposition disposition{};try{const auto response=client.call(work->command);disposition=known_status(background_host::text(response,L"status",32));if(response.HasKey(L"session")){const auto info=background_host::info(response.GetNamedObject(L"session"));std::lock_guard lock(state.gate);update_snapshot_locked(state,info,false);state.needs_status=true;}}
        catch(const background_host::OutcomeUncertain&){disposition=BackgroundDeliveryDisposition::uncertain;if(input_operation(work->command.operation))try{disposition=known_status(client.delivery_status(state.options.key,work->command.epoch,work->command.delivery_id));}catch(...){}else if(work->command.operation==Operation::resume_queue||work->command.operation==Operation::pause_queue||work->command.operation==Operation::refresh_models){
                // A control may already be durably accepted when its response is lost. Query
                // only the original command ID/digest; never repeat a mutation or new input.
                Command query;query.operation=Operation::command_status;query.key=work->command.key;query.epoch=work->command.epoch;query.target_command_id=work->command.id;query.expected_delivery_digest=background_host::command_fingerprint(work->command);
                while(std::chrono::steady_clock::now()<work->deadline){bool cancelled{};{std::lock_guard lock(state.gate);cancelled=state.stop||work->cancelled;}if(cancelled)break;try{disposition=known_status(background_host::text(client.call(query),L"status",32));break;}catch(...){std::unique_lock lock(state.gate);state.cv.wait_for(lock,std::chrono::milliseconds(10));}}
            }}
        catch(...){disposition=BackgroundDeliveryDisposition::not_submitted;std::lock_guard lock(state.gate);state.attached=false;state.snapshot.phase=BackgroundAgentPhase::unavailable;++state.snapshot.revision;notice_locked(state,"The owned host could not be reached. No duplicate in-app runtime was started.","host_unavailable");}
        finish(state,work,disposition);if(work->command.operation==Operation::shutdown){std::lock_guard lock(state.gate);state.stop=true;}state.cv.notify_all();
    }
    static void poll(State& state,background_host::Client& client){
        AgentEventCursor after;{std::lock_guard lock(state.gate);if(!state.fetched||state.events.size()>maximum_events-128||state.event_bytes>maximum_event_bytes-3*1024*1024||state.retained_bytes>maximum_event_bytes-3*1024*1024)return;after=*state.fetched;}
        const auto batch=client.poll(state.options.key,after.epoch,after.sequence);bool read_status{};
        {std::lock_guard lock(state.gate);if(!state.fetched||state.fetched->epoch!=after.epoch||state.fetched->sequence!=after.sequence)throw std::runtime_error("Hosted poll cursor changed unexpectedly");
            for(const auto& logged:batch.events){if(logged.sequence!=state.fetched->sequence+1||logged.epoch!=state.fetched->epoch)throw std::runtime_error("Hosted event order is invalid");append_hosted_locked(state,logged);state.retained.push_back(logged);state.retained_bytes+=event_size(logged.value);state.fetched->sequence=logged.sequence;
                if(logged.value.kind==SessionEvent::Kind::prompt){std::erase_if(state.snapshot.prompts,[&](const auto& value){return value.id==logged.value.id;});state.snapshot.prompts.push_back(logged.value);state.needs_status=true;}
                else if(logged.value.kind==SessionEvent::Kind::resolved){std::erase_if(state.snapshot.prompts,[&](const auto& value){return value.id==logged.value.id;});state.needs_status=true;}
                else if(logged.value.kind==SessionEvent::Kind::completed){state.snapshot.prompts.clear();state.needs_status=true;}
                else if(logged.value.kind==SessionEvent::Kind::models){state.snapshot.models=logged.value.text;state.needs_status=true;}
                else if(logged.value.kind==SessionEvent::Kind::queued||logged.value.kind==SessionEvent::Kind::queue_changed||logged.value.kind==SessionEvent::Kind::input)state.needs_status=true;
                else if(logged.value.kind==SessionEvent::Kind::account_scope){if(canonical_profile(logged.value.id)!=state.options.expected_profile_id)state.snapshot.phase=BackgroundAgentPhase::review;else if(state.options.expected_account_scope.empty()&&logged.value.text.size()==64&&logged.value.text.find_first_not_of("0123456789abcdef")==std::string::npos)state.options.expected_account_scope=logged.value.text;}
            }
            update_snapshot_locked(state,batch.session,state.fetched->sequence==batch.session.last);if(!binding_ok(state,batch.session,state.own_start)){state.snapshot.phase=BackgroundAgentPhase::review;notice_locked(state,"The hosted account binding changed. No further input will be submitted.","host_binding_changed");}read_status=state.needs_status&&state.fetched->sequence==batch.session.last;
        }
        if(read_status){const auto full=full_status(client,state.options.key,after.epoch);std::lock_guard lock(state.gate);if(!full)state.needs_status=false;else if(state.fetched&&full->epoch==state.fetched->epoch&&full->last<=state.fetched->sequence&&snapshots_included(*full)){update_snapshot_locked(state,*full,true);state.needs_status=false;}}
    }

    static void acknowledge(State& state,background_host::Client& client){
        AgentEventCursor target;{std::lock_guard lock(state.gate);if(!state.durable||!state.ack_target||(state.acknowledged&&state.acknowledged->sequence>=state.ack_target))return;target={state.durable->epoch,state.ack_target};}
        Command command;command.operation=Operation::acknowledge;command.key=state.options.key;command.epoch=target.epoch;command.sequence=target.sequence;const auto result=client.call(command);if(background_host::text(result,L"status",32)!="ok")throw std::runtime_error("Hosted durable ACK was not confirmed");std::lock_guard lock(state.gate);if(!state.acknowledged||state.acknowledged->sequence<target.sequence)state.acknowledged=target;state.snapshot.acknowledged=std::max(state.snapshot.acknowledged,target.sequence);++state.snapshot.revision;
    }
    static void run(std::shared_ptr<State> state){
        try{winrt::init_apartment(winrt::apartment_type::multi_threaded);background_host::Client client(state->options.scope,state->options.expected_host_image,state->options.request_timeout);auto next_poll=std::chrono::steady_clock::now(),next_connect=next_poll;for(;;){std::shared_ptr<Work> work;bool attached{},stop{};{std::lock_guard lock(state->gate);stop=state->stop;attached=state->attached;}if(stop)break;
            if(!attached&&std::chrono::steady_clock::now()>=next_connect){try{attached=attach(*state,client);if(attached)reconcile(*state,client);}catch(...){std::lock_guard lock(state->gate);state->attached=false;state->snapshot.phase=BackgroundAgentPhase::unavailable;state->snapshot.ownership=background_host::Ownership::unavailable;++state->snapshot.revision;notice_locked(*state,"The host connection is unavailable. Held or unverifiable ownership blocks any duplicate runtime.","host_unavailable");}next_connect=std::chrono::steady_clock::now()+state->options.reconnect_interval;}
            {std::lock_guard lock(state->gate);if(!state->work.empty()){const auto candidate=state->work.front();const bool expired=candidate->cancelled||std::chrono::steady_clock::now()>=candidate->deadline;const bool controls=candidate->command.operation==Operation::interrupt||candidate->command.operation==Operation::shutdown;const bool ready=state->attached&&(state->snapshot.phase==BackgroundAgentPhase::ready||controls);if(expired||ready){work=candidate;state->work.pop_front();if(expired)work->cancelled=true;}}}
            if(work){if(work->cancelled)finish(*state,work,BackgroundDeliveryDisposition::not_submitted);else perform(*state,client,work);}
            {std::lock_guard lock(state->gate);attached=state->attached;stop=state->stop;}if(stop)break;
            if(attached){try{acknowledge(*state,client);if(std::chrono::steady_clock::now()>=next_poll){poll(*state,client);next_poll=std::chrono::steady_clock::now()+state->options.poll_interval;}}catch(...){std::lock_guard lock(state->gate);state->attached=false;state->snapshot.phase=BackgroundAgentPhase::unavailable;++state->snapshot.revision;notice_locked(*state,"The host connection was lost. Durable receipts and unconfirmed inputs were retained.","host_connection_lost");}}
            std::unique_lock lock(state->gate);state->cv.wait_for(lock,std::chrono::milliseconds(10));}
        }catch(...){std::lock_guard lock(state->gate);notice_locked(*state,"The host proxy stopped safely. Review its durable state before another input.","host_proxy_stopped");}
        std::deque<std::shared_ptr<Work>> remaining;{std::lock_guard lock(state->gate);state->stop=true;state->snapshot.phase=BackgroundAgentPhase::detached;++state->snapshot.revision;remaining=std::move(state->work);}for(const auto& work:remaining)finish(*state,work,BackgroundDeliveryDisposition::not_submitted);state->busy.store(false);state->finished.store(true);state->cv.notify_all();
    }
};
} // namespace coincide
