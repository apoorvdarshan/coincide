#pragma once
#include <algorithm>
#include <cctype>
#include <string>
#include <string_view>
#include <vector>

namespace coincide::markdown {
enum Style : unsigned { normal = 0, bold = 1, italic = 2, code = 4, strike = 8 };
struct Span { std::string text; unsigned style{}; std::string link; };
struct Block {
    enum Kind { paragraph, heading, fenced_code, bullet, quote, rule, table, image } kind{paragraph};
    std::vector<Span> spans;
    std::string text, language, marker;
    unsigned level{};
    std::vector<std::vector<std::string>> rows;
};
inline std::string_view trim(std::string_view value) {
    while (!value.empty() && (value.front() == ' ' || value.front() == '\t' || value.front() == '\r')) value.remove_prefix(1);
    while (!value.empty() && (value.back() == ' ' || value.back() == '\t' || value.back() == '\r')) value.remove_suffix(1);
    return value;
}
inline bool safe_link(std::string_view value) {
    if (value.empty() || value.size() > 8192 || std::any_of(value.begin(), value.end(), [](unsigned char c) {return c <= 32 || c == 127;})) return false;
    std::string scheme(value.substr(0, std::min<std::size_t>(value.size(), 8)));
    std::transform(scheme.begin(), scheme.end(), scheme.begin(), [](unsigned char c) {return static_cast<char>(std::tolower(c));});
    return scheme.starts_with("https://") || scheme.starts_with("http://") || scheme.starts_with("mailto:");
}
inline void append(std::vector<Span>& spans, std::string text, unsigned style, std::string link = {}) {
    if (text.empty()) return;
    if (!spans.empty() && spans.back().style == style && spans.back().link == link) spans.back().text += text;
    else spans.push_back({std::move(text), style, std::move(link)});
}
inline std::vector<Span> inline_text(std::string_view source, unsigned style = 0, unsigned depth = 0) {
    std::vector<Span> result;
    if (depth >= 8 || source.size() > 65536) {append(result, std::string(source), style); return result;}
    std::string plain;
    auto flush = [&] {append(result, std::move(plain), style); plain.clear();};
    bool no_more_links{};
    for (std::size_t i = 0; i < source.size();) {
        const auto c = source[i];
        if (c == '\\' && i + 1 < source.size() && std::ispunct(static_cast<unsigned char>(source[i + 1]))) {plain += source[i + 1]; i += 2; continue;}
        if (c == '`') {
            std::size_t width = 1; while (i + width < source.size() && source[i + width] == '`') ++width;
            const auto end = source.find(std::string(width, '`'), i + width);
            if (end != std::string_view::npos) {flush(); append(result, std::string(source.substr(i + width, end - i - width)), style | code); i = end + width; continue;}
            plain.append(source.substr(i, width)); i += width; continue;
        }
        if (c == '[' && !no_more_links) {
            const auto close = source.find("](", i + 1);
            if (close == std::string_view::npos) no_more_links = true;
            else {
                const auto end = source.find(')', close + 2);
                if (end != std::string_view::npos) {
                    auto url = trim(source.substr(close + 2, end - close - 2));
                    if (safe_link(url)) {
                        flush();
                        auto label = inline_text(source.substr(i + 1, close - i - 1), style, depth + 1);
                        for (auto& span : label) append(result, std::move(span.text), span.style, std::string(url));
                        i = end + 1; continue;
                    }
                }
            }
        }
        if (c == '*' || c == '_' || c == '~') {
            const auto width = i + 1 < source.size() && source[i + 1] == c ? std::size_t{2} : std::size_t{1};
            // Underscores inside identifiers are literal, and a single tilde is not strikethrough.
            if ((c != '_' || i == 0 || !std::isalnum(static_cast<unsigned char>(source[i - 1]))) && (c != '~' || width == 2)) {
                const auto end = source.find(std::string(width, c), i + width);
                if (end != std::string_view::npos && end > i + width) {
                    flush();
                    const auto flag = c == '~' ? strike : (width == 2 ? bold : italic);
                    auto nested = inline_text(source.substr(i + width, end - i - width), style | flag, depth + 1);
                    for (auto& span : nested) append(result, std::move(span.text), span.style, std::move(span.link));
                    i = end + width; continue;
                }
            }
        }
        plain += c; ++i;
    }
    flush(); return result;
}
inline std::vector<std::string> cells(std::string_view line) {
    line = trim(line);
    if (line.starts_with('|')) line.remove_prefix(1);
    if (line.ends_with('|')) line.remove_suffix(1);
    std::vector<std::string> result; std::string cell; bool escaped{}, in_code{};
    for (const auto c : line) {
        if (escaped) {cell += c; escaped = false; continue;}
        if (c == '\\') {escaped = true; continue;}
        if (c == '`') in_code = !in_code;
        if (c == '|' && !in_code) {result.emplace_back(trim(cell)); cell.clear();} else cell += c;
    }
    if (escaped) cell += '\\';
    result.emplace_back(trim(cell)); return result;
}
inline bool table_separator(std::string_view line, std::size_t columns) {
    const auto parts = cells(line);
    if (parts.size() != columns || columns < 2 || columns > 12) return false;
    for (const auto& part : parts) {
        const auto text = trim(part); unsigned dashes{};
        for (const auto c : text) {if (c == '-') ++dashes; else if (c != ':' && c != ' ') return false;}
        if (dashes < 3) return false;
    }
    return true;
}
inline std::vector<Block> parse(std::string_view source) {
    std::vector<Block> result;
    if (source.size() > 2 * 1024 * 1024) {Block b; b.spans.push_back({std::string(source), 0, {}}); result.push_back(std::move(b)); return result;}
    std::vector<std::string_view> lines;
    for (std::size_t at = 0; at < source.size();) {
        const auto end = source.find('\n', at);
        lines.push_back(source.substr(at, end == std::string_view::npos ? source.size() - at : end - at));
        if (end == std::string_view::npos) break;
        at = end + 1;
    }
    auto paragraph_text = std::string{};
    auto flush = [&] {if (!paragraph_text.empty()) {Block b; b.spans = inline_text(paragraph_text); result.push_back(std::move(b)); paragraph_text.clear();}};
    for (std::size_t i = 0; i < lines.size(); ++i) {
        const auto line = trim(lines[i]);
        if (line.empty()) {flush(); continue;}
        if (line.starts_with("```") || line.starts_with("~~~")) {
            flush(); Block b; b.kind = Block::fenced_code;
            const auto fence_char = line.front(); std::size_t width{};
            while (width < line.size() && line[width] == fence_char) ++width;
            b.language = std::string(trim(line.substr(width)));
            bool first_line = true;
            for (++i; i < lines.size(); ++i) {
                const auto candidate = trim(lines[i]);
                std::size_t count{}; while (count < candidate.size() && candidate[count] == fence_char) ++count;
                if (count >= width && trim(candidate.substr(count)).empty()) break;
                if (!first_line) b.text += '\n';
                b.text += lines[i];
                first_line = false;
            }
            result.push_back(std::move(b)); continue;
        }
        if (i + 1 < lines.size() && line.find('|') != std::string_view::npos) {
            const auto header = cells(line);
            if (table_separator(lines[i + 1], header.size())) {
                flush(); Block b; b.kind = Block::table; b.rows.push_back(header); ++i;
                while (i + 1 < lines.size() && !trim(lines[i + 1]).empty() && lines[i + 1].find('|') != std::string_view::npos && b.rows.size() < 501) {
                    auto row = cells(lines[++i]); row.resize(header.size()); b.rows.push_back(std::move(row));
                }
                result.push_back(std::move(b)); continue;
            }
        }
        std::size_t hashes{}; while (hashes < line.size() && line[hashes] == '#') ++hashes;
        if (hashes > 0 && hashes <= 6 && hashes < line.size() && line[hashes] == ' ') {
            flush(); Block b; b.kind = Block::heading; b.level = static_cast<unsigned>(hashes);
            b.spans = inline_text(trim(line.substr(hashes + 1))); result.push_back(std::move(b)); continue;
        }
        if (line.starts_with('>')) {flush(); Block b; b.kind = Block::quote; b.spans = inline_text(trim(line.substr(1))); result.push_back(std::move(b)); continue;}
        const auto rule_char = line.front(); unsigned rule_count{}; bool is_rule = rule_char == '-' || rule_char == '*' || rule_char == '_';
        for (const auto c : line) {if (c == rule_char) ++rule_count; else if (c != ' ') is_rule = false;}
        if (is_rule && rule_count >= 3) {flush(); Block b; b.kind = Block::rule; result.push_back(std::move(b)); continue;}
        std::size_t marker{};
        if (line.size() > 2 && (line.front() == '-' || line.front() == '*' || line.front() == '+') && line[1] == ' ') marker = 2;
        else {
            while (marker < line.size() && std::isdigit(static_cast<unsigned char>(line[marker]))) ++marker;
            if (!marker || marker + 1 >= line.size() || (line[marker] != '.' && line[marker] != ')') || line[marker + 1] != ' ') marker = 0;
            else marker += 2;
        }
        if (marker) {
            flush(); Block b; b.kind = Block::bullet; b.marker = std::string(line.substr(0, marker));
            b.spans = inline_text(line.substr(marker)); result.push_back(std::move(b)); continue;
        }
        if (line.starts_with("![")) {
            const auto close = line.find("]("); const auto end = line.rfind(')');
            if (close != std::string_view::npos && end == line.size() - 1 && end > close + 2 && safe_link(line.substr(close + 2, end - close - 2))) {
                flush(); Block b; b.kind = Block::image; b.text = std::string(line.substr(2, close - 2)); b.marker = std::string(line.substr(close + 2, end - close - 2)); result.push_back(std::move(b)); continue;
            }
        }
        if (!paragraph_text.empty()) paragraph_text += '\n';
        paragraph_text += lines[i];
    }
    flush(); return result;
}
} // namespace coincide::markdown
