#pragma once
#include "Workspace.h"

namespace coincide {
struct FileMentionTrigger {
    std::size_t start{},length{},caret{};
    std::u16string query;
    bool operator==(const FileMentionTrigger&)const=default;
};
struct FileMentionEdit {std::u16string text;std::size_t caret{};};
struct ComposerFileMention {
    static constexpr std::size_t maximum_draft_units=4*1024*1024,maximum_query_units=1024,maximum_path_bytes=4096;
    static bool boundary(std::u16string_view text,std::size_t at){return at<=text.size()&&!(at&&at<text.size()&&text[at-1]>=0xd800&&text[at-1]<=0xdbff&&text[at]>=0xdc00&&text[at]<=0xdfff);}
    static std::optional<FileMentionTrigger> detect(std::u16string_view text,std::size_t caret,std::size_t selected=0){
        if(text.size()>maximum_draft_units||selected||!boundary(text,caret))return{};
        auto start=caret;while(start&&!workspace_text::whitespace(text[start-1]))--start;
        if(start==caret||text[start]!=u'@'||caret-start-1>maximum_query_units)return{};
        auto end=caret;while(end<text.size()&&!workspace_text::whitespace(text[end]))++end;
        if(end-start>maximum_query_units+1)return{};
        const auto query=text.substr(start+1,caret-start-1);
        if(std::any_of(query.begin(),query.end(),[](char16_t ch){return ch==u'"'||ch<32||ch==127;}))return{};
        return FileMentionTrigger{start,end-start,caret,std::u16string(query)};
    }
    static bool relative(std::string_view path){
        if(path.empty()||path.size()>maximum_path_bytes||path.front()=='/'||path.front()=='\\'||path.find_first_of("\0:\\\"<>|?*",0,9)!=std::string_view::npos)return false;
        try{for(std::size_t at=0;at<path.size();){const auto value=workspace_text::next(path,at);if(value<32||value==127)return false;}}catch(...){return false;}
        std::size_t first{};for(;;){const auto at=path.find('/',first);const auto part=path.substr(first,at==std::string_view::npos?path.size()-first:at-first);if(part.empty()||part=="."||part==".."||part.back()=='.'||part.back()==' ')return false;if(at==std::string_view::npos)break;first=at+1;}return true;
    }
    static FileMentionEdit insert(std::u16string_view current,const FileMentionTrigger& reviewed,std::u16string_view relative_path){
        const auto now=detect(current,reviewed.caret);if(!now||*now!=reviewed||relative_path.empty()||relative_path.size()>maximum_path_bytes)throw std::invalid_argument("The file mention changed before insertion");
        std::string path;for(std::size_t i=0;i<relative_path.size();++i){char32_t code=relative_path[i];if(code>=0xd800&&code<=0xdbff){if(i+1==relative_path.size()||relative_path[i+1]<0xdc00||relative_path[i+1]>0xdfff)throw std::invalid_argument("The file mention path has invalid Unicode");code=0x10000+((code-0xd800)<<10)+(relative_path[++i]-0xdc00);}else if(code>=0xdc00&&code<=0xdfff)throw std::invalid_argument("The file mention path has invalid Unicode");workspace_text::append(path,code);}
        if(!relative(path))throw std::invalid_argument("The file mention must name a relative project file");
        bool quote{};for(const auto ch:relative_path){if(ch==u'"'||ch<32||ch==127)throw std::invalid_argument("The file mention path cannot be quoted safely");quote=quote||workspace_text::whitespace(ch);}
        std::u16string mention=u"@";if(quote)mention+=u'"';mention+=relative_path;if(quote)mention+=u'"';
        const auto end=reviewed.start+reviewed.length;
        if(end==current.size()||!workspace_text::whitespace(current[end]))mention+=u' ';
        if(mention.size()>maximum_draft_units-(current.size()-reviewed.length))throw std::invalid_argument("The draft has no room for this file mention");
        FileMentionEdit result{std::u16string(current.substr(0,reviewed.start)),reviewed.start+mention.size()};result.text+=mention;result.text+=current.substr(end);return result;
    }
    static std::vector<std::string> match(std::vector<std::string> paths,std::string_view query,std::size_t limit=30){
        if(paths.size()>5000||query.size()>maximum_query_units*4||query.find('\0')!=std::string_view::npos||limit>100)throw std::invalid_argument("The file mention query is invalid");
        std::string normalized(query);std::replace(normalized.begin(),normalized.end(),'\\','/');const auto folded=workspace_text::fold(normalized);struct Match{std::string path,folded;unsigned rank;};std::vector<Match> matches;
        std::size_t bytes{};for(auto& path:paths){if(path.size()>2*1024*1024-bytes)throw std::invalid_argument("The file mention index is too large");bytes+=path.size();if(!relative(path))continue;const auto full=workspace_text::fold(path);const auto base=full.substr(full.find_last_of('/')==std::string::npos?0:full.find_last_of('/')+1);unsigned rank{};
            if(folded.empty())rank=4;else if(base==folded)rank=0;else if(base.starts_with(folded))rank=1;else if(full.starts_with(folded))rank=2;else if(full.find(folded)!=std::string::npos)rank=3;else continue;
            matches.push_back({std::move(path),full,rank});}
        std::sort(matches.begin(),matches.end(),[](const auto& a,const auto& b){if(a.rank!=b.rank)return a.rank<b.rank;if(a.folded.size()!=b.folded.size())return a.folded.size()<b.folded.size();return a.folded==b.folded?a.path<b.path:a.folded<b.folded;});
        std::vector<std::string> result;for(auto& hit:matches){if(result.size()==limit)break;if(std::find(result.begin(),result.end(),hit.path)==result.end())result.push_back(std::move(hit.path));}return result;
    }
};
} // namespace coincide
