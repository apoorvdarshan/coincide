#include "../Core/Markdown.h"
#include <iostream>
#include <stdexcept>

int main() {
    using namespace coincide::markdown;
    int checks{};
    auto check = [&](bool valid, const char* failure) {++checks; if (!valid) throw std::runtime_error(failure);};
    try {
        const auto formatted = parse("# नमस्ते\n\n**bold** and `a_b` with [site](https://example.com)\n\n```cpp\n[not a link](javascript:bad)\n你好\n```\n\n- first\n2. second\n> quote\n---");
        check(formatted.size() == 7, "Markdown blocks must retain their separate semantic roles");
        check(formatted[0].kind == Block::heading && formatted[0].spans[0].text == "नमस्ते", "Unicode headings must survive parsing");
        check(formatted[1].spans[0].style == bold, "Strong formatting must be represented without parsing HTML");
        check(formatted[1].spans[2].style == code && formatted[1].spans[2].text == "a_b", "Inline code must preserve literal markup");
        check(formatted[1].spans.back().link == "https://example.com", "Safe links must retain their target");
        check(formatted[2].kind == Block::fenced_code && formatted[2].language == "cpp" && formatted[2].text.find("你好") != std::string::npos, "Code fences must preserve language and Unicode source");
        check(formatted[3].kind == Block::bullet && formatted[4].marker == "2. ", "Ordered and unordered list markers must be retained");
        check(formatted[5].kind == Block::quote && formatted[6].kind == Block::rule, "Quotes and rules need distinct native rendering");
        for (const auto url : {"javascript:alert(1)", "file:///secret", "data:text/html,bad", "https://example.com\nsecret", " https://example.com"}) check(!safe_link(url), "Unsafe or ambiguous schemes must not become clickable links");
        check(safe_link("HTTPS://example.com") && safe_link("mailto:hello@example.com"), "HTTP and mail links are case insensitive");
        const auto literal = inline_text("[bad](javascript:bad) <script> foo_bar \\*literal\\*");
        std::string plain; for (const auto& span : literal) {plain += span.text; check(span.link.empty(), "Raw HTML and unsafe links must remain inert text");}
        check(plain == "[bad](javascript:bad) <script> foo_bar *literal*", "Escaping must preserve literal untrusted content");
        const auto tables = parse("| Left | Right |\n| :--- | ---: |\n| 你好 | a\\|b |\n\nafter");
        check(tables.size() == 2 && tables[0].kind == Block::table && tables[0].rows.size() == 2, "A table must not consume the following paragraph");
        check(tables[0].rows[1][1] == "a|b", "Escaped table pipes must remain inside their cell");
        const auto unfinished = parse("````text\n```\nkeep this\n");
        check(unfinished.size() == 1 && unfinished[0].text == "```\nkeep this", "A shorter fence must not close a longer code fence");
        const auto blanks=parse("```\n\nfirst\n\nlast\n```");
        check(blanks[0].text=="\nfirst\n\nlast","Code copy must preserve leading and interior blank lines");
        const auto huge = inline_text(std::string(70000, '['));
        check(huge.size() == 1 && huge[0].text.size() == 70000, "Pathological inline text must remain bounded and intact");
        const auto image = parse("![diagram](https://example.com/a.png)");
        check(image.size() == 1 && image[0].kind == Block::image && image[0].marker == "https://example.com/a.png", "Images must be explicit links without automatic remote retrieval");
        std::cout << checks << " Markdown checks passed\n"; return 0;
    } catch (const std::exception& error) {std::cerr << "FAIL: " << error.what() << '\n'; return 1;}
}
