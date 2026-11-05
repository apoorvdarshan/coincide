#pragma once
#include "TranscriptFind.h"
#include <unordered_set>
#include <optional>

namespace coincide {
struct ConversationSearchThread {
    std::string id,title,project;
    bool deleted{};
};
struct ConversationSearchHit {
    std::string thread_id,title,project;
    TranscriptFindMatch message;
};
// A search owns metadata and reads one saved transcript at a time. It never loads a
// live Thread or acquires a provider session. The UI must revalidate a selected hit.
class ConversationSearch {
public:
    static constexpr std::size_t maximum_threads=10000,maximum_results=1000;
    static constexpr std::size_t maximum_file_bytes=16*1024*1024,maximum_total_bytes=128*1024*1024;
    struct ReadLimit {};
    using Cancel=TranscriptFind::Cancel;
    using Reader=std::function<std::vector<TranscriptFindDocument>(const std::string&,std::size_t&,const Cancel&)>;
    std::vector<ConversationSearchHit> hits;
    std::size_t searched{},unavailable{},bytes{};
    bool limited{};
    static ConversationSearch search(const std::vector<ConversationSearchThread>& threads,
            std::string query,const Reader& read,Cancel cancel={},std::optional<std::string> project={}) {
        // Validate even an empty source, rather than silently accepting an invalid query.
        (void)TranscriptFind::search({},query,cancel);
        ConversationSearch result;
        if(query.empty())return result;
        if(threads.size()>maximum_threads)throw std::invalid_argument("Too many conversations to search");
        std::unordered_set<std::string> identities;
        for(const auto& thread:threads)if(thread.id.empty()||!identities.insert(thread.id).second)
            throw std::invalid_argument("Search requires distinct conversation identities");
        for(const auto& thread:threads){
            if(cancel&&cancel())throw TranscriptFind::Cancelled{};
            if(thread.deleted||(project&&thread.project!=*project))continue;
            if(result.hits.size()==maximum_results||result.bytes>=maximum_total_bytes){result.limited=true;break;}
            std::vector<TranscriptFindDocument> documents;
            try {if(!read)throw std::runtime_error("Saved message reader is unavailable");documents=read(thread.id,result.bytes,cancel);}
            catch(const ReadLimit&){result.limited=true;break;}
            catch(const TranscriptFind::Cancelled&){throw;}
            catch(...){++result.unavailable;continue;}
            try {
                const auto found=TranscriptFind::search(documents,query,cancel);
                ++result.searched;
                for(const auto& hit:found.matches()){
                    if(result.hits.size()==maximum_results){result.limited=true;return result;}
                    result.hits.push_back({thread.id,thread.title,thread.project,hit});
                }
                if(found.limited())result.limited=true;
            }catch(const TranscriptFind::Cancelled&){throw;}
            catch(...){++result.unavailable;}
        }
        return result;
    }
};
} // namespace coincide
