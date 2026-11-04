#pragma once
#include <windows.h>
#include "../Core/Workspace.h"
#include "AgentSession.h"
#include <map>
#include <set>
#include <type_traits>

namespace coincide {
// Root initializes this from its verified host/provider binding. No runtime, COM, UI or store
// ownership is kept here. The Thread cursor is the applied prefix, never a host ACK.
struct HostedConversationState {
    std::string thread_id,provider,epoch,profile_id{"default"},account_scope,status,transport_status;
    std::map<std::string,SessionEvent> prompts;
    std::vector<CodexModel> models;
    bool awaiting_completion{},completion_received{},failed{},notify_completion{};
    std::string active_delivery_id,native_turn_id;
    friend void swap(HostedConversationState& a,HostedConversationState& b)noexcept{
        a.thread_id.swap(b.thread_id);a.provider.swap(b.provider);a.epoch.swap(b.epoch);a.profile_id.swap(b.profile_id);a.account_scope.swap(b.account_scope);a.status.swap(b.status);a.transport_status.swap(b.transport_status);a.prompts.swap(b.prompts);a.models.swap(b.models);a.active_delivery_id.swap(b.active_delivery_id);a.native_turn_id.swap(b.native_turn_id);using std::swap;swap(a.awaiting_completion,b.awaiting_completion);swap(a.completion_received,b.completion_received);swap(a.failed,b.failed);swap(a.notify_completion,b.notify_completion);
    }
};
struct HostedConversationEffects {
    bool durable_changed{},cursor_advanced{},transcript_changed{},index_changed{},runtime_changed{};
    bool output_changed{},queue_changed{},prompts_changed{},models_changed{},status_changed{};
    bool activity{},needs_response{},notify_response{},notify_completion{},completion{};
    bool completion_success{},completion_uncertain{},usage_malformed{};
    std::string completion_outcome,input_id,session_id,native_turn_id;
    std::optional<UsageObservation> usage;
    std::optional<QueuedInput> delivered_input;
    std::optional<AgentEventCursor> applied_cursor;
};
enum class HostedApplyStatus {applied,duplicate,review};
enum class HostedReviewReason {none,binding,epoch,cursor,gap,missing_receipt,malformed_event,unknown_input,application_failure};
struct HostedApplyResult {
    HostedApplyStatus status{HostedApplyStatus::review};HostedReviewReason reason{HostedReviewReason::none};HostedConversationEffects effects;
};
class HostedConversationReducer {
    // Stage only fields this event can change. The loaded transcript/draft/settings remain
    // borrowed until every validation/allocation succeeds; commit performs no allocations.
    struct ThreadEdit {
        Thread& original;
        std::optional<std::vector<NativeSession>> sessions;
        std::optional<std::vector<QueuedInput>> queued;
        std::optional<Message> append;
        std::optional<std::size_t> text_row;
        std::string replacement_text;
        explicit ThreadEdit(Thread& value):original(value){}
        std::vector<NativeSession>& session_rows(){if(!sessions)sessions=original.sessions;return *sessions;}
        std::vector<QueuedInput>& queue_rows(){if(!queued)queued=original.queued_inputs;return *queued;}
        std::size_t message_count()const{return original.messages.size()+(append?1:0);}
        void prepare_last_allocation(){if(append)original.messages.reserve(original.messages.size()+1);}
        void commit()noexcept{
            static_assert(std::is_nothrow_move_constructible_v<Message>);
            static_assert(std::is_nothrow_swappable_v<std::vector<NativeSession>>&&std::is_nothrow_swappable_v<std::vector<QueuedInput>>);
            // reserve was the last fallible operation. There is capacity for one nothrow Message
            // move; replacing an existing output swaps only its prepared string, not its row.
            if(append)original.messages.push_back(std::move(*append));
            if(text_row)original.messages[*text_row].text.swap(replacement_text);
            if(sessions)original.sessions.swap(*sessions);
            if(queued)original.queued_inputs.swap(*queued);
        }
    };
    struct Invalid {HostedReviewReason reason;};
    static void require(bool valid,HostedReviewReason reason=HostedReviewReason::malformed_event){if(!valid)throw Invalid{reason};}
    static std::string guid(std::string_view value){
        if(value.size()==38&&value.front()=='{'&&value.back()=='}')value=value.substr(1,36);
        require(value.size()==36,HostedReviewReason::binding);bool nonzero{};std::string result;result.reserve(36);
        for(std::size_t i=0;i<value.size();++i){auto ch=value[i];if(i==8||i==13||i==18||i==23)require(ch=='-',HostedReviewReason::binding);else{require((ch>='0'&&ch<='9')||(ch>='a'&&ch<='f')||(ch>='A'&&ch<='F'),HostedReviewReason::binding);nonzero=nonzero||ch!='0';if(ch>='A'&&ch<='F')ch=static_cast<char>(ch+32);}result.push_back(ch);}require(nonzero,HostedReviewReason::binding);return result;
    }
    static bool identity(const std::string& a,const std::string& b){if(a==b)return true;try{return guid(a)==guid(b);}catch(...){return false;}}
    static std::string identity_key(const std::string& value){try{return "guid:"+guid(value);}catch(...){return "raw:"+value;}}
    static std::string lower(std::string value){for(auto& ch:value)if(ch>='A'&&ch<='Z')ch=static_cast<char>(ch+32);return value;}
    static void text(const std::string& value,std::size_t maximum,bool empty=true,bool multiline=true){
        require(value.size()<=maximum&&(empty||!value.empty())&&value.find('\0')==std::string::npos);
        try{for(std::size_t at=0;at<value.size();){const auto code=workspace_text::next(value,at);if(!multiline)require(code>=32&&code!=127);}}catch(const Invalid&){throw;}catch(...){throw Invalid{HostedReviewReason::malformed_event};}
    }
    static bool same_event(const SessionEvent& a,const SessionEvent& b){return a.kind==b.kind&&a.id==b.id&&a.text==b.text&&a.detail==b.detail;}
    static bool same_models(const std::vector<CodexModel>& a,const std::vector<CodexModel>& b){
        if(a.size()!=b.size())return false;for(std::size_t i=0;i<a.size();++i){const auto& x=a[i];const auto& y=b[i];if(x.id!=y.id||x.model!=y.model||x.display_name!=y.display_name||x.default_effort!=y.default_effort||x.efforts!=y.efforts||x.hidden!=y.hidden||x.is_default!=y.is_default||x.supports_images!=y.supports_images||x.service_tiers.size()!=y.service_tiers.size())return false;for(std::size_t j=0;j<x.service_tiers.size();++j)if(x.service_tiers[j].id!=y.service_tiers[j].id||x.service_tiers[j].name!=y.service_tiers[j].name||x.service_tiers[j].description!=y.service_tiers[j].description)return false;}return true;
    }
    // Windows' GetObject macro can be introduced before or after WinRT JSON projections.
    // Use the projection spelling that this translation unit actually declared, without
    // changing the application's macro state or relying on its header include order.
#pragma push_macro("GetObject")
#ifdef GetObject
#undef GetObject
#endif
    template<class T>static rpc_json::JsonObject json_object(const T& value){if constexpr(requires{value.GetObject();})return value.GetObject();else return value.GetObjectW();}
#pragma pop_macro("GetObject")
    static void structure(const rpc_json::IJsonValue& value,unsigned depth=0,std::size_t* total=nullptr){
        std::size_t count{};if(!total)total=&count;require(depth<=24&&++*total<=50000);
        if(value.ValueType()==rpc_json::JsonValueType::Object){for(const auto& entry:json_object(value)){require(entry.Key().size()<=4096);structure(entry.Value(),depth+1,total);}}
        else if(value.ValueType()==rpc_json::JsonValueType::Array){require(value.GetArray().Size()<=10000);for(const auto& item:value.GetArray())structure(item,depth+1,total);}
    }
    static std::vector<CodexModel> catalog(const std::string& value){
        text(value,512*1024,false);const auto object=rpc_json::JsonObject::Parse(winrt::to_hstring(value));structure(object);const auto entries=object.GetNamedArray(L"data");require(entries.Size()<=4096);std::set<std::string> ids;
        for(const auto& raw:entries){require(raw.ValueType()==rpc_json::JsonValueType::Object);const auto item=json_object(raw);auto id=CodexProtocol::string(item,L"model");if(id.empty())id=CodexProtocol::string(item,L"id");text(id,1024,false,false);require(ids.insert(id).second);}
        auto models=CodexProtocol::catalog_entries(entries);for(const auto& model:models){text(model.id,1024,false,false);text(model.model,1024,false,false);text(model.display_name,4096);text(model.default_effort,1024);require(model.efforts.size()<=128&&model.service_tiers.size()<=128);for(const auto& effort:model.efforts)text(effort,1024,false,false);for(const auto& tier:model.service_tiers){text(tier.id,1024,false,false);text(tier.name,4096);text(tier.description,16384);}}return models;
    }
    static void prompt(const SessionEvent& event){text(event.id,4096,false,false);text(event.text,1024*1024,false);text(event.detail,4096,false,false);const auto object=rpc_json::JsonObject::Parse(winrt::to_hstring(event.text));structure(object);}
    static void validate_binding(const Thread& thread,const HostedConversationState& state){
        require(known_provider(state.provider)&&thread.provider==state.provider&&identity(thread.id,state.thread_id),HostedReviewReason::binding);
        require(valid_session_binding({state.provider,"pending",0,state.profile_id,state.account_scope}),HostedReviewReason::binding);
        for(const auto& saved:thread.sessions)if(saved.provider==state.provider&&!saved.account_scope.empty())require(lower(saved.profile_id)==lower(state.profile_id)&&(state.account_scope.empty()||lower(saved.account_scope)==lower(state.account_scope)),HostedReviewReason::binding);
    }
    static void require_verified_resume(const Thread& thread,const HostedConversationState& state,const SessionEvent& event){
        if(!state.account_scope.empty())return;const auto saved=std::find_if(thread.sessions.begin(),thread.sessions.end(),[&](const auto& value){return value.provider==state.provider&&!value.account_scope.empty();});if(saved==thread.sessions.end())return;
        using K=SessionEvent::Kind;const bool metadata=event.kind==K::account_scope||event.kind==K::status||event.kind==K::error||event.kind==K::catalog_error||event.kind==K::models||event.kind==K::usage||event.kind==K::queued||event.kind==K::queue_changed||event.kind==K::delivery_failed||(event.kind==K::completed&&(state.failed||event.text!="completed"));require(metadata,HostedReviewReason::binding);
    }
    static void validate_thread(const Thread& thread){
        require(thread.messages.size()<=100000&&thread.sessions.size()<=provider_ids.size()&&thread.queued_inputs.size()<=100,HostedReviewReason::binding);Workspace::validate_thread_metadata(thread);
        std::set<std::string> providers,ids;for(const auto& session:thread.sessions){require(known_provider(session.provider)&&!session.id.empty()&&session.acknowledged_messages<=thread.messages.size()&&valid_session_binding(session)&&providers.insert(session.provider).second,HostedReviewReason::binding);text(session.id,4096,false,false);}
        for(const auto& message:thread.messages){require(ids.insert(identity_key(message.id)).second,HostedReviewReason::binding);}
        ids.clear();for(const auto& queued:thread.queued_inputs){text(queued.id,128,false,false);require(ids.insert(identity_key(queued.id)).second,HostedReviewReason::binding);}
    }
    static auto session(ThreadEdit& edit,const HostedConversationState& state){auto& rows=edit.session_rows();return std::find_if(rows.begin(),rows.end(),[&](const auto& value){return value.provider==state.provider;});}
    static void account(ThreadEdit& edit,HostedConversationState& state,const SessionEvent& event,HostedConversationEffects& effects){
        NativeSession binding{state.provider,"pending",0,event.id,event.text};require(valid_session_binding(binding)&&!binding.account_scope.empty(),HostedReviewReason::binding);
        require(lower(binding.profile_id)==lower(state.profile_id)&&(state.account_scope.empty()||lower(state.account_scope)==lower(binding.account_scope)),HostedReviewReason::binding);
        auto existing=session(edit,state);if(existing!=edit.session_rows().end()){require(existing->account_scope.empty()||(lower(existing->account_scope)==lower(binding.account_scope)&&lower(existing->profile_id)==lower(binding.profile_id)),HostedReviewReason::binding);existing->profile_id=binding.profile_id;existing->account_scope=binding.account_scope;effects.transcript_changed=true;}
        state.profile_id=binding.profile_id;state.account_scope=binding.account_scope;
    }
    static void remember(ThreadEdit& edit,HostedConversationState& state,const SessionEvent& event,HostedConversationEffects& effects){
        text(event.id,4096,false,false);auto existing=session(edit,state);NativeSession next{state.provider,event.id,0,state.profile_id,state.account_scope};
        if(existing!=edit.session_rows().end()){if(!existing->account_scope.empty()){require(!state.account_scope.empty()&&lower(existing->account_scope)==lower(state.account_scope)&&lower(existing->profile_id)==lower(state.profile_id),HostedReviewReason::binding);}if(existing->id==event.id)next.acknowledged_messages=existing->acknowledged_messages;}
        require(valid_session_binding(next),HostedReviewReason::binding);if(existing==edit.session_rows().end())edit.session_rows().push_back(std::move(next));else*existing=std::move(next);effects.session_id=event.id;effects.transcript_changed=true;
    }
    static void output(ThreadEdit& edit,const HostedConversationState& state,const SessionEvent& event,HostedConversationEffects& effects){
        const auto& thread=edit.original;text(event.id,4096,false,false);const std::string role=event.kind==SessionEvent::Kind::tool?"tool":"assistant";const auto id=state.provider+"/"+event.id;auto existing=std::find_if(thread.messages.begin(),thread.messages.end(),[&](const auto& value){return value.id==id;});
        if(existing==thread.messages.end()){require(thread.messages.size()<100000);edit.append=Message{id,role,event.text,state.provider};}
        else{require(existing->role==role&&existing->provider==state.provider);require(existing->text.size()<=8*1024*1024);if(event.kind==SessionEvent::Kind::text_delta){require(event.text.size()<=8*1024*1024-existing->text.size());edit.replacement_text=existing->text;edit.replacement_text+=event.text;edit.text_row=static_cast<std::size_t>(existing-thread.messages.begin());}else if(!event.text.empty()){edit.replacement_text=event.text;edit.text_row=static_cast<std::size_t>(existing-thread.messages.begin());}}
        effects.output_changed=true;effects.transcript_changed=true;effects.activity=true;
    }
    static void input(ThreadEdit& edit,HostedConversationState& state,const SessionEvent& event,HostedConversationEffects& effects){
        const auto& thread=edit.original;const auto id=event.receipt&&!event.receipt->delivery_id.empty()?event.receipt->delivery_id:event.id;text(id,128,false,false);
        auto pending=std::find_if(thread.queued_inputs.begin(),thread.queued_inputs.end(),[&](const auto& value){return identity(value.id,id);});auto existing=std::find_if(thread.messages.begin(),thread.messages.end(),[&](const auto& value){return identity(value.id,id);});
        require(pending!=thread.queued_inputs.end()||existing!=thread.messages.end(),HostedReviewReason::unknown_input);
        if(existing!=thread.messages.end()){require(existing->role=="user"&&existing->provider==state.provider,HostedReviewReason::unknown_input);if(pending!=thread.queued_inputs.end()){require(existing->text==pending->text&&existing->attachments.size()==pending->attachments.size(),HostedReviewReason::unknown_input);for(std::size_t i=0;i<existing->attachments.size();++i){const auto& a=existing->attachments[i];const auto& b=pending->attachments[i];require(a.path==b.path&&a.name==b.name&&a.media_type==b.media_type,HostedReviewReason::unknown_input);}}}
        else{require(thread.messages.size()<100000);edit.append=Message{pending->id,"user",pending->text,state.provider,pending->attachments};effects.transcript_changed=true;}
        if(pending!=thread.queued_inputs.end()){effects.input_id=pending->id;effects.delivered_input=*pending;auto& queued=edit.queue_rows();queued.erase(queued.begin()+(pending-thread.queued_inputs.begin()));effects.transcript_changed=true;effects.queue_changed=true;}else effects.input_id=existing->id;
        state.active_delivery_id=effects.input_id;state.awaiting_completion=true;state.completion_received=false;state.failed=false;state.notify_completion=false;effects.activity=true;
    }
    static bool view_kind(SessionEvent::Kind kind){using K=SessionEvent::Kind;return kind==K::status||kind==K::error||kind==K::catalog_error||kind==K::models||kind==K::prompt||kind==K::resolved;}
    static void reduce(ThreadEdit& edit,HostedConversationState& state,const SessionEvent& event,HostedConversationEffects& effects,bool durable){
        using K=SessionEvent::Kind;effects.runtime_changed=true;
        switch(event.kind){
        case K::account_scope:account(edit,state,event,effects);break;
        case K::session:remember(edit,state,event,effects);break;
        case K::started:if(state.completion_received)state.failed=false;state.awaiting_completion=true;state.completion_received=false;state.notify_completion=false;state.native_turn_id=event.id;state.status=state.provider+" is working…";effects.native_turn_id=event.id;effects.status_changed=true;break;
        case K::text_delta:case K::text_complete:case K::tool:output(edit,state,event,effects);break;
        case K::models:{auto models=catalog(event.text);effects.models_changed=!same_models(state.models,models);state.models.swap(models);break;}
        case K::catalog_error:case K::status:state.status=event.text;effects.status_changed=true;break;
        case K::error:state.status=event.text;effects.status_changed=true;if(durable)state.failed=true;else state.transport_status=event.text;break;
        case K::queued:case K::queue_changed:effects.queue_changed=true;break;
        case K::delivery_failed:state.status=event.text;effects.queue_changed=true;effects.status_changed=true;break;
        case K::input:input(edit,state,event,effects);break;
        case K::prompt:{prompt(event);const auto old=state.prompts.find(event.id);effects.prompts_changed=old==state.prompts.end()||!same_event(old->second,event);state.prompts.insert_or_assign(event.id,event);require(state.prompts.size()<=64);std::size_t bytes{};for(const auto& [id,value]:state.prompts){(void)id;bytes+=value.id.size()+value.text.size()+value.detail.size();}require(bytes<=512*1024);state.status=state.provider+" is waiting for your response.";effects.status_changed=true;if(durable){effects.activity=effects.prompts_changed;effects.needs_response=effects.prompts_changed;effects.notify_response=effects.prompts_changed;}break;}
        case K::resolved:text(event.id,4096,false,false);effects.prompts_changed=state.prompts.erase(event.id)!=0;break;
        case K::usage:try{effects.usage=UsageProtocol::decode_text(event.text);}catch(...){effects.usage_malformed=true;}break;
        case K::completed:{if(state.completion_received)break;effects.completion=true;effects.completion_success=event.text=="completed"&&!state.failed;effects.completion_uncertain=event.text!="completed"&&event.text!="interrupted";effects.completion_outcome=event.text=="interrupted"?"interrupted":effects.completion_success?"completed":"failed";effects.prompts_changed=!state.prompts.empty();state.prompts.clear();state.completion_received=true;state.notify_completion=true;effects.notify_completion=true;if(!state.failed)state.status=event.text=="interrupted"?"Stopped":"Ready";effects.status_changed=true;if(effects.completion_success){auto current=session(edit,state);if(current!=edit.session_rows().end()){current->acknowledged_messages=edit.message_count();effects.transcript_changed=true;}}break;}
        default:throw Invalid{HostedReviewReason::malformed_event};
        }
        if(durable)state.transport_status.clear();
    }
public:
    static HostedApplyResult apply(Thread& thread,HostedConversationState& state,const SessionEvent& event){
        static_assert(std::is_nothrow_swappable_v<HostedConversationState>);
        static_assert(std::is_nothrow_move_constructible_v<HostedApplyResult>);
        try{
            validate_binding(thread,state);require(static_cast<int>(event.kind)>=0&&static_cast<int>(event.kind)<=static_cast<int>(SessionEvent::Kind::usage));
            auto cursor=std::find_if(thread.host_cursors.begin(),thread.host_cursors.end(),[&](const auto& value){return value.provider==state.provider;});
            if(event.receipt){require(cursor!=thread.host_cursors.end()&&valid_host_event_cursor(*cursor),HostedReviewReason::cursor);require(identity(cursor->epoch,state.epoch)&&identity(event.receipt->epoch,state.epoch),HostedReviewReason::epoch);require(event.receipt->sequence&&event.receipt->sequence<=9007199254740991ULL,HostedReviewReason::cursor);if(event.receipt->sequence<=cursor->sequence)return{HostedApplyStatus::duplicate,HostedReviewReason::none,{}};require(event.receipt->sequence==cursor->sequence+1,HostedReviewReason::gap);if(!event.receipt->delivery_id.empty())(void)guid(event.receipt->delivery_id);}
            else require(view_kind(event.kind),HostedReviewReason::missing_receipt);
            text(event.id,4096);require(event.text.size()<=1024*1024);if(event.kind!=SessionEvent::Kind::usage)text(event.text,1024*1024);text(event.detail,1024*1024);if(event.receipt){validate_thread(thread);require_verified_resume(thread,state,event);}
            ThreadEdit edit(thread);HostedConversationState next=state;HostedApplyResult result{HostedApplyStatus::applied,HostedReviewReason::none,{}};reduce(edit,next,event,result.effects,event.receipt.has_value());
            std::optional<HostEventCursor> applied;
            if(event.receipt){applied=*cursor;applied->epoch=event.receipt->epoch;applied->sequence=event.receipt->sequence;result.effects.cursor_advanced=true;result.effects.durable_changed=true;result.effects.index_changed=true;result.effects.applied_cursor=AgentEventCursor{applied->epoch,applied->sequence};}
            // All event parsing, text/queue/session staging, runtime copying and result allocation
            // are complete. A successful append reserve is followed only by nothrow commits.
            edit.prepare_last_allocation();edit.commit();if(applied){cursor->epoch.swap(applied->epoch);cursor->sequence=applied->sequence;}using std::swap;swap(state,next);return result;
        }catch(const Invalid& invalid){return{HostedApplyStatus::review,invalid.reason,{}};}catch(const winrt::hresult_error&){return{HostedApplyStatus::review,HostedReviewReason::malformed_event,{}};}catch(...){return{HostedApplyStatus::review,HostedReviewReason::application_failure,{}};}
    }
};
} // namespace coincide
