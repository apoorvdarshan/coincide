#pragma once
#include "../Core/Workspace.h"
#include "../Runtime/HostedClientState.h"
#include <type_traits>

namespace coincide {
// Pure preservation plan. It neither opens a store nor creates/contacts a runtime. The owner
// reviews the exact source fingerprint; Root persists both files before retiring metadata.
class HostedInputRecovery {
public:
    struct Plan {
        HostedTerminalInputRecovery input;
        HostedInputRetention retention{HostedInputRetention::unavailable_acknowledged};
        std::string source_fingerprint,preview;
        std::vector<Message> append;
        bool remove_queued{};
        bool available()const noexcept{return retention==HostedInputRetention::original_preserved;}
    };
    struct Effects {std::vector<std::string> rows;bool queue_changed{};};
    static std::string disposition(HostedIntentDisposition value){
        switch(value){case HostedIntentDisposition::rejected:return "rejected";case HostedIntentDisposition::not_submitted:return "not submitted";case HostedIntentDisposition::cancelled:return "future queued work cancelled";default:throw std::invalid_argument("Only a definite saved input can use this recovery");}
    }
    static Plan plan(const Thread& thread,const HostedTerminalInputRecovery& input){
        if(id(thread.id)!=input.key.thread||thread.provider!=input.key.provider||!known_provider(input.key.provider))throw std::invalid_argument("Recovery belongs to another conversation/provider");
        const auto cursor=std::find_if(thread.host_cursors.begin(),thread.host_cursors.end(),[&](const auto& value){return value.provider==input.key.provider;});
        if(cursor==thread.host_cursors.end()||id(cursor->epoch)!=input.binding.epoch||!valid_host_event_cursor(*cursor))throw std::invalid_argument("Recovery belongs to another saved generation");
        const auto state=disposition(input.disposition);const auto operation=input.operation==HostedIntentOperation::send?"send":input.operation==HostedIntentOperation::queue?"queue":input.operation==HostedIntentOperation::steer?"steer":throw std::invalid_argument("Invalid saved input operation");
        if(input.disposition==HostedIntentDisposition::cancelled&&input.operation==HostedIntentOperation::send)throw std::invalid_argument("A direct send cannot be a removed future queue entry");
        if(id(input.delivery_id)!=input.delivery_id)throw std::invalid_argument("Recovery requires the canonical original delivery ID");
        const auto base=input.key.provider+"/"+input.binding.epoch+"/"+input.delivery_id;
        const auto retained_id="terminal-input-retained/"+base;
        const QueuedInput* queued{};const Message* original{},*retained{};
        for(const auto& value:thread.queued_inputs)if(same_id(value.id,input.delivery_id)){if(queued)throw std::runtime_error("The saved input has ambiguous queue identifiers");queued=&value;}
        for(const auto& value:thread.messages){
            if(value.role=="user"&&value.provider==input.key.provider&&same_id(value.id,input.delivery_id)){if(original)throw std::runtime_error("The original user input is ambiguous");original=&value;}
            if(value.id==retained_id){if(retained||value.role!="tool"||value.provider!=input.key.provider)throw std::runtime_error("The retained input reference is ambiguous");retained=&value;}
        }
        Plan result;result.input=input;result.remove_queued=queued!=nullptr;result.retention=queued||original||retained?HostedInputRetention::original_preserved:HostedInputRetention::unavailable_acknowledged;
        std::string source;field(source,"hosted-input-recovery-v1");field(source,input.key.thread);field(source,input.key.provider);field(source,input.binding.epoch);field(source,input.delivery_id);field(source,operation);field(source,state);
        if(queued){field(source,"queue");field(source,queued->id);field(source,queued->text);field(source,queued->model);field(source,queued->effort);field(source,queued->service_tier);field(source,queued->plan?"1":"0");field(source,queued->full_access?"1":"0");attachments(source,queued->attachments);result.preview=preview(queued->text,queued->attachments);
            Message reference{retained_id,"tool","Original saved input retained after explicit recovery. This is historical reference; recovery sent no input.\n\n"+queued->text+"\n\nOriginal delivery ID: "+input.delivery_id+"\nModel: "+queued->model+"\nEffort: "+queued->effort+"\nService tier: "+queued->service_tier+"\nPlan: "+(queued->plan?"true":"false")+"\nFull access: "+(queued->full_access?"true":"false"),input.key.provider,queued->attachments};
            if(retained){std::string existing,expected;message(existing,*retained);message(expected,reference);if(existing!=expected)throw std::runtime_error("The retained reference differs from the current saved input; both were preserved for review");}else result.append.push_back(std::move(reference));
        }
        if(original){field(source,"user");message(source,*original);if(result.preview.empty())result.preview=preview(original->text,original->attachments);}
        if(retained){field(source,"retained");message(source,*retained);if(result.preview.empty())result.preview=preview(retained->text,retained->attachments);}
        if(!result.available())field(source,"unavailable");result.source_fingerprint=local_file::sha256(source);
        const auto notice_id="terminal-input-recovery/"+base+(result.available()?"/preserved":"/unavailable");
        const auto existing=std::find_if(thread.messages.begin(),thread.messages.end(),[&](const auto& value){return value.id==notice_id;});
        Message decision{notice_id,"tool","Owner reviewed saved input metadata. Recorded state: "+state+". Original delivery ID: "+input.delivery_id+". "+(result.available()?"The exact saved input remains in the conversation, including any retained attachments. ":"The original payload could not be located by its saved ID; the owner acknowledged that absence. Existing messages, draft, attachments and other saved inputs were preserved. ")+"Recovery sent no input and started no provider. This decision clears only the definite saved input metadata.",input.key.provider,{}};
        if(existing!=thread.messages.end()){std::string previous,expected;message(previous,*existing);message(expected,decision);if(previous!=expected)throw std::runtime_error("The saved recovery decision conflicts with another message");}else result.append.push_back(std::move(decision));
        return result;
    }
    static Effects apply(Thread& thread,const Plan& reviewed,bool owner_reviewed){
        if(!owner_reviewed)throw std::invalid_argument("Saved input recovery requires the owner's explicit choice");
        auto current=plan(thread,reviewed.input);
        if(current.source_fingerprint!=reviewed.source_fingerprint||current.retention!=reviewed.retention)throw std::runtime_error("The original saved input changed after review; review it again");
        Effects effects;effects.queue_changed=current.remove_queued;for(const auto& value:current.append)effects.rows.push_back(value.id);
        auto queued=thread.queued_inputs;if(current.remove_queued)std::erase_if(queued,[&](const auto& value){return same_id(value.id,reviewed.input.delivery_id);});
        thread.messages.reserve(thread.messages.size()+current.append.size());
        static_assert(std::is_nothrow_move_constructible_v<Message>);
        for(auto& value:current.append)thread.messages.push_back(std::move(value));thread.queued_inputs.swap(queued);return effects;
    }
private:
    static std::string id(std::string value){if(value.size()==36)value="{"+value+"}";return background_host::guid(std::move(value));}
    static bool same_id(const std::string& a,const std::string& b){try{return id(a)==id(b);}catch(...){return false;}}
    static void field(std::string& out,std::string_view value){constexpr std::size_t maximum=4*1024*1024;const auto prefix=std::to_string(value.size())+":";if(value.size()>maximum||out.size()>maximum||prefix.size()>maximum-out.size()||value.size()>maximum-out.size()-prefix.size())throw std::invalid_argument("Saved recovery payload exceeds its bound");out+=prefix;out.append(value);}
    static void attachments(std::string& out,const std::vector<MessageAttachment>& values){field(out,std::to_string(values.size()));for(const auto& value:values){field(out,value.path);field(out,value.name);field(out,value.media_type);}}
    static void message(std::string& out,const Message& value){field(out,value.id);field(out,value.role);field(out,value.provider);field(out,value.text);attachments(out,value.attachments);}
    static std::string preview(const std::string& text,const std::vector<MessageAttachment>& values){auto end=std::min<std::size_t>(text.size(),8192);while(end&&end<text.size()&&(static_cast<unsigned char>(text[end])&0xc0)==0x80)--end;auto result=text.substr(0,end);if(end<text.size())result+="\n[Preview shortened; the complete original is retained.]";for(const auto& value:values)result+="\nAttachment: "+value.name+" ("+value.media_type+")";return result;}
};
} // namespace coincide
