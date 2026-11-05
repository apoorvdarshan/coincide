#pragma once
#include "Workspace.h"
#include <functional>

namespace coincide {
enum class PaletteKind { command, project, thread };
struct PaletteEntry {
    PaletteKind kind{};
    std::string id,title,detail;
    bool enabled{true};
    friend bool operator==(const PaletteEntry&,const PaletteEntry&)=default;
};
struct PaletteResults {std::vector<PaletteEntry> entries;bool limited{};};
// Search metadata only. Opening a result is a separate, revalidated UI action;
// neither matching nor constructing this snapshot reads transcripts or starts a provider.
struct CommandPalette {
    static constexpr std::size_t maximum_entries=20000,maximum_results=100,maximum_bytes=8*1024*1024;
    struct Cancelled {};
    static PaletteResults search(const std::vector<PaletteEntry>& entries,std::string_view query,const std::function<bool()>& cancel={}) {
        if(entries.size()>maximum_entries||query.size()>1024||query.find('\0')!=std::string_view::npos)throw std::invalid_argument("Command palette snapshot or query exceeds its bound");
        const auto folded=workspace_text::fold(query);std::vector<std::string> terms;
        std::size_t first{};for(std::size_t at=0;at<folded.size();){const auto start=at;if(workspace_text::whitespace(workspace_text::next(folded,at))){if(start>first)terms.push_back(folded.substr(first,start-first));first=at;}}
        if(first<folded.size())terms.push_back(folded.substr(first));
        std::unordered_set<std::string> identities;std::size_t bytes{};
        struct Match {std::size_t index;unsigned rank;};std::vector<Match> matches;
        for(std::size_t i=0;i<entries.size();++i){
            if(cancel&&cancel())throw Cancelled{};
            const auto& entry=entries[i];
            if(entry.id.empty()||entry.id.size()>256||entry.title.empty()||entry.title.size()>4096||entry.detail.size()>8192||entry.id.find('\0')!=std::string::npos||entry.title.find('\0')!=std::string::npos||entry.detail.find('\0')!=std::string::npos)throw std::invalid_argument("Invalid command palette metadata");
            if(entry.kind!=PaletteKind::command&&entry.kind!=PaletteKind::project&&entry.kind!=PaletteKind::thread)throw std::invalid_argument("Invalid command palette target kind");
            const auto size=entry.id.size()+entry.title.size()+entry.detail.size();if(size>maximum_bytes-bytes)throw std::invalid_argument("Command palette metadata exceeds its bound");bytes+=size;
            if(!identities.insert(std::to_string(static_cast<unsigned>(entry.kind))+":"+entry.id).second)throw std::invalid_argument("Duplicate command palette target");
            const auto title=workspace_text::fold(entry.title),detail=workspace_text::fold(entry.detail);(void)workspace_text::fold(entry.id);
            if(!entry.enabled)continue;
            const auto haystack=title+"\n"+detail;
            if(!std::all_of(terms.begin(),terms.end(),[&](const auto& term){return haystack.find(term)!=std::string::npos;}))continue;
            const auto rank=terms.empty()?3U:title==folded?0U:title.starts_with(folded)?1U:title.find(folded)!=std::string::npos?2U:3U;
            matches.push_back({i,rank});
        }
        if(cancel&&cancel())throw Cancelled{};
        std::stable_sort(matches.begin(),matches.end(),[](const auto& a,const auto& b){return a.rank<b.rank;});
        PaletteResults result;result.limited=matches.size()>maximum_results;
        for(std::size_t i=0;i<std::min(matches.size(),maximum_results);++i)result.entries.push_back(entries[matches[i].index]);
        return result;
    }
};
} // namespace coincide
