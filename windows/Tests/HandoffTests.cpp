#include "../Core/Handoff.h"
#include <iostream>
int main(){
    using namespace std::string_view_literals;
    int checks{};auto check=[&](bool value,const char* failure){++checks;if(!value)throw std::runtime_error(failure);};
    try {
        coincide::Thread thread;thread.messages={{"1","user","First question",""},{"2","assistant","Old answer","claude"},{"3","tool","PRIVATE TOOL OUTPUT","claude"},{"4","user","Recent question",""},{"5","assistant","Recent answer","codex"}};
        thread.sessions={{"claude","original-session",2}};
        const auto resumed=coincide::handoff_context(thread,"claude");
        check(resumed.included==2&&resumed.text.find("First question")==std::string::npos,"Resumed providers should receive only missed user/assistant messages");
        check(resumed.text.find("Recent question")<resumed.text.find("Recent answer"),"Handoff context must retain chronological order");
        check(resumed.text.find("PRIVATE TOOL OUTPUT")==std::string::npos,"Raw tool logs should not be copied into provider handoffs");
        check(resumed.text.find("\"provider\":\"codex\"")!=std::string::npos,"Historical provider attribution must remain explicit");
        check(coincide::handoff_context(thread,"opencode").included==4,"A new provider must receive bounded prior conversation context");
        thread.sessions.push_back({"codex","current-session",thread.messages.size()});check(coincide::handoff_context(thread,"codex").text.empty(),"An up-to-date native session must not replay context");
        check(coincide::reference_json_string("\"\\\n\0"sv)=="\"\\\"\\\\\\u000a\\u0000\"","History content must be JSON-escaped, including control bytes");
        thread.messages.back().text=std::string(5000,'x')+"你好";
        const auto bounded=coincide::handoff_context(thread,"opencode",1024);
        check(bounded.text.size()<=1024&&bounded.omitted>0,"Oversized histories need a strict context budget and omission marker");
        check(bounded.text.find("你好")!=std::string::npos,"A truncated latest message must preserve complete UTF-8 and its tail");
        check(coincide::utf8_tail("a你好",4)=="好","Truncation must never begin inside a UTF-8 character");
        std::cout<<checks<<" handoff checks passed\n";return 0;
    }catch(const std::exception& failure){std::cerr<<"FAIL: "<<failure.what()<<'\n';return 1;}
}
