#include "../Core/TranscriptFind.h"
#include <iostream>

namespace {unsigned checks{};void check(bool value,const char* why){++checks;if(!value)throw std::runtime_error(why);}template<class F>void rejects(F action,const char* why){bool rejected{};try{action();}catch(...){rejected=true;}check(rejected,why);}}
int main(){using coincide::TranscriptFind;using coincide::TranscriptFindDocument;try{
    std::vector<coincide::Message> messages{{"one","user","Alpha alpha","codex"},{"two","assistant","Straße CAFÉ Привет Σίσυφος 🙂","claude"},{"three","tool","```\nhidden **needle** code\n```","codex"}};
    const auto original=messages;const auto docs=TranscriptFind::snapshot(messages);auto found=TranscriptFind::search(docs,"ALPHA");
    check(found.matches().size()==1&&found.current()->message_id=="one"&&found.current()->matched=="Alpha","Find must return one visible navigation target per matching saved message");
    check(found.current()->offset==0&&found.current()->length==5,"Matches must retain exact original source offsets");
    check(found.move(true)->message_id=="one"&&found.move(false)->message_id=="one","Single-result navigation must wrap safely");
    for(const auto& query:{"STRASSE","café","ПРИВЕТ","ΣΊΣΥΦΟΣ","🙂"}){const auto value=TranscriptFind::search(docs,query);check(value.matches().size()==1&&value.current()->message_id=="two","Unicode literals must search independently of provider and locale");}
    check(TranscriptFind::search(docs,"STRASSE").current()->matched=="Straße","Case-fold expansions must reveal the saved spelling rather than folded text");
    check(TranscriptFind::search({{"emoji","🙂Straße🙂"}},"strasse").current()->offset==4,"Source offsets must count original UTF-8 bytes across supplementary characters");
    const auto markup=TranscriptFind::search(docs,"**needle**");check(markup.current()&&markup.current()->matched=="**needle**","Find is a literal saved-text search, including markup source");
    check(TranscriptFind::search(docs,"codex").matches().empty(),"Provider labels must not become hidden results");
    check(TranscriptFind::search(docs,"").matches().empty()&&TranscriptFind::search(docs,"absent").current()==nullptr,"Empty and unmatched queries must have no selection");
    check(TranscriptFind::search({{"a","first"},{"b","second"}},"first\nsecond").matches().empty(),"Search must never bridge distinct saved messages");
    auto multiple=TranscriptFind::search({{"a","needle"},{"b","needle"},{"c","needle"}},"needle");
    check(multiple.move(false)->message_id=="b"&&multiple.move(false)->message_id=="c"&&multiple.move(false)->message_id=="a","Next must follow saved order and wrap");
    check(multiple.move(true)->message_id=="c","Previous must wrap to the last result");
    auto updated=TranscriptFind::search({{"a","needle edited"},{"c","needle streamed"},{"d","needle new"}},"needle");updated.preserve_selection(multiple);check(updated.current()->message_id=="c","A stream refresh must preserve the selected stable message ID");
    auto removed=TranscriptFind::search({{"a","needle"},{"d","needle"}},"needle");removed.preserve_selection(updated);check(removed.current()->message_id=="d","A vanished match must choose an existing bounded neighbor");
    auto changed=TranscriptFind::search({{"a","other"},{"d","other"}},"other");changed.preserve_selection(removed);check(changed.position()==0,"A new query must start with its first result");
    const auto excerpt=TranscriptFind::search({{"long",std::string(600,'a')+"猫needle🙂"+std::string(600,'b')}},"needle");check(excerpt.current()->leading&&excerpt.current()->trailing&&excerpt.current()->before.size()<300&&excerpt.current()->after.size()<400,"Long source excerpts must remain bounded on Unicode boundaries");
    check(coincide::workspace_text::fold(excerpt.current()->before).ends_with("猫")&&excerpt.current()->after.starts_with("🙂"),"The visible excerpt must preserve adjacent complete UTF-8 characters");
    check(TranscriptFind::search({{"overlap","ababababaca"}},"ababaca").current()->offset==4,"KMP fallback must find repeated-prefix literals without skipping an occurrence");
    check(TranscriptFind::search({{"fold","ß"}},"s").matches().size()==1,"A fold expansion must still create only one navigation result for a message");
    const auto long_tail=TranscriptFind::search({{"long-tail",std::string(1024*1024,'a')+"needle"}},"needle");check(long_tail.current()&&long_tail.current()->offset==1024*1024,"A long no-hit prefix must not silently truncate saved-text search");
    std::vector<TranscriptFindDocument> capped;for(std::size_t i=0;i<TranscriptFind::maximum_results+1;++i)capped.push_back({std::to_string(i),"x"});const auto limit=TranscriptFind::search(capped,"x");check(limit.limited()&&limit.matches().size()==TranscriptFind::maximum_results,"Result truncation must be explicit and bounded");
    rejects([&]{(void)TranscriptFind::search(docs,std::string(1025,'a'));},"Oversized search terms must fail explicitly");
    rejects([&]{(void)TranscriptFind::search(docs,std::string("a\0b",3));},"Embedded-NUL queries must fail rather than silently truncate");
    rejects([&]{(void)TranscriptFind::search(docs,"\xc0\xaf");},"Invalid UTF-8 search terms must fail explicitly");
    rejects([&]{(void)TranscriptFind::search({{"bad","\xed\xa0\x80"}},"needle");},"Malformed saved text must never create a misleading hit");
    unsigned cancellation_checks{};bool cancelled{};try{(void)TranscriptFind::search({{"large",std::string(4*1024*1024,'a')}},"absent",[&]{return ++cancellation_checks>2;});}catch(const TranscriptFind::Cancelled&){cancelled=true;}check(cancelled&&cancellation_checks==3,"Superseded long scans must observe bounded cancellation checkpoints");
    std::string nonascii;for(unsigned i=0;i<100000;++i)nonascii+="a猫🙂";cancellation_checks=0;cancelled=false;try{(void)TranscriptFind::search({{"large-unicode",nonascii}},"absent",[&]{return ++cancellation_checks>2;});}catch(const TranscriptFind::Cancelled&){cancelled=true;}check(cancelled,"Variable-width UTF-8 must not skip cancellation checkpoints");
    check(messages.size()==original.size()&&messages[0].text==original[0].text&&messages[2].text==original[2].text,"Snapshot/search/navigation must leave saved messages untouched");
    std::cout<<"PASS: "<<checks<<" current-thread saved-text find checks\n";return 0;
}catch(const std::exception& error){std::cerr<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';return 1;}}
