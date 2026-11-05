#include "../Core/ComposerFileMention.h"
#include <iostream>

namespace {unsigned checks{};void check(bool value,const char* why){++checks;if(!value)throw std::runtime_error(why);}template<class F>void rejects(F action,const char* why){bool rejected{};try{action();}catch(const std::exception&){rejected=true;}check(rejected,why);}}
int main(){using namespace coincide;using M=ComposerFileMention;try{
    auto found=M::detect(u"Please @src/main",16);check(found&&found->start==7&&found->query==u"src/main"&&found->length==9,"An @ token must bind its exact current UTF-16 range");
    check(!M::detect(u"mail@example.com",16)&&!M::detect(u"ordinary text",13),"Emails and ordinary text must not become file mentions");
    check(M::detect(u"@",1)&&M::detect(u"你好\u3000@src",7),"An empty query and Unicode whitespace must start a file token");
    check(!M::detect(u"@path",5,2)&&!M::detect(u"@path",50),"A selected range or invalid caret must not replace arbitrary text");
    check(!M::detect(u"😀 @x",1)&&M::detect(u"😀 @x",5),"UTF-16 carets must not split a surrogate pair");
    check(!M::detect(u"@\"quoted",8)&&!M::detect(std::u16string(1026,u'@'),1026),"Malformed or oversized mention tokens must be ignored");
    const auto middle=M::detect(u"Before @oldname after",11);check(middle&&middle->query==u"old"&&middle->length==8,"Completing in the middle of a token must replace only that whole token");
    auto edit=M::insert(u"Before @oldname after",*middle,u"src/main.cpp");check(edit.text==u"Before @src/main.cpp after"&&edit.caret==20,"An insertion must preserve unrelated prefix and suffix exactly");
    edit=M::insert(u"Look @app",*M::detect(u"Look @app",9),u"App File.swift");check(edit.text==u"Look @\"App File.swift\" "&&edit.caret==edit.text.size(),"Spaces must be quoted and an end-of-message completion must leave a typing separator");
    edit=M::insert(u"@文",*M::detect(u"@文",2),u"src/你好.txt");check(edit.text==u"@src/你好.txt ","Unicode project paths must retain their original spelling");
    rejects([&]{M::insert(u"Before @changed after",*middle,u"safe.cpp");},"Changed source text must reject a reviewed trigger");
    for(const auto path:{u"../outside",u"/absolute",u"C:/file",u"a\\b",u"a/./b",u"a//b",u"a/../b",u"bad\"quote",u"bad\nline"})rejects([&]{M::insert(u"@x",*M::detect(u"@x",2),path);},"A mention must never introduce an absolute, traversing or unquotable path");
    rejects([&]{M::insert(u"@x",*M::detect(u"@x",2),std::u16string(1,0xd800));},"Invalid UTF-16 file names must not be inserted");
    check(!M::relative("file:stream")&&!M::relative(std::string("a\0b",3))&&!M::relative("\xc0\xaf")&&!M::relative("folder./file"),"File identities must reject streams, NUL, invalid UTF-8 and ambiguous Windows components");
    const std::vector<std::string> paths{"src/main.cpp","other/src/main.cpp","Main.cpp","App File.swift","src/Straße.swift","../outside"};
    auto matches=M::match(paths,"main.cpp");check(matches.size()==3&&matches[0]=="Main.cpp"&&matches[1]=="src/main.cpp","Exact base names must rank before longer matching project paths");
    check(M::match(paths,"SRC\\MAIN")==M::match(paths,"src/main"),"Windows path separators and case must match the same literal relative file");
    check(M::match(paths,"STRASSE")==std::vector<std::string>{"src/Straße.swift"},"File suggestions must use invariant Unicode case folding");
    matches=M::match(paths,"");check(matches.size()==5&&std::find(matches.begin(),matches.end(),"../outside")==matches.end(),"Index entries outside the project must never become suggestions");
    check(M::match(paths,"absent").empty()&&M::match(paths,"",1).size()==1,"Missing queries and result limits must not invent fallback files");
    check(M::match({"x.cpp","x.cpp"},"").size()==1,"Duplicate paths must not become duplicate suggestion rows");
    rejects([&]{M::match(paths,std::string("a\0b",3));},"NUL queries must fail before matching");
    rejects([&]{M::match(std::vector<std::string>(5001,"x"),"");},"Metadata index entry counts must have a finite bound");
    rejects([&]{M::match(std::vector<std::string>(600,std::string(4096,'x')),"");},"Aggregate path metadata must remain bounded");
    std::cout<<"PASS: "<<checks<<" composer file mention checks\n";return 0;
}catch(const std::exception& error){std::cerr<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';return 1;}}
