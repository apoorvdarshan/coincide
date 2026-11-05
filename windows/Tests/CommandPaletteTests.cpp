#include "../Core/CommandPalette.h"
#include <iostream>

namespace {unsigned checks{};void check(bool value,const char* why){++checks;if(!value)throw std::runtime_error(why);}template<class F>void rejects(F action,const char* why){bool rejected{};try{action();}catch(const std::exception&){rejected=true;}check(rejected,why);}}
int main(){using namespace coincide;using K=PaletteKind;try{
    const std::vector<PaletteEntry> entries{{K::command,"new","New Chat","Create a conversation"},{K::project,"project","Straße","Project · C:/owned"},{K::thread,"one","Same title","codex · Straße"},{K::thread,"two","Same title","claude · Other"},{K::command,"disabled","Forbidden","hidden",false}};
    auto found=CommandPalette::search(entries,"");check(found.entries.size()==4&&!found.limited,"An empty palette must expose enabled metadata in stable source order");
    check(found.entries.front().id=="new"&&found.entries.back().id=="two","Empty queries must retain the supplied recency and command order");
    found=CommandPalette::search(entries,"same");check(found.entries.size()==2&&found.entries[0].id=="one"&&found.entries[1].id=="two","Equal titles must retain distinct target IDs");
    check(CommandPalette::search(entries,"STRASSE").entries.size()==2,"Unicode folding must match project names in both projects and conversations");
    found=CommandPalette::search(entries,"strasse codex");check(found.entries.size()==1&&found.entries[0].id=="one","Terms must match across title, project and provider metadata");
    check(CommandPalette::search(entries,"strasse\u3000codex").entries==found.entries,"Unicode whitespace must split terms without requiring a literal byte match");
    check(CommandPalette::search(entries,"forbidden").entries.empty(),"Disabled commands must never become actionable search results");
    check(CommandPalette::search(entries,"unmatched").entries.empty(),"A missing query must have no fallback action");
    const std::vector<PaletteEntry> ranked{{K::thread,"detail","Elsewhere","needle"},{K::thread,"inside","A needle",""},{K::thread,"prefix","Needlework",""},{K::thread,"exact","Needle",""}};
    found=CommandPalette::search(ranked,"needle");check(found.entries[0].id=="exact"&&found.entries[1].id=="prefix"&&found.entries[2].id=="inside"&&found.entries[3].id=="detail","Exact titles must rank before prefixes, substrings and metadata matches");
    auto same_id=entries;same_id.push_back({K::thread,"project","Other target kind",""});check(CommandPalette::search(same_id,"").entries.size()==5,"Project and conversation ID namespaces must stay distinct");
    auto duplicate=entries;duplicate.push_back(entries[0]);rejects([&]{CommandPalette::search(duplicate,"");},"Duplicate target identities must fail closed");
    rejects([&]{CommandPalette::search({},std::string("a\0b",3));},"NUL queries must fail before matching");
    rejects([&]{CommandPalette::search({},"\xc0\xaf");},"Malformed UTF-8 must never become a search term");
    rejects([&]{CommandPalette::search({},std::string(1025,'a'));},"Oversized queries must be rejected");
    for(unsigned field=0;field<3;++field){auto invalid=entries;if(field==0)invalid[0].id="";else if(field==1)invalid[0].title=std::string("a\0b",3);else invalid[0].detail="\xc0\xaf";rejects([&]{CommandPalette::search(invalid,"");},"Invalid metadata must not produce partially trusted targets");}
    auto invalid=entries;invalid[0].kind=static_cast<K>(8);rejects([&]{CommandPalette::search(invalid,"");},"Unknown destination kinds must fail closed");
    std::vector<PaletteEntry> many;for(unsigned i=0;i<105;++i)many.push_back({K::thread,std::to_string(i),"Matching title",""});found=CommandPalette::search(many,"matching");check(found.limited&&found.entries.size()==100&&found.entries.back().id=="99","Result caps must be explicit and retain stable identities");
    rejects([&]{CommandPalette::search(std::vector<PaletteEntry>(CommandPalette::maximum_entries+1),"");},"Metadata entry counts must have a finite bound");
    std::vector<PaletteEntry> large;for(unsigned i=0;i<1030;++i)large.push_back({K::thread,std::to_string(i),"Title",std::string(8192,'x')});rejects([&]{CommandPalette::search(large,"");},"Aggregate metadata must stay bounded");
    bool cancelled{};unsigned calls{};try{CommandPalette::search(entries,"",[&]{return ++calls==2;});}catch(const CommandPalette::Cancelled&){cancelled=true;}check(cancelled&&calls==2,"A superseded search must stop while scanning metadata");
    check(entries[2].id=="one"&&entries[2].title=="Same title"&&entries[0].enabled,"Search must never mutate original metadata or enable commands");
    std::cout<<"PASS: "<<checks<<" command palette metadata checks\n";return 0;
}catch(const std::exception& error){std::cerr<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';return 1;}}
