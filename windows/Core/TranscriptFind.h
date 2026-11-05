#pragma once
#include "Workspace.h"
#include <functional>

namespace coincide {
// Search only saved message bodies. Callers explicitly supply the current conversation;
// drafts, queue entries, provider metadata and unrelated lazy histories are not inputs.
struct TranscriptFindDocument {std::string id,text;};
struct TranscriptFindMatch {
    std::string message_id;std::size_t row{},offset{},length{};
    std::string before,matched,after;bool leading{},trailing{};
};
class TranscriptFind {
public:
    static constexpr std::size_t maximum_query_bytes=1024,maximum_results=10000;
    using Cancel=std::function<bool()>;
    static std::vector<TranscriptFindDocument> snapshot(const std::vector<Message>& messages){
        std::vector<TranscriptFindDocument> result;result.reserve(messages.size());
        for(const auto& message:messages)result.push_back({message.id,message.text});return result;
    }
    // A linear KMP scan keeps only query-sized source offsets. Unicode folding may expand
    // a character (Straße -> strasse); offsets always refer to the original saved bytes.
    static TranscriptFind search(const std::vector<TranscriptFindDocument>& documents,std::string query,Cancel cancelled={}){
        if(query.size()>maximum_query_bytes||query.find('\0')!=std::string::npos)throw std::invalid_argument("Find text is too long or invalid");
        TranscriptFind result;result.query_=std::move(query);const auto needle=workspace_text::fold(result.query_);if(needle.empty())return result;
        std::vector<std::size_t> prefix(needle.size());for(std::size_t i=1,j=0;i<needle.size();++i){while(j&&needle[i]!=needle[j])j=prefix[j-1];if(needle[i]==needle[j])++j;prefix[i]=j;}
        struct Span{std::size_t begin{},end{};};std::vector<Span> ring(needle.size());
        for(std::size_t row=0;row<documents.size();++row){
            if(cancelled&&cancelled())throw Cancelled{};const auto& document=documents[row];std::size_t position{},matched{},cancel_at{};
            for(std::size_t at=0;at<document.text.size();){
                if(position>=cancel_at){if(cancelled&&cancelled())throw Cancelled{};cancel_at=position+4096;}
                const auto begin=at;static_cast<void>(workspace_text::next(document.text,at));const auto folded=workspace_text::fold(std::string_view(document.text).substr(begin,at-begin));
                for(const auto byte:folded){ring[position%needle.size()]={begin,at};while(matched&&byte!=needle[matched])matched=prefix[matched-1];if(byte==needle[matched])++matched;++position;
                    if(matched==needle.size()){
                        if(result.matches_.size()==maximum_results){result.limited_=true;return result;}
                        const auto start=ring[(position-needle.size())%needle.size()].begin;TranscriptFindMatch hit{document.id,row,start,at-start,{},{},{},false,false};
                        auto left=start;for(unsigned n=0;n<72&&left;++n){--left;while(left&&(static_cast<unsigned char>(document.text[left])&0xc0)==0x80)--left;}
                        auto right=at;for(unsigned n=0;n<96&&right<document.text.size();++n)static_cast<void>(workspace_text::next(document.text,right));
                        hit.before=document.text.substr(left,start-left);hit.matched=document.text.substr(start,at-start);hit.after=document.text.substr(at,right-at);hit.leading=left!=0;hit.trailing=right!=document.text.size();result.matches_.push_back(std::move(hit));break;
                    }
                }
                if(!result.matches_.empty()&&result.matches_.back().row==row)break;
            }
        }
        return result;
    }
    struct Cancelled {};
    const std::vector<TranscriptFindMatch>& matches()const{return matches_;}
    const std::string& query()const{return query_;}
    bool limited()const{return limited_;}
    const TranscriptFindMatch* current()const{return matches_.empty()?nullptr:&matches_[active_];}
    std::size_t position()const{return active_;}
    bool select(const std::string& message_id){const auto at=std::find_if(matches_.begin(),matches_.end(),[&](const auto& hit){return hit.message_id==message_id;});if(at==matches_.end())return false;active_=static_cast<std::size_t>(at-matches_.begin());return true;}
    void preserve_selection(const TranscriptFind& previous){if(query_!=previous.query_||!previous.current())return;const auto at=std::find_if(matches_.begin(),matches_.end(),[&](const auto& hit){return hit.message_id==previous.current()->message_id;});if(at!=matches_.end())active_=static_cast<std::size_t>(at-matches_.begin());else if(!matches_.empty())active_=std::min(previous.active_,matches_.size()-1);}
    const TranscriptFindMatch* move(bool backwards){if(!matches_.empty())active_=backwards?(active_?active_-1:matches_.size()-1):(active_+1)%matches_.size();return current();}
private:
    std::string query_;std::vector<TranscriptFindMatch> matches_;std::size_t active_{};bool limited_{};
};
} // namespace coincide
