#include "../Core/ConversationSearch.h"
#include <iostream>

namespace {unsigned checks{};void check(bool condition,const char* why){++checks;if(!condition)throw std::runtime_error(why);}template<class F>void rejects(F action,const char* why){bool failed{};try{action();}catch(...){failed=true;}check(failed,why);}}
int main(){using namespace coincide;try{
    std::vector<ConversationSearchThread> threads{{"one","Same title","project"},{"two","Same title",""},{"deleted","Deleted","",true}};
    std::vector<std::string> reads;
    const ConversationSearch::Reader reader=[&](const auto& id,std::size_t& total,const auto&){reads.push_back(id);total+=10;return std::vector<TranscriptFindDocument>{{id+"-a","Straße **needle**"},{id+"-b","needle repeated needle"}};};
    auto result=ConversationSearch::search(threads,"NEEDLE",reader);
    check(result.hits.size()==4&&result.searched==2&&result.unavailable==0,"Search must include every eligible saved message once");
    check(reads==std::vector<std::string>{"one","two"},"Deleted conversations must not be read");
    check(result.hits[0].thread_id=="one"&&result.hits[2].thread_id=="two"&&result.hits[0].title==result.hits[2].title,"Equal titles must retain distinct stable conversation identities");
    check(result.hits[0].message.message_id=="one-a"&&result.hits[0].message.matched=="needle"&&result.bytes==20,"Results must retain source message identity, excerpt and bounded read accounting");
    check(ConversationSearch::search(threads,"STRASSE",reader).hits[0].message.matched=="Straße","Cross-conversation search must retain Unicode folding and source spelling");
    reads.clear();result=ConversationSearch::search(threads,"needle",reader,{},"project");check(result.hits.size()==2&&reads==std::vector<std::string>{"one"},"A project filter must exclude other transcripts before reading");
    reads.clear();result=ConversationSearch::search(threads,"needle",reader,{},std::string{});check(result.hits.size()==2&&reads==std::vector<std::string>{"two"},"Projectless search must remain distinct from all projects");
    reads.clear();check(ConversationSearch::search(threads,"",reader).hits.empty()&&reads.empty(),"An empty query must never scan saved files");
    rejects([&]{ConversationSearch::search({},std::string("a\0b",3),reader);},"NUL queries must be rejected even for an empty workspace");
    rejects([&]{ConversationSearch::search({},std::string(1025,'a'),reader);},"Oversized queries must fail before any read");
    auto duplicate=threads;duplicate.push_back(threads[0]);rejects([&]{ConversationSearch::search(duplicate,"needle",reader);},"Duplicate conversation identities must fail closed");
    rejects([&]{ConversationSearch::search(std::vector<ConversationSearchThread>(ConversationSearch::maximum_threads+1),"needle",reader);},"Metadata snapshots must have a finite bound");
    result=ConversationSearch::search(threads,"needle",[&](const auto& id,std::size_t& total,const auto& cancel){if(id=="one")throw std::runtime_error("unreadable fixture");return reader(id,total,cancel);});
    check(result.hits.size()==2&&result.searched==1&&result.unavailable==1,"An unreadable conversation must be reported without hiding other matches");
    result=ConversationSearch::search(threads,"needle",[](const auto&,std::size_t&,const auto&)->std::vector<TranscriptFindDocument>{return {{"bad","\xc0\xaf"}};});
    check(result.hits.empty()&&result.unavailable==2&&result.searched==0,"Malformed saved text must be excluded and counted honestly");
    result=ConversationSearch::search(threads,"needle",[](const auto&,std::size_t&,const auto&)->std::vector<TranscriptFindDocument>{throw ConversationSearch::ReadLimit{};});
    check(result.limited&&result.hits.empty()&&result.searched==0,"Aggregate read exhaustion must report partial results");
    const std::vector<ConversationSearchThread> single{{"one","One",""}};
    result=ConversationSearch::search(single,"needle",[](const auto&,std::size_t&,const auto&){std::vector<TranscriptFindDocument> documents;for(unsigned i=0;i<1002;++i)documents.push_back({std::to_string(i),"needle"});return documents;});
    check(result.limited&&result.hits.size()==ConversationSearch::maximum_results&&result.hits.back().message.message_id=="999","Search result caps must preserve deterministic stable identities");
    bool cancelled{};try{ConversationSearch::search(threads,"needle",reader,[]{return true;});}catch(const TranscriptFind::Cancelled&){cancelled=true;}check(cancelled,"Cancellation must stop before reading another transcript");
    cancelled=false;unsigned calls{};try{ConversationSearch::search(single,"needle",[](const auto&,std::size_t&,const auto&){return std::vector<TranscriptFindDocument>{{"long",std::string(50000,'x')}};},[&]{return ++calls>3;});}catch(const TranscriptFind::Cancelled&){cancelled=true;}check(cancelled,"Long scans must propagate cancellation rather than partial success");
    auto found=TranscriptFind::search({{"first","needle"},{"last","needle"}},"needle");check(found.select("last")&&found.current()->message_id=="last","Selected search results must target their exact message rather than the first match");check(!found.select("gone")&&found.current()->message_id=="last","A missing selected message must not silently change the active target");
    std::cout<<"PASS: "<<checks<<" cross-conversation search checks\n";return 0;
}catch(const std::exception& error){std::cerr<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';return 1;}}
