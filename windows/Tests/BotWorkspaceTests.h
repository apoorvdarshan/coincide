#pragma once
#include "../App/BotWorkspace.h"

namespace coincide {
inline int bot_workspace_tests(const std::filesystem::path& report){
    const auto directory=std::filesystem::temp_directory_path()/winrt::to_hstring("CoincideBotWorkspace-"+new_id()).c_str();std::size_t checks{};
    const auto check=[&](bool value,const char* message){if(!value)throw std::runtime_error(message);++checks;};
    try{
        const auto home=directory/L"home",custom=directory/L"custom";std::filesystem::create_directories(home);std::filesystem::create_directories(custom);
        {std::ofstream(custom/L"keep.txt")<<"owned fixture file";}
        WorkspaceStore store(directory);auto workspace=store.open();BotStore bots(directory/L"bots",home);bots.open();bots.ensure_starters({});auto bot=bots.records().front();
        bool busy{};std::vector<std::string> invalidated;BotWorkspace controller(workspace,store,bots,[&](const auto&){return busy;},[&](const auto& ids){invalidated=ids;});
        const auto id=controller.open(bots.plan(bot.id,{}));auto& first=workspace.thread(id);
        check(first.bot_id==bot.id&&first.project_id==bots_container_id&&first.bot_folder==winrt::to_string(home.wstring()),"Opening a bot must persist its identity and Home working folder");
        check(first.messages.empty()&&first.draft.empty()&&first.sessions.empty(),"Opening a bot must not send a greeting or start a provider");
        first.messages.push_back({new_id(),"user","Keep original history","codex"});first.draft="Keep this draft";first.model="saved-model";store.save_thread(first);store.save_index(workspace);
        WorkspaceStore reopened(directory);auto restored=reopened.open();reopened.load_thread(restored.thread(id));
        check(restored.thread(id).bot_id==bot.id&&restored.thread(id).bot_folder==first.bot_folder,"Bot identity and folder recovery metadata must survive restart");
        check(controller.conversations(bot.id).size()==1&&controller.conversations(bot.id).front().has_draft,"A bot's history list must include its draft without inventing a new conversation");
        const auto existing=bots.plan(bot.id,controller.conversations(bot.id));check(controller.open(existing)==id,"Open Conversation must resume the latest saved history");
        bot.selection.model="new-default";bot.selection.profile_id="11111111-2222-3333-4444-555555555555";bots.save(bot,[&](const auto& change){controller.before_change(change);});
        check(controller.open(bots.plan(bot.id,controller.conversations(bot.id)))==id&&workspace.thread(id).model=="saved-model"&&workspace.thread(id).draft=="Keep this draft","Changing bot defaults must never overwrite an existing conversation's selections or draft");
        const auto new_id_value=controller.open(bots.plan(bot.id,controller.conversations(bot.id),true));
        check(new_id_value!=id&&workspace.thread(new_id_value).model=="new-default"&&workspace.thread(new_id_value).preferred_profile_id==bot.selection.profile_id&&workspace.thread(id).preferred_profile_id=="default","New Conversation must use current defaults while older histories retain their original profile");
        check(controller.open(bots.plan(bot.id,controller.conversations(bot.id),true))==new_id_value,"New Conversation must reuse an untouched empty bot conversation");
        bot.folder=winrt::to_string(custom.wstring());bot.persona="Changed standing instructions";busy=true;bool rejected{};
        try{bots.save(bot,[&](const auto& change){controller.before_change(change);});}catch(...){rejected=true;}
        check(rejected&&!bots.find(bot.id)->folder&&invalidated.empty(),"A busy bot context edit must fail before metadata or sessions change");
        busy=false;bots.save(bot,[&](const auto& change){controller.before_change(change);});controller.recover_orphans();
        check(invalidated.size()==2&&workspace.thread(id).bot_folder==*bot.folder,"Idle bot context changes must invalidate sessions and persist their current folder");
        const auto transcript=directory/L"threads"/winrt::to_hstring(id+".json").c_str();const auto bytes=[&]{std::ifstream stream(transcript,std::ios::binary);return std::string(std::istreambuf_iterator<char>(stream),{});};const auto before=bytes();
        // Simulate interruption after bot metadata removal and before the workspace index write.
        bots.erase(bot.id);check(controller.recover_orphans(),"An erased bot's remaining histories must be recovered at the next metadata reconciliation");
        check(!workspace.thread(id).bot_id&&!workspace.thread(id).bot_folder&&workspace.thread(id).project_id,"Recovered histories must become ordinary project conversations");
        check(workspace.project(*workspace.thread(id).project_id).path==*bot.folder,"Keeping a conversation must retain its original custom working folder");
        check(bytes()==before&&workspace.thread(id).draft=="Keep this draft","Bot recovery must not rewrite transcript, draft or native session history");
        check(!bots.ensure_starters({})&&bots.records().empty(),"Removing Brulee must not recreate it on the next startup");
        auto second=bots.make_draft({});bots.save(second);const auto remove_id=controller.open(bots.plan(second.id,{}));
        controller.before_remove(second,BotHistoryDisposition::remove);bots.erase(second.id);controller.removed(second.id,BotHistoryDisposition::remove);
        check(workspace.thread(remove_id).deleted_at>0&&!workspace.thread(remove_id).bot_id,"Remove Conversations must use restorable trash metadata");
        check(std::filesystem::exists(custom/L"keep.txt")&&std::filesystem::exists(transcript),"Removing a bot must preserve its working files and saved conversation files");
        auto third=bots.make_draft({});bots.save(third);const auto keep_id=controller.open(bots.plan(third.id,{}));busy=true;rejected=false;
        try{controller.before_remove(third,BotHistoryDisposition::keep_as_chats);}catch(...){rejected=true;}
        check(rejected&&bots.find(third.id)&&workspace.thread(keep_id).bot_id,"Removing a busy bot must leave both bot and history ownership intact");
        busy=false;controller.before_remove(third,BotHistoryDisposition::keep_as_chats);bots.erase(third.id);controller.removed(third.id,BotHistoryDisposition::keep_as_chats);
        check(!workspace.thread(keep_id).bot_id&&!workspace.thread(keep_id).deleted_at,"Keep Conversations must keep histories active as ordinary chats");
        std::filesystem::remove_all(directory);std::ofstream output(report);output<<"PASS: "<<checks<<" Windows bot workspace integration checks\n";return output?0:2;
    }catch(const winrt::hresult_error& error){std::ofstream(report)<<"FAIL: "<<winrt::to_string(error.message())<<'\n';}
    catch(const std::exception& error){std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';}
    std::error_code ignored;std::filesystem::remove_all(directory,ignored);return 1;
}
} // namespace coincide
