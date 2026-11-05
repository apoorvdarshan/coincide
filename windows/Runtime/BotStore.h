#pragma once
#include "BotCatalog.h"
#include "ACPFileSystem.h"
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <chrono>
#include <cmath>
#include <functional>
#include <mutex>
#include <set>

namespace coincide {
// Metadata only. Workspace remains the sole owner of botID-bound conversations/transcripts.
// No provider, shell, AGENTS file, user-folder write or Git checkpoint is performed here.
class BotStore {
    using Object=winrt::Windows::Data::Json::JsonObject;using Value=winrt::Windows::Data::Json::JsonValue;using Array=winrt::Windows::Data::Json::JsonArray;
public:
    static constexpr std::size_t maximum_bots=128;
    BotStore(std::filesystem::path directory,std::filesystem::path home):directory_(std::move(directory)),home_(std::move(home)){if(!directory_.is_absolute()||!home_.is_absolute())throw std::invalid_argument("Bots need absolute local app and Home folders");ACPFileSystem home_files(home_);home_=home_files.root();}
    void open(){
        std::lock_guard lock(mutex_);opened_=false;bots_.clear();snapshot_.reset();initialized_=false;lineup_=2;
        if(!std::filesystem::exists(directory_)){opened_=true;return;}auto directory_pin=pin_directory(directory_);ACPFileSystem files(directory_);directory_=files.root();const auto path=directory_/L"bots.json";if(!std::filesystem::exists(path)){opened_=true;return;}
        const auto bytes=files.read(utf8(path));const auto value=Object::Parse(winrt::to_hstring(bytes));fields(value,{L"schema",L"starterLineup",L"addedStarters",L"bots"});if(value.GetNamedNumber(L"schema",0)!=1)throw std::runtime_error("Unsupported bot metadata; the existing file was preserved");
        const auto lineup=value.GetNamedNumber(L"starterLineup",2);if(lineup!=2)throw std::runtime_error("Unsupported bot starter lineup; the existing file was preserved");const auto list=value.GetNamedArray(L"bots");if(list.Size()>maximum_bots)throw std::runtime_error("Too many bots; the existing file was preserved");std::set<std::string> identities;std::vector<BotRecord> loaded;
        for(const auto& raw:list){auto bot=decode(raw.GetObject());if(!identities.insert(bot.id).second)throw std::runtime_error("Duplicate bot identity; the existing file was preserved");loaded.push_back(std::move(bot));}
        bots_=std::move(loaded);initialized_=value.GetNamedBoolean(L"addedStarters");lineup_=2;snapshot_=bytes;opened_=true;
    }
    std::vector<BotRecord> records()const{std::lock_guard lock(mutex_);return bots_;}
    std::optional<BotRecord> find(std::string id)const{std::lock_guard lock(mutex_);id=bot_guid(std::move(id));for(const auto& bot:bots_)if(bot.id==id)return bot;return {};}
    bool ensure_starters(const BotSelection& defaults){
        defaults.validate();std::lock_guard lock(mutex_);require_open();if(initialized_)return false;auto next=bots_;if(std::none_of(next.begin(),next.end(),[](const auto& bot){return bot.starter_id=="brulee";})){if(next.size()>=maximum_bots)throw std::runtime_error("Remove a bot before adding the starter lineup");next.push_back(bot_starter(new_id(),defaults,now_ms()));}commit(next,true);return true;
    }
    BotRecord make_draft(const BotSelection& defaults)const{
        defaults.validate();std::lock_guard lock(mutex_);require_open();const BotCharacter* character=&bot_characters[0];for(const auto& candidate:bot_characters)if(std::none_of(bots_.begin(),bots_.end(),[&](const auto& bot){return bot.character==candidate.id;})){character=&candidate;break;}BotRecord result;result.id=new_id();result.name=character->name;result.character=character->id;result.tint=character->tint;result.personality_id=character->personality;result.selection=defaults;result.created_ms=now_ms();return result;
    }
    BotChange change_for(BotRecord value)const{
        value.id=bot_guid(value.id);value.name=bot_trim(value.name);value.validate();std::lock_guard lock(mutex_);require_open();BotChange change;change.after=std::move(value);for(const auto& bot:bots_)if(bot.id==change.after.id){change.before=bot;break;}if(change.before){if(change.after.created_ms!=change.before->created_ms||change.after.starter_id!=change.before->starter_id)throw std::invalid_argument("Bot origin and creation identity cannot change");change.invalidates_context=change.before->folder!=change.after.folder||change.before->instructions()!=change.after.instructions();change.defaults_changed=change.before->selection!=change.after.selection;}else{if(!change.after.starter_id.empty())throw std::invalid_argument("Only lineup initialization creates starter origins");change.invalidates_context=true;change.defaults_changed=true;}return change;
    }
    // Guard runs synchronously BEFORE the metadata write. Root can reject a running bot context change.
    BotChange save(BotRecord value,const std::function<void(const BotChange&)>& guard={}){
        const auto change=change_for(std::move(value));if(change.after.folder)static_cast<void>(resolve(change.after));if(guard)guard(change);std::lock_guard lock(mutex_);require_open();auto next=bots_;const auto found=std::find_if(next.begin(),next.end(),[&](const auto& bot){return bot.id==change.after.id;});if(change.before){if(found==next.end()||*found!=*change.before)throw std::runtime_error("Bot changed while its edit was being checked; reload before saving");*found=change.after;}else{if(found!=next.end()||next.size()>=maximum_bots)throw std::runtime_error("The bot list changed or reached its limit; reload before saving");next.push_back(change.after);}commit(next,initialized_);return change;
    }
    // Only metadata is erased. The caller explicitly decides how Workspace handles its histories.
    void erase(std::string id,const std::function<void(const BotRecord&)>& guard={}){
        const auto original=find(std::move(id));if(!original)throw std::invalid_argument("Unknown bot");if(guard)guard(*original);std::lock_guard lock(mutex_);require_open();auto next=bots_;const auto found=std::find_if(next.begin(),next.end(),[&](const auto& bot){return bot.id==original->id;});if(found==next.end()||*found!=*original)throw std::runtime_error("Bot changed before removal; reload before removing");next.erase(found);commit(next,initialized_);
    }
    std::filesystem::path working_directory(const BotRecord& bot)const{bot.validate();return resolve(bot);}
    bool broad_folder(const std::filesystem::path& folder)const{ACPFileSystem files(folder);const auto path=files.root();return equal_path(path,home_)||equal_path(path,home_.parent_path())||equal_path(path,path.root_path());}
    BotOpenPlan plan(std::string id,std::vector<BotConversation> histories,bool new_requested=false)const{
        const auto bot=find(std::move(id));if(!bot)throw std::invalid_argument("Unknown bot");if(histories.size()>10000)throw std::invalid_argument("Too many bot conversations");std::set<std::string> threads;
        for(auto& history:histories){history.thread_id=bot_guid(history.thread_id);if(bot_guid(history.bot_id)!=bot->id||!threads.insert(history.thread_id).second)throw std::invalid_argument("Bot conversation ownership is invalid");bot_text(history.title,512,true);if(history.updated_ms<0)throw std::invalid_argument("Invalid bot conversation date");}
        std::stable_sort(histories.begin(),histories.end(),[](const auto& a,const auto& b){return a.updated_ms==b.updated_ms?a.thread_id<b.thread_id:a.updated_ms>b.updated_ms;});const auto folder=resolve(*bot);BotOpenPlan result{bot->id,{},bot->selection,utf8(folder),bot->instructions(),new_requested,broad_folder(folder)};
        for(const auto& history:histories)if(!history.archived&&(!new_requested||(!history.item_count&&!history.has_draft&&!history.busy))){result.existing_thread_id=history.thread_id;break;}return result;
    }
    // Explicit UI action only. Never remove this directory, even if the editor is later cancelled.
    std::string create_managed_folder(std::string id){
        id=bot_guid(std::move(id));std::lock_guard lock(mutex_);require_open();auto directory_pin=prepare_directory();ACPFileSystem root(directory_);const auto base=root.root()/L"Bot Folders";auto base_pin=create_child(base);ACPFileSystem folders(base);const auto path=folders.root()/winrt::to_hstring(id.substr(1,36)).c_str();auto bot_pin=create_child(path);ACPFileSystem bot_files(path);return utf8(bot_files.root());
    }
    std::filesystem::path home()const{return home_;}
    static std::string new_id(){GUID id{};if(FAILED(CoCreateGuid(&id)))throw std::runtime_error("Could not create a bot identity");wchar_t value[40]{};StringFromGUID2(id,value,40);return bot_guid(winrt::to_string(value));}
    static std::int64_t now_ms(){return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();}
private:
    std::filesystem::path directory_,home_;mutable std::mutex mutex_;std::vector<BotRecord> bots_;std::optional<std::string> snapshot_;bool opened_{},initialized_{};unsigned lineup_{2};
    static std::string utf8(const std::filesystem::path& value){return winrt::to_string(value.wstring());}
    static bool equal_path(const std::filesystem::path& a,const std::filesystem::path& b){const auto av=a.wstring(),bv=b.wstring();return CompareStringOrdinal(av.c_str(),-1,bv.c_str(),-1,TRUE)==CSTR_EQUAL;}
    std::filesystem::path resolve(const BotRecord& bot)const{if(!bot.folder)return home_;const std::filesystem::path path(ACPFileSystem::wide(*bot.folder));if(!path.is_absolute())throw std::invalid_argument("A bot folder must be an absolute local Windows folder");ACPFileSystem files(path);return files.root();}
    void require_open()const{if(!opened_)throw std::logic_error("Open valid bot metadata before changing it");}
    static NativeHandle pin_directory(const std::filesystem::path& path){NativeHandle handle(CreateFileW(path.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT|FILE_FLAG_BACKUP_SEMANTICS,nullptr));BY_HANDLE_FILE_INFORMATION info{};if(handle.get()==INVALID_HANDLE_VALUE||!GetFileInformationByHandle(handle.get(),&info)||!(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)||(info.dwFileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_OFFLINE)))throw std::runtime_error("The app-owned bot folder is unsafe");return handle;}
    static NativeHandle create_child(const std::filesystem::path& path){if(!CreateDirectoryW(path.c_str(),nullptr)&&GetLastError()!=ERROR_ALREADY_EXISTS)throw std::runtime_error("Could not create the app-owned bot folder");return pin_directory(path);}
    NativeHandle prepare_directory(){if(std::filesystem::exists(directory_))return pin_directory(directory_);ACPFileSystem parent(directory_.parent_path());directory_=parent.root()/directory_.filename();return create_child(directory_);}
    static void fields(const Object& value,std::initializer_list<std::wstring_view> allowed){for(const auto& field:value)if(std::find(allowed.begin(),allowed.end(),field.Key())==allowed.end())throw std::invalid_argument("Unknown bot metadata field; the existing file was preserved");}
    static std::string text(const Object& value,const wchar_t* key){return winrt::to_string(value.GetNamedString(key));}
    static void put(const Object& object,const wchar_t* key,const std::string& value){object.SetNamedValue(key,Value::CreateStringValue(winrt::to_hstring(value)));}
    static Object encode(const BotRecord& bot){Object result;for(const auto& pair:{std::pair{L"id",&bot.id},{L"name",&bot.name},{L"character",&bot.character},{L"tint",&bot.tint},{L"persona",&bot.persona},{L"personality",&bot.personality_id},{L"customPersonality",&bot.custom_personality},{L"starterID",&bot.starter_id}})put(result,pair.first,*pair.second);result.SetNamedValue(L"personalityEnabled",Value::CreateBooleanValue(bot.personality_enabled));result.SetNamedValue(L"createdMS",Value::CreateNumberValue(static_cast<double>(bot.created_ms)));if(bot.folder)put(result,L"folder",*bot.folder);Object selection;for(const auto& pair:{std::pair{L"provider",&bot.selection.provider},{L"profileID",&bot.selection.profile_id},{L"model",&bot.selection.model},{L"effort",&bot.selection.effort},{L"serviceTier",&bot.selection.service_tier}})put(selection,pair.first,*pair.second);selection.SetNamedValue(L"plan",Value::CreateBooleanValue(bot.selection.plan));selection.SetNamedValue(L"fullAccess",Value::CreateBooleanValue(bot.selection.full_access));result.SetNamedValue(L"selection",selection);return result;}
    static BotRecord decode(const Object& value){
        fields(value,{L"id",L"name",L"character",L"tint",L"persona",L"personality",L"customPersonality",L"starterID",L"createdMS",L"folder",L"selection",L"personalityEnabled"});BotRecord bot;bot.id=bot_guid(text(value,L"id"));bot.name=text(value,L"name");bot.character=text(value,L"character");bot.tint=text(value,L"tint");bot.persona=text(value,L"persona");bot.personality_id=text(value,L"personality");bot.custom_personality=text(value,L"customPersonality");bot.starter_id=text(value,L"starterID");bot.personality_enabled=value.GetNamedBoolean(L"personalityEnabled",true);if(value.HasKey(L"folder"))bot.folder=text(value,L"folder");const auto date=value.GetNamedNumber(L"createdMS");if(!std::isfinite(date)||date!=std::floor(date)||date<0||date>253402300799999.0)throw std::invalid_argument("Invalid bot creation date");bot.created_ms=static_cast<std::int64_t>(date);const auto selection=value.GetNamedObject(L"selection");fields(selection,{L"provider",L"profileID",L"model",L"effort",L"serviceTier",L"plan",L"fullAccess"});bot.selection={text(selection,L"provider"),text(selection,L"profileID"),text(selection,L"model"),text(selection,L"effort"),text(selection,L"serviceTier"),selection.GetNamedBoolean(L"plan"),selection.GetNamedBoolean(L"fullAccess")};bot.validate();return bot;
    }
    void commit(const std::vector<BotRecord>& next,bool initialized){
        if(next.size()>maximum_bots)throw std::invalid_argument("Too many bots");Object value;value.SetNamedValue(L"schema",Value::CreateNumberValue(1));value.SetNamedValue(L"starterLineup",Value::CreateNumberValue(lineup_));value.SetNamedValue(L"addedStarters",Value::CreateBooleanValue(initialized));Array list;for(const auto& bot:next){bot.validate();list.Append(encode(bot));}value.SetNamedValue(L"bots",list);const auto bytes=winrt::to_string(value.Stringify());if(bytes.size()>ACPFileSystem::max_bytes)throw std::invalid_argument("Bot metadata exceeds its local file bound");
        auto directory_pin=prepare_directory();ACPFileSystem files(directory_);directory_=files.root();NativeHandle lease(CreateFileW((directory_/L"bots.lock").c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_ALWAYS,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));BY_HANDLE_FILE_INFORMATION info{};if(lease.get()==INVALID_HANDLE_VALUE||!GetFileInformationByHandle(lease.get(),&info)||(info.dwFileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_OFFLINE))||info.nNumberOfLinks!=1)throw std::runtime_error("Bot metadata is busy or unsafe; reopen before saving");const auto path=directory_/L"bots.json";const auto current=std::filesystem::exists(path)?std::optional(files.read(utf8(path))):std::nullopt;if(current!=snapshot_)throw std::runtime_error("Bots changed in another window; reopen before saving");files.write(utf8(path),bytes);bots_=next;snapshot_=bytes;initialized_=initialized;
    }
};
} // namespace coincide
