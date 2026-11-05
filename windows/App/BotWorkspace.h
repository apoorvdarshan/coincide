#pragma once
#include "WorkspaceStore.h"
#include "../Runtime/BotStore.h"

namespace coincide {
// The metadata store owns bots; Workspace owns conversations. No provider is started here.
// Guards run before changes, and failures leave histories reachable as ordinary chats.
class BotWorkspace {
public:
    using Busy=std::function<bool(const std::string&)>;
    using Invalidate=std::function<void(const std::vector<std::string>&)>;
    BotWorkspace(Workspace& workspace,WorkspaceStore& store,BotStore& bots,Busy busy={},Invalidate invalidate={}):workspace_(workspace),store_(store),bots_(bots),busy_(std::move(busy)),invalidate_(std::move(invalidate)){}

    std::vector<BotConversation> conversations(const std::string& bot_id){
        const auto id=bot_guid(bot_id);std::vector<BotConversation> result;
        for(auto& thread:workspace_.threads)if(thread.bot_id&&bot_guid(*thread.bot_id)==id){
            store_.load_thread(thread);
            result.push_back({thread.id,id,thread.title,thread.updated_at*1000,thread.messages.size(),
                !thread.draft.empty()||!thread.draft_attachments.empty()||!thread.queued_inputs.empty(),thread.archived||thread.deleted_at!=0,busy_&&busy_(thread.id)});
        }
        return result;
    }
    std::string open(const BotOpenPlan& plan){
        const auto bot=bots_.find(plan.bot_id);if(!bot)throw std::runtime_error("This bot was removed. Its saved conversations were preserved.");
        if(plan.existing_thread_id){const auto& thread=workspace_.thread(*plan.existing_thread_id);
            if(!thread.bot_id||bot_guid(*thread.bot_id)!=bot->id||thread.archived||thread.deleted_at)throw std::runtime_error("This bot conversation is no longer available.");
            return thread.id; // Saved model, provider, draft and history always win over new defaults.
        }
        // Re-resolve current defaults/folder after UI callbacks. A stale plan cannot start in an old folder.
        const auto folder=bots_.working_directory(*bot);Thread thread;thread.id=new_id();thread.title=bot->display_name();thread.bot_id=bot->id;
        thread.project_id=std::string(bots_container_id);thread.bot_folder=winrt::to_string(folder.wstring());thread.provider=bot->selection.provider;thread.model=bot->selection.model;
        thread.preferred_profile_id=bot->selection.profile_id;if(*thread.preferred_profile_id!="default")*thread.preferred_profile_id=bot_guid(*thread.preferred_profile_id).substr(1,36);
        thread.effort=bot->selection.effort;thread.service_tier=bot->selection.service_tier;thread.plan=bot->selection.plan;thread.full_access=bot->selection.full_access;
        thread.created_at=thread.updated_at=Workspace::now_seconds();const auto id=thread.id;const auto before=workspace_;
        try{
            const auto project=std::find_if(workspace_.projects.begin(),workspace_.projects.end(),[](const auto& value){return bot_guid(value.id)==bots_container_id;});
            if(project==workspace_.projects.end())workspace_.add_project({std::string(bots_container_id),"Bots",winrt::to_string(bots_.home().wstring())});
            workspace_.add_thread(std::move(thread));store_.load_thread(workspace_.thread(id));store_.save_thread(workspace_.thread(id));store_.save_index(workspace_);
        }catch(...){workspace_=before;throw;}
        return id;
    }
    void before_change(const BotChange& change){
        if(!change.invalidates_context||!change.before)return;const auto ids=identities(change.before->id);guard(ids);
        if(invalidate_)invalidate_(ids); // Dispose idle sessions BEFORE changing standing context.
    }
    void before_remove(const BotRecord& bot,BotHistoryDisposition){const auto ids=identities(bot.id);guard(ids);if(invalidate_)invalidate_(ids);}
    void removed(const std::string& bot_id,BotHistoryDisposition disposition){
        const auto ids=identities(bot_id);const auto before=workspace_;
        try{for(const auto& id:ids)detach(workspace_.thread(id));
            if(disposition==BotHistoryDisposition::remove)workspace_.delete_threads(ids);
            store_.save_index(workspace_);
        }catch(...){workspace_=before;throw;}
    }
    bool recover_orphans(){
        const auto before=workspace_;bool changed{};
        // Cache valid bot folders before removal so restart recovery can retain the same cwd.
        for(auto& thread:workspace_.threads)if(thread.bot_id){const auto bot=bots_.find(*thread.bot_id);
            if(!bot){detach(thread);changed=true;}
            else{try{const auto folder=winrt::to_string(bots_.working_directory(*bot).wstring());if(thread.bot_folder!=folder){thread.bot_folder=folder;changed=true;}}catch(...){/* Missing custom folders stay unavailable; never substitute Home. */}}
        }
        if(changed)try{store_.save_index(workspace_);}catch(...){workspace_=before;throw;}
        return changed;
    }
private:
    Workspace& workspace_;WorkspaceStore& store_;BotStore& bots_;Busy busy_;Invalidate invalidate_;
    void detach(Thread& thread){
        thread.bot_id.reset();if(thread.project_id==bots_container_id)thread.project_id.reset();
        if(thread.bot_folder){const std::filesystem::path folder(winrt::to_hstring(*thread.bot_folder).c_str());
            // Preserve the path even while a drive is offline. Ordinary project delivery will
            // report it unavailable, rather than silently resuming a saved session elsewhere.
            const auto found=std::find_if(workspace_.projects.begin(),workspace_.projects.end(),[&](const auto& project){return project.id!=bots_container_id&&project.path==*thread.bot_folder;});
            if(found!=workspace_.projects.end())thread.project_id=found->id;
            else{const auto id=new_id();const auto name=folder.filename().empty()?std::wstring(L"Bot conversations"):folder.filename().wstring();workspace_.add_project({id,winrt::to_string(name),*thread.bot_folder});thread.project_id=id;}
        }
        thread.bot_folder.reset();
    }
    std::vector<std::string> identities(const std::string& bot_id)const{const auto id=bot_guid(bot_id);std::vector<std::string> result;for(const auto& thread:workspace_.threads)if(thread.bot_id&&bot_guid(*thread.bot_id)==id)result.push_back(thread.id);return result;}
    void guard(const std::vector<std::string>& ids)const{for(const auto& id:ids)if(busy_&&busy_(id))throw std::runtime_error("Stop this bot's agents, close its terminals and finish repository operations before changing its context or removing it.");}
};
} // namespace coincide
