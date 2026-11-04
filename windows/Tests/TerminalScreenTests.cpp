#include "../Core/TerminalScreen.h"
#include <iostream>
#include <functional>

namespace {
int checks{};
void check(bool condition,const char* failure){++checks;if(!condition)throw std::runtime_error(failure);}
template<class Operation>void rejects(Operation operation,const char* failure){bool rejected{};try{operation();}catch(...){rejected=true;}check(rejected,failure);}
std::string line(const coincide::TerminalScreen& screen,std::size_t row){return coincide::TerminalScreen::line_text(screen.lines().at(row));}
}

int main(){
    using coincide::TerminalScreen;
    using Color=coincide::TerminalColor;
    try{
        TerminalScreen screen(12,3);
        screen.consume("hello\rXY");
        check(line(screen,0)=="XYllo       ","carriage return must edit the current line rather than append a log entry");
        screen.consume("\x1b[2Kready");
        check(line(screen,0)=="  ready     ","erase-line must preserve the cursor position");
        screen.consume("\x1b[1G\x1b[3C!");
        check(screen.cursor().column==4&&line(screen,0).at(3)=='!',"absolute and relative cursor motion must address cells");
        screen.consume("\x1b[2;5Hhere\x1b[1D?");
        check(line(screen,1).substr(4,4)=="her?","cursor-addressed writes must replace existing cells");
        screen.consume("\x1b[2J\x1b[H012345\x1b[3G\x1b[2P");
        check(line(screen,0)=="0145        ","delete characters must shift the remainder left");
        screen.consume("\x1b[2@ab");
        check(line(screen,0)=="01ab45      ","insert characters must shift the remainder right");
        screen.consume("\x1b[2X");
        check(line(screen,0)=="01ab        ","erase characters must clear cells without shifting");
        screen.consume("\x1b[1K");
        check(line(screen,0)==std::string(12,' '),"erase to the beginning must include the cursor cell");

        TerminalScreen wrap(3,2,2);wrap.consume("abc");
        check(wrap.cursor().column==2&&wrap.cursor().row==0,"printing at the right margin must defer wrapping");
        wrap.consume("\x1b[31md");
        check(line(wrap,0)=="abc"&&line(wrap,1)=="d  ","style changes must not lose pending autowrap");
        wrap.consume("\r\ne\r\nf\r\ng");
        check(wrap.scrollback().size()==2&&TerminalScreen::line_text(wrap.scrollback().back())=="e  ","scrollback must retain only its bounded newest rows");
        check(line(wrap,0)=="f  "&&line(wrap,1)=="g  ","scrolling must retain the current screen's latest rows");
        wrap.consume("\x1b[3J");check(wrap.scrollback().empty(),"erase-saved-lines must clear only scrollback");
        wrap.consume("\x1b[2J");check(line(wrap,1)=="   "&&wrap.cursor().row==1,"erase-display must not reposition the cursor");

        const std::string unicode="A你好e\xcc\x81🙂";
        for(std::size_t split=0;split<=unicode.size();++split){
            TerminalScreen value(20,2);value.consume(std::string_view(unicode).substr(0,split));value.consume(std::string_view(unicode).substr(split));
            check(value.lines()[0][1].text=="你"&&value.lines()[0][1].width==2&&value.lines()[0][2].continuation
                    &&value.lines()[0][5].text=="e\xcc\x81"&&value.lines()[0][6].text=="🙂"&&value.cursor().column==8,
                "UTF-8 fragments, wide characters, and combining marks must preserve terminal cell positions");
        }
        TerminalScreen emoji(12,2);emoji.consume("👩‍💻🇮🇳!");
        check(emoji.lines()[0][0].text=="👩‍💻"&&emoji.lines()[0][2].text=="🇮🇳"&&emoji.lines()[0][4].text=="!",
            "ZWJ emoji and regional-indicator pairs must remain in their original wide cells");
        TerminalScreen wide(4,2);wide.consume("ab你\x1b[4Gx");
        check(wide.lines()[0][2].text==" "&&wide.lines()[0][3].text=="x"&&!wide.lines()[0][3].continuation,
            "overwriting a wide-character continuation must clear the complete old character");
        wide.consume("\x1b[H你\x1b[2G\x1b[P");
        check(!wide.lines()[0][0].continuation&&wide.lines()[0][0].width==1,"deleting through a wide character must repair orphaned cells");

        TerminalScreen color(20,2);color.consume("\x1b[1;3;4;31;44mA\x1b[38;5;196;48;2;1;2;3mB\x1b[0mC");
        const auto& a=color.lines()[0][0].style;const auto& b=color.lines()[0][1].style;const auto& c=color.lines()[0][2].style;
        check(a.bold&&a.italic&&a.underline&&a.foreground.kind==Color::Kind::indexed&&a.foreground.value==1&&a.background.value==4,
            "SGR must retain independent style flags and basic foreground/background colors");
        check(b.foreground.value==196&&b.background.kind==Color::Kind::rgb&&b.background.value==0x010203,"SGR must support indexed and truecolor values");
        check(!c.bold&&c.foreground.kind==Color::Kind::default_color&&c.background.kind==Color::Kind::default_color,"SGR reset must restore the default palette and flags");
        color.consume("\x1b[7;8;9mD\x1b[27;28;29mE");
        check(color.lines()[0][3].style.inverse&&color.lines()[0][3].style.conceal&&color.lines()[0][3].style.strikethrough
                &&!color.lines()[0][4].style.inverse&&!color.lines()[0][4].style.conceal,"independent SGR resets must not retain inverse/conceal state");

        TerminalScreen margins(5,4);margins.consume("11111\r\n22222\r\n33333\r\n44444");
        margins.consume("\x1b[2;3r\x1b[3;1H\n");
        check(line(margins,0)=="11111"&&line(margins,1)=="33333"&&line(margins,2)=="     "&&line(margins,3)=="44444",
            "scroll regions must preserve rows outside their margins");
        check(margins.scrollback().empty(),"partial-region scrolling must not pollute primary scrollback");
        margins.consume("\x1b[?6h\x1b[1;1HX");check(margins.lines()[1][0].text=="X","origin mode must address rows relative to the scroll region");
        margins.consume("\x1b[?6l\x1b[2;1H\x1b[L");
        check(line(margins,1)=="     "&&line(margins,2).front()=='X'&&line(margins,3)=="44444","insert-line must edit only the active scroll region");
        margins.consume("\x1b[M");check(line(margins,1).front()=='X'&&line(margins,2)=="     ","delete-line must shift rows inside the active scroll region");

        TerminalScreen alternate(10,3);alternate.consume("primary\x1b[2;3H\x1b[32m\x1b[?1049hother\r\npage");
        check(alternate.alternate_screen()&&line(alternate,0).starts_with("other")&&alternate.scrollback().empty(),"alternate screen must have a separate grid and no primary scrollback");
        alternate.resize(8,2);alternate.consume("\x1b[?1049l!");
        check(!alternate.alternate_screen()&&line(alternate,0).starts_with("primary")&&alternate.lines()[1][2].text=="!"
                &&alternate.lines()[1][2].style.foreground.value==2,"leaving alternate screen must restore the resized primary cursor and style");
        alternate.consume("\x1b[?25l\x1b[?2004h\x1b[?1h");
        check(!alternate.cursor().visible&&alternate.bracketed_paste()&&alternate.application_cursor_keys(),"cursor and keyboard modes must be exposed to the native host");
        alternate.consume("\x1b[?25h\x1b[?2004l\x1b[?1l");
        check(alternate.cursor().visible&&!alternate.bracketed_paste()&&!alternate.application_cursor_keys(),"private mode resets must restore native keyboard defaults");

        TerminalScreen fragmented(20,2);
        const std::string commands="\x1b[2;4H\x1b[38;2;5;6;7mQ\x1b]2;A terminal 你好\x1b\\";
        for(const auto byte:commands)fragmented.consume(std::string_view(&byte,1));
        check(fragmented.lines()[1][3].text=="Q"&&fragmented.lines()[1][3].style.foreground.value==0x050607,
            "CSI commands must remain correct when every byte arrives separately");
        check(fragmented.title()=="A terminal 你好","OSC title and UTF-8 must remain correct across byte boundaries");
        fragmented.consume("\x1b]52;c;Y2xpcGJvYXJk\a\x1b]8;;https://invalid.test\x1b\\link\x1b]8;;\x1b\\");
        check(fragmented.title()=="A terminal 你好"&&fragmented.unsupported_sequences()>=3,"clipboard and hyperlink OSCs must not change the title or become host actions");
        fragmented.consume("\x1b]2;"+std::string(10000,'x')+"\a");
        check(fragmented.title()=="A terminal 你好","an oversized OSC must be discarded without replacing the valid title");
        fragmented.consume("\x1b["+std::string(10000,'9')+"H!");
        check(fragmented.cursor().column<fragmented.columns()&&fragmented.cursor().row<fragmented.rows(),"an oversized CSI must never escape grid bounds");
        fragmented.consume("\x1bPdiscarded payload\x1b\\Z");
        check(fragmented.unsupported_sequences()>=5,"unsupported DCS strings must be bounded and skipped");

        TerminalScreen editing(20,3);editing.consume("a\tb\b!\x1b[4h\r12\x1b[4l");
        check(line(editing,0).starts_with("12a")&&editing.lines()[0][10].text=="!","tabs, backspace and insert mode must edit a shared cell grid");
        editing.consume("\x1b[3g\r\t");check(editing.cursor().column==19,"clearing tab stops must make tab advance to the right margin");
        editing.consume("\x1b[4G\x1bH\r\t");check(editing.cursor().column==3,"explicit tab stops must be honored");
        editing.consume("\x1b(0qx\x1b(B");check(editing.lines()[0][3].text=="─"&&editing.lines()[0][4].text=="│","DEC graphics characters must render as line drawing");

        TerminalScreen malformed(10,2);malformed.consume(std::string("\xf0\x28\x8c\x28",4));
        check(line(malformed,0).starts_with("�(�("),"invalid UTF-8 must recover without swallowing subsequent printable text");
        malformed.consume(std::string("\xe4\xbd",2));malformed.finish();
        check(malformed.cursor().column==5,"an incomplete final UTF-8 sequence must finish as one replacement cell");
        TerminalScreen bounded(10,2,3);
        for(int row=0;row<1000;++row)bounded.consume("line\r\n");
        check(bounded.scrollback().size()==3&&bounded.lines().size()==2,"long terminal output must remain bounded by scrollback and visible rows");
        bounded.resize(5,1);check(bounded.lines().size()==1&&bounded.lines()[0].size()==5&&bounded.cursor().row==0,"shrinking a terminal must retain a valid visible grid and cursor");
        bounded.resize(20,5);check(bounded.lines().size()==5&&bounded.lines()[0].size()==20,"growing a terminal must initialize new cells and rows");
        rejects([]{TerminalScreen invalid(0,24);},"a zero-sized terminal must be rejected");
        rejects([]{TerminalScreen invalid(1000,500);},"terminal grid allocation must have a total cell bound");
        rejects([]{TerminalScreen invalid(10,2,10001);},"terminal scrollback configuration must be bounded");
        std::cout<<checks<<" terminal screen checks passed\n";return 0;
    }catch(const std::exception& error){std::cerr<<"FAIL: "<<error.what()<<'\n';return 1;}
}
