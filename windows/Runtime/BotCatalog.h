#pragma once
#include <algorithm>
#include <array>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace coincide {
struct BotPersonalityPreset {std::string_view id,name,summary,greeting,prompt;};
// Kept in the same order as CoincideKit/Models/BotPersonalityPreset.swift.
inline constexpr BotPersonalityPreset bot_personalities[]={
{"cheerful","Cheerful","Warm, upbeat and encouraging.","Hi there! So glad you stopped by. What are we doing today?","Be warm, upbeat and encouraging. Greet the user brightly, celebrate small wins and keep a light, friendly tone even when something goes wrong: reassure first, then get to the fix. An exclamation mark now and then is fine, but stay genuine rather than gushing, and never let the cheer get in the way of an accurate, useful answer."},
{"calm","Calm & Concise","Steady, brief and to the point.","Hello. What do you need?","Be calm, unhurried and brief. Lead with the answer in a sentence or two, and skip greetings, filler and repetition. Use a short list only when it makes things clearer. Keep a steady, reassuring tone when something breaks, and add detail only when the user asks for it or the task needs it."},
{"witty","Witty","Clever, with a light touch of humor.","Ah, a fresh puzzle. My favorite kind. What have you got?","Be clever and lightly playful. A quick quip, a wry aside or a well-placed pun is welcome when the moment allows, but the substance always comes first and the humor is never at the user's expense. Drop the jokes when the user is frustrated, the stakes are high or the topic is serious."},
{"mentor","Mentor","Patient, and explains the why.","Hi! Tell me what you’re working on, and we’ll go through it together.","Be a patient mentor. Explain the why behind an answer, not just the what, building on what the user already knows and using small, concrete examples. When the user is learning, offer a hint or a guiding question before the full solution, check that it landed, and suggest one thing worth learning next. Never make anyone feel slow for asking."},
{"coach","Coach","Keeps you motivated and moving.","Let’s make today count. What’s the one thing you want done?","Be an energetic, encouraging coach. Help the user pin down a clear goal, break the work into small steps and keep the momentum going: end a reply with the single most useful next action. Notice progress and say so. Nudge when things stall, but respect the user's pace and decisions."},
{"candid","Straight Shooter","Honest, direct and questions assumptions.","Hi. Tell me the plan, and I’ll tell you honestly what I think.","Be a straight shooter. Give your honest assessment first, including when you disagree or think a plan is risky, and say why in plain words. Question assumptions, point out what could go wrong or is missing, and say how confident you are. Stay respectful and constructive: challenge ideas, never the person, and once the user has heard you out, go with their decision."},
{"curious","Curious Explorer","Asks good questions and spots connections.","Ooh, something new? Tell me more. What are we exploring?","Be a curious explorer. Show real interest in the problem, ask a good clarifying question when the answer would change because of it, and briefly point out interesting connections, alternatives or side paths worth a look. Think aloud a little about what you are checking and why, then land on a clear answer."},
{"professional","Professional","Polished, precise and formal.","Good day. How can I help you?","Be polished and professional. Use a courteous, neutral tone, precise wording and a clean structure, without slang, jokes or emoji. Lead with the outcome, state assumptions and next steps explicitly, and keep replies concise enough to forward to a colleague as they are."},
{"gentle","Gentle","Kind, reassuring and never rushed.","Hey, no rush at all. What can I help you with?","Be gentle, kind and reassuring. Acknowledge it when something is frustrating, take things one step at a time and phrase suggestions softly. Never rush or judge, and make it easy to ask anything, however small. Keep the warmth in the words, not in extra length."},
{"creative","Creative","Imaginative and full of ideas.","I’ve got ideas bubbling already. What shall we make?","Be imaginative and full of ideas. Offer a few distinct options or angles rather than a single one, suggest unexpected but workable twists, and use vivid language and analogies. When the user picks a direction, build on it with enthusiasm, and keep every idea practical enough to act on."},
};
struct BotCharacter {std::string_view id,name,tint,personality;};
inline constexpr BotCharacter bot_characters[]={
{"alien","Alien","leaf","curious"},{"star","Star","sunflower","coach"},{"croissant","Croissant","tangerine","calm"},{"bomboloni","Bomboloni","sunflower","gentle"},{"cherry","Cherry","cherry","witty"},{"teddy","Teddy","caramel","mentor"},{"brulee","Brulee","rose","cheerful"}};
inline constexpr std::string_view bot_tints[]={"sunflower","tangerine","coral","cherry","rose","lilac","sky","mint","leaf","sage","caramel"};
inline const BotPersonalityPreset* bot_personality(std::string_view id){for(const auto& item:bot_personalities)if(item.id==id)return &item;return nullptr;}
inline const BotCharacter* bot_character(std::string_view id){for(const auto& item:bot_characters)if(item.id==id)return &item;return nullptr;}
// UTF-8 scalar validation never truncates a multi-byte character or accepts overlong/surrogate encodings.
inline std::size_t bot_text(std::string_view value,std::size_t limit,bool multiline=false,bool empty=true){
    if(value.size()>limit*4||(!empty&&value.empty()))throw std::invalid_argument("Bot text exceeds its limit");std::size_t count{};
    for(std::size_t i=0;i<value.size();){const auto first=static_cast<unsigned char>(value[i++]);std::uint32_t c=first;unsigned extra{};if(first>=0xc2&&first<=0xdf){c=first&31;extra=1;}else if(first>=0xe0&&first<=0xef){c=first&15;extra=2;}else if(first>=0xf0&&first<=0xf4){c=first&7;extra=3;}else if(first>=0x80)throw std::invalid_argument("Invalid bot UTF-8");
        if(i+extra>value.size())throw std::invalid_argument("Invalid bot UTF-8");for(unsigned j=0;j<extra;++j){const auto next=static_cast<unsigned char>(value[i++]);if((next&0xc0)!=0x80)throw std::invalid_argument("Invalid bot UTF-8");c=(c<<6)|(next&63);}if((extra==1&&c<0x80)||(extra==2&&c<0x800)||(extra==3&&c<0x10000)||c>0x10ffff||(c>=0xd800&&c<=0xdfff)||c==0||(c<32&&(!multiline||(c!=9&&c!=10&&c!=13)))||c==127||++count>limit)throw std::invalid_argument("Invalid or oversized bot text");
    }return count;
}
inline std::string bot_trim(std::string_view value){
    const auto whitespace=[](std::uint32_t c){return (c>=9&&c<=13)||c==32||c==0x85||c==0xa0||c==0x1680||(c>=0x2000&&c<=0x200a)||c==0x2028||c==0x2029||c==0x202f||c==0x205f||c==0x3000;};std::size_t first=value.size(),last{};
    for(std::size_t i=0;i<value.size();){const auto at=i;const auto byte=static_cast<unsigned char>(value[i++]);std::uint32_t c=byte;unsigned extra{};if(byte>=0xc2&&byte<=0xdf){c=byte&31;extra=1;}else if(byte>=0xe0&&byte<=0xef){c=byte&15;extra=2;}else if(byte>=0xf0&&byte<=0xf4){c=byte&7;extra=3;}if(i+extra>value.size())return std::string(value);for(unsigned j=0;j<extra;++j)c=(c<<6)|(static_cast<unsigned char>(value[i++])&63);if(!whitespace(c)){if(first==value.size())first=at;last=i;}}
    return first==value.size()?std::string{}:std::string(value.substr(first,last-first));
}
inline std::string bot_guid(std::string value){if(value.size()==38&&value.front()=='{'&&value.back()=='}')value=value.substr(1,36);if(value.size()!=36)throw std::invalid_argument("Invalid bot identity");for(std::size_t i=0;i<value.size();++i){auto& c=value[i];if(i==8||i==13||i==18||i==23){if(c!='-')throw std::invalid_argument("Invalid bot identity");}else{if(c>='A'&&c<='F')c=static_cast<char>(c-'A'+'a');if(!((c>='a'&&c<='f')||(c>='0'&&c<='9')))throw std::invalid_argument("Invalid bot identity");}}if(value=="00000000-0000-0000-0000-000000000000")throw std::invalid_argument("Invalid bot identity");return "{"+value+"}";}
inline bool bot_provider(std::string_view id){return id=="codex"||id=="claude"||id=="opencode"||id=="cursor"||id=="grok"||id=="antigravity";}
struct BotSelection {
    std::string provider{"codex"},profile_id{"default"},model,effort,service_tier;bool plan{},full_access{};
    bool operator==(const BotSelection&)const=default;
    void validate()const{if(!bot_provider(provider))throw std::invalid_argument("Unknown bot provider");if(profile_id!="default")static_cast<void>(bot_guid(profile_id));bot_text(model,256);bot_text(effort,64);bot_text(service_tier,64);}
};
struct BotRecord {
    std::string id,name,character{"alien"},tint{"leaf"},persona,personality_id,custom_personality;
    BotSelection selection;std::optional<std::string> folder;std::int64_t created_ms{};std::string starter_id;bool personality_enabled{true};
    bool operator==(const BotRecord&)const=default;
    void validate()const{static_cast<void>(bot_guid(id));bot_text(name,120,false,false);if(bot_trim(name).empty())throw std::invalid_argument("A bot needs a name");if(!bot_character(character)||std::find(std::begin(bot_tints),std::end(bot_tints),tint)==std::end(bot_tints))throw std::invalid_argument("Unknown bot artwork");bot_text(persona,20000,true);bot_text(custom_personality,4000,true);bot_text(personality_id,128);bot_text(starter_id,128);selection.validate();if(folder){bot_text(*folder,240,false,false);}if(created_ms<0||created_ms>253402300799999LL)throw std::invalid_argument("Invalid bot creation date");}
    std::string display_name()const{const auto value=bot_trim(name);return value.empty()?"Bot":value;}
    std::string personality_prompt()const{if(!personality_enabled)return {};if(!personality_id.empty()){const auto preset=bot_personality(personality_id);return preset?std::string(preset->prompt):std::string{};}return bot_trim(custom_personality);}
    std::string instructions()const{
        validate();const auto job=bot_trim(persona),personality=personality_prompt();std::string result="You are "+display_name()+", one of the user's bots in Coincide, a desktop app for working with coding agents. Each bot is an ongoing conversation with its own personality and job.";
        if(personality.empty()){result+=" Stay in character, keep replies friendly and to the point, and ask before doing anything destructive or hard to undo.";if(!job.empty())result+="\n\n"+job;}
        else{result+=" Stay in character, and ask before doing anything destructive or hard to undo.\n\n## Personality\nHow you talk and behave. It shapes your tone and manner only: your instructions, the user's requests and your safety rules always come first.\n\n"+personality;if(!job.empty())result+="\n\n## Instructions\nYour job, in the user's words.\n\n"+job;}
        bot_text(result,25000,true);return result;
    }
    std::string instructions_block()const{auto body=instructions();std::size_t at{};while((at=body.find("</bot_instructions>",at))!=std::string::npos){body.replace(at,19,"</bot-instructions>");at+=19;}return "<bot_instructions>\nStanding instructions for this whole conversation, set by the user in Coincide. Follow them in every reply. They are context, not a request; the user's message comes after the closing tag.\n\n"+body+"\n</bot_instructions>";}
};
inline BotRecord bot_starter(std::string id,const BotSelection& defaults,std::int64_t now){BotRecord bot;bot.id=bot_guid(std::move(id));bot.name="Brulee";bot.character="brulee";bot.tint="rose";bot.personality_id="cheerful";bot.persona="You are a cheerful everyday helper. Answer quick questions, explain things plainly, do small tasks on this Windows PC (convert a file, rename a batch of photos, work out a command) and suggest a better bot or a project thread when a job grows big. Prefer short answers with the key point first.";bot.selection=defaults;bot.created_ms=now;bot.starter_id="brulee";bot.validate();return bot;}
struct BotConversation {std::string thread_id,bot_id,title;std::int64_t updated_ms{};std::size_t item_count{};bool has_draft{},archived{},busy{};};
struct BotOpenPlan {std::string bot_id;std::optional<std::string> existing_thread_id;BotSelection selection;std::string working_directory,instructions;bool new_requested{},broad_folder{};};
struct BotChange {std::optional<BotRecord> before;BotRecord after;bool invalidates_context{},defaults_changed{};};
enum class BotHistoryDisposition {keep_as_chats,remove};
inline constexpr std::string_view bots_container_id="{b0b5b0b5-c01c-4d1e-b075-000000000001}";
} // namespace coincide
