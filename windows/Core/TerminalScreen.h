#pragma once
#include <algorithm>
#include <cstdint>
#include <deque>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace coincide {
struct TerminalColor {
    enum class Kind { default_color, indexed, rgb };
    Kind kind{Kind::default_color};
    std::uint32_t value{};
    bool operator==(const TerminalColor&) const = default;
};
struct TerminalStyle {
    TerminalColor foreground, background;
    bool bold{}, dim{}, italic{}, underline{}, inverse{}, conceal{}, strikethrough{};
    bool operator==(const TerminalStyle&) const = default;
};
struct TerminalCell {
    std::string text{" "};
    TerminalStyle style;
    std::uint8_t width{1};
    bool continuation{};
    bool operator==(const TerminalCell&) const = default;
};
using TerminalLine = std::vector<TerminalCell>;
struct TerminalCursor { std::size_t column{}, row{}; bool visible{true}; };

namespace terminal_unicode {
// Unicode 17.0.0 category/east-Asian-width snapshot. No locale or external runtime dependency.
struct Range { char32_t first, last; };
inline constexpr Range zero_width[]{
    {0xad,0xad}, {0x300,0x36f}, {0x483,0x489}, {0x591,0x5bd},
    {0x5bf,0x5bf}, {0x5c1,0x5c2}, {0x5c4,0x5c5}, {0x5c7,0x5c7},
    {0x600,0x605}, {0x610,0x61a}, {0x61c,0x61c}, {0x64b,0x65f},
    {0x670,0x670}, {0x6d6,0x6dd}, {0x6df,0x6e4}, {0x6e7,0x6e8},
    {0x6ea,0x6ed}, {0x70f,0x70f}, {0x711,0x711}, {0x730,0x74a},
    {0x7a6,0x7b0}, {0x7eb,0x7f3}, {0x7fd,0x7fd}, {0x816,0x819},
    {0x81b,0x823}, {0x825,0x827}, {0x829,0x82d}, {0x859,0x85b},
    {0x890,0x891}, {0x897,0x89f}, {0x8ca,0x902}, {0x93a,0x93a},
    {0x93c,0x93c}, {0x941,0x948}, {0x94d,0x94d}, {0x951,0x957},
    {0x962,0x963}, {0x981,0x981}, {0x9bc,0x9bc}, {0x9c1,0x9c4},
    {0x9cd,0x9cd}, {0x9e2,0x9e3}, {0x9fe,0x9fe}, {0xa01,0xa02},
    {0xa3c,0xa3c}, {0xa41,0xa42}, {0xa47,0xa48}, {0xa4b,0xa4d},
    {0xa51,0xa51}, {0xa70,0xa71}, {0xa75,0xa75}, {0xa81,0xa82},
    {0xabc,0xabc}, {0xac1,0xac5}, {0xac7,0xac8}, {0xacd,0xacd},
    {0xae2,0xae3}, {0xafa,0xaff}, {0xb01,0xb01}, {0xb3c,0xb3c},
    {0xb3f,0xb3f}, {0xb41,0xb44}, {0xb4d,0xb4d}, {0xb55,0xb56},
    {0xb62,0xb63}, {0xb82,0xb82}, {0xbc0,0xbc0}, {0xbcd,0xbcd},
    {0xc00,0xc00}, {0xc04,0xc04}, {0xc3c,0xc3c}, {0xc3e,0xc40},
    {0xc46,0xc48}, {0xc4a,0xc4d}, {0xc55,0xc56}, {0xc62,0xc63},
    {0xc81,0xc81}, {0xcbc,0xcbc}, {0xcbf,0xcbf}, {0xcc6,0xcc6},
    {0xccc,0xccd}, {0xce2,0xce3}, {0xd00,0xd01}, {0xd3b,0xd3c},
    {0xd41,0xd44}, {0xd4d,0xd4d}, {0xd62,0xd63}, {0xd81,0xd81},
    {0xdca,0xdca}, {0xdd2,0xdd4}, {0xdd6,0xdd6}, {0xe31,0xe31},
    {0xe34,0xe3a}, {0xe47,0xe4e}, {0xeb1,0xeb1}, {0xeb4,0xebc},
    {0xec8,0xece}, {0xf18,0xf19}, {0xf35,0xf35}, {0xf37,0xf37},
    {0xf39,0xf39}, {0xf71,0xf7e}, {0xf80,0xf84}, {0xf86,0xf87},
    {0xf8d,0xf97}, {0xf99,0xfbc}, {0xfc6,0xfc6}, {0x102d,0x1030},
    {0x1032,0x1037}, {0x1039,0x103a}, {0x103d,0x103e}, {0x1058,0x1059},
    {0x105e,0x1060}, {0x1071,0x1074}, {0x1082,0x1082}, {0x1085,0x1086},
    {0x108d,0x108d}, {0x109d,0x109d}, {0x1160,0x11ff}, {0x135d,0x135f},
    {0x1712,0x1714}, {0x1732,0x1733}, {0x1752,0x1753}, {0x1772,0x1773},
    {0x17b4,0x17b5}, {0x17b7,0x17bd}, {0x17c6,0x17c6}, {0x17c9,0x17d3},
    {0x17dd,0x17dd}, {0x180b,0x180f}, {0x1885,0x1886}, {0x18a9,0x18a9},
    {0x1920,0x1922}, {0x1927,0x1928}, {0x1932,0x1932}, {0x1939,0x193b},
    {0x1a17,0x1a18}, {0x1a1b,0x1a1b}, {0x1a56,0x1a56}, {0x1a58,0x1a5e},
    {0x1a60,0x1a60}, {0x1a62,0x1a62}, {0x1a65,0x1a6c}, {0x1a73,0x1a7c},
    {0x1a7f,0x1a7f}, {0x1ab0,0x1add}, {0x1ae0,0x1aeb}, {0x1b00,0x1b03},
    {0x1b34,0x1b34}, {0x1b36,0x1b3a}, {0x1b3c,0x1b3c}, {0x1b42,0x1b42},
    {0x1b6b,0x1b73}, {0x1b80,0x1b81}, {0x1ba2,0x1ba5}, {0x1ba8,0x1ba9},
    {0x1bab,0x1bad}, {0x1be6,0x1be6}, {0x1be8,0x1be9}, {0x1bed,0x1bed},
    {0x1bef,0x1bf1}, {0x1c2c,0x1c33}, {0x1c36,0x1c37}, {0x1cd0,0x1cd2},
    {0x1cd4,0x1ce0}, {0x1ce2,0x1ce8}, {0x1ced,0x1ced}, {0x1cf4,0x1cf4},
    {0x1cf8,0x1cf9}, {0x1dc0,0x1dff}, {0x200b,0x200f}, {0x202a,0x202e},
    {0x2060,0x2064}, {0x2066,0x206f}, {0x20d0,0x20f0}, {0x2cef,0x2cf1},
    {0x2d7f,0x2d7f}, {0x2de0,0x2dff}, {0x302a,0x302d}, {0x3099,0x309a},
    {0xa66f,0xa672}, {0xa674,0xa67d}, {0xa69e,0xa69f}, {0xa6f0,0xa6f1},
    {0xa802,0xa802}, {0xa806,0xa806}, {0xa80b,0xa80b}, {0xa825,0xa826},
    {0xa82c,0xa82c}, {0xa8c4,0xa8c5}, {0xa8e0,0xa8f1}, {0xa8ff,0xa8ff},
    {0xa926,0xa92d}, {0xa947,0xa951}, {0xa980,0xa982}, {0xa9b3,0xa9b3},
    {0xa9b6,0xa9b9}, {0xa9bc,0xa9bd}, {0xa9e5,0xa9e5}, {0xaa29,0xaa2e},
    {0xaa31,0xaa32}, {0xaa35,0xaa36}, {0xaa43,0xaa43}, {0xaa4c,0xaa4c},
    {0xaa7c,0xaa7c}, {0xaab0,0xaab0}, {0xaab2,0xaab4}, {0xaab7,0xaab8},
    {0xaabe,0xaabf}, {0xaac1,0xaac1}, {0xaaec,0xaaed}, {0xaaf6,0xaaf6},
    {0xabe5,0xabe5}, {0xabe8,0xabe8}, {0xabed,0xabed}, {0xd7b0,0xd7c6},
    {0xd7cb,0xd7fb}, {0xfb1e,0xfb1e}, {0xfe00,0xfe0f}, {0xfe20,0xfe2f},
    {0xfeff,0xfeff}, {0xfff9,0xfffb}, {0x101fd,0x101fd}, {0x102e0,0x102e0},
    {0x10376,0x1037a}, {0x10a01,0x10a03}, {0x10a05,0x10a06}, {0x10a0c,0x10a0f},
    {0x10a38,0x10a3a}, {0x10a3f,0x10a3f}, {0x10ae5,0x10ae6}, {0x10d24,0x10d27},
    {0x10d69,0x10d6d}, {0x10eab,0x10eac}, {0x10efa,0x10eff}, {0x10f46,0x10f50},
    {0x10f82,0x10f85}, {0x11001,0x11001}, {0x11038,0x11046}, {0x11070,0x11070},
    {0x11073,0x11074}, {0x1107f,0x11081}, {0x110b3,0x110b6}, {0x110b9,0x110ba},
    {0x110bd,0x110bd}, {0x110c2,0x110c2}, {0x110cd,0x110cd}, {0x11100,0x11102},
    {0x11127,0x1112b}, {0x1112d,0x11134}, {0x11173,0x11173}, {0x11180,0x11181},
    {0x111b6,0x111be}, {0x111c9,0x111cc}, {0x111cf,0x111cf}, {0x1122f,0x11231},
    {0x11234,0x11234}, {0x11236,0x11237}, {0x1123e,0x1123e}, {0x11241,0x11241},
    {0x112df,0x112df}, {0x112e3,0x112ea}, {0x11300,0x11301}, {0x1133b,0x1133c},
    {0x11340,0x11340}, {0x11366,0x1136c}, {0x11370,0x11374}, {0x113bb,0x113c0},
    {0x113ce,0x113ce}, {0x113d0,0x113d0}, {0x113d2,0x113d2}, {0x113e1,0x113e2},
    {0x11438,0x1143f}, {0x11442,0x11444}, {0x11446,0x11446}, {0x1145e,0x1145e},
    {0x114b3,0x114b8}, {0x114ba,0x114ba}, {0x114bf,0x114c0}, {0x114c2,0x114c3},
    {0x115b2,0x115b5}, {0x115bc,0x115bd}, {0x115bf,0x115c0}, {0x115dc,0x115dd},
    {0x11633,0x1163a}, {0x1163d,0x1163d}, {0x1163f,0x11640}, {0x116ab,0x116ab},
    {0x116ad,0x116ad}, {0x116b0,0x116b5}, {0x116b7,0x116b7}, {0x1171d,0x1171d},
    {0x1171f,0x1171f}, {0x11722,0x11725}, {0x11727,0x1172b}, {0x1182f,0x11837},
    {0x11839,0x1183a}, {0x1193b,0x1193c}, {0x1193e,0x1193e}, {0x11943,0x11943},
    {0x119d4,0x119d7}, {0x119da,0x119db}, {0x119e0,0x119e0}, {0x11a01,0x11a0a},
    {0x11a33,0x11a38}, {0x11a3b,0x11a3e}, {0x11a47,0x11a47}, {0x11a51,0x11a56},
    {0x11a59,0x11a5b}, {0x11a8a,0x11a96}, {0x11a98,0x11a99}, {0x11b60,0x11b60},
    {0x11b62,0x11b64}, {0x11b66,0x11b66}, {0x11c30,0x11c36}, {0x11c38,0x11c3d},
    {0x11c3f,0x11c3f}, {0x11c92,0x11ca7}, {0x11caa,0x11cb0}, {0x11cb2,0x11cb3},
    {0x11cb5,0x11cb6}, {0x11d31,0x11d36}, {0x11d3a,0x11d3a}, {0x11d3c,0x11d3d},
    {0x11d3f,0x11d45}, {0x11d47,0x11d47}, {0x11d90,0x11d91}, {0x11d95,0x11d95},
    {0x11d97,0x11d97}, {0x11ef3,0x11ef4}, {0x11f00,0x11f01}, {0x11f36,0x11f3a},
    {0x11f40,0x11f40}, {0x11f42,0x11f42}, {0x11f5a,0x11f5a}, {0x13430,0x13440},
    {0x13447,0x13455}, {0x1611e,0x16129}, {0x1612d,0x1612f}, {0x16af0,0x16af4},
    {0x16b30,0x16b36}, {0x16f4f,0x16f4f}, {0x16f8f,0x16f92}, {0x16fe4,0x16fe4},
    {0x1bc9d,0x1bc9e}, {0x1bca0,0x1bca3}, {0x1cf00,0x1cf2d}, {0x1cf30,0x1cf46},
    {0x1d167,0x1d169}, {0x1d173,0x1d182}, {0x1d185,0x1d18b}, {0x1d1aa,0x1d1ad},
    {0x1d242,0x1d244}, {0x1da00,0x1da36}, {0x1da3b,0x1da6c}, {0x1da75,0x1da75},
    {0x1da84,0x1da84}, {0x1da9b,0x1da9f}, {0x1daa1,0x1daaf}, {0x1e000,0x1e006},
    {0x1e008,0x1e018}, {0x1e01b,0x1e021}, {0x1e023,0x1e024}, {0x1e026,0x1e02a},
    {0x1e08f,0x1e08f}, {0x1e130,0x1e136}, {0x1e2ae,0x1e2ae}, {0x1e2ec,0x1e2ef},
    {0x1e4ec,0x1e4ef}, {0x1e5ee,0x1e5ef}, {0x1e6e3,0x1e6e3}, {0x1e6e6,0x1e6e6},
    {0x1e6ee,0x1e6ef}, {0x1e6f5,0x1e6f5}, {0x1e8d0,0x1e8d6}, {0x1e944,0x1e94a},
    {0xe0001,0xe0001}, {0xe0020,0xe007f}, {0xe0100,0xe01ef},
};
inline constexpr Range double_width[]{
    {0x1100,0x115f}, {0x231a,0x231b}, {0x2329,0x232a}, {0x23e9,0x23ec},
    {0x23f0,0x23f0}, {0x23f3,0x23f3}, {0x25fd,0x25fe}, {0x2614,0x2615},
    {0x2630,0x2637}, {0x2648,0x2653}, {0x267f,0x267f}, {0x268a,0x268f},
    {0x2693,0x2693}, {0x26a1,0x26a1}, {0x26aa,0x26ab}, {0x26bd,0x26be},
    {0x26c4,0x26c5}, {0x26ce,0x26ce}, {0x26d4,0x26d4}, {0x26ea,0x26ea},
    {0x26f2,0x26f3}, {0x26f5,0x26f5}, {0x26fa,0x26fa}, {0x26fd,0x26fd},
    {0x2705,0x2705}, {0x270a,0x270b}, {0x2728,0x2728}, {0x274c,0x274c},
    {0x274e,0x274e}, {0x2753,0x2755}, {0x2757,0x2757}, {0x2795,0x2797},
    {0x27b0,0x27b0}, {0x27bf,0x27bf}, {0x2b1b,0x2b1c}, {0x2b50,0x2b50},
    {0x2b55,0x2b55}, {0x2e80,0x2e99}, {0x2e9b,0x2ef3}, {0x2f00,0x2fd5},
    {0x2ff0,0x303e}, {0x3041,0x3096}, {0x3099,0x30ff}, {0x3105,0x312f},
    {0x3131,0x318e}, {0x3190,0x31e5}, {0x31ef,0x321e}, {0x3220,0x3247},
    {0x3250,0xa48c}, {0xa490,0xa4c6}, {0xa960,0xa97c}, {0xac00,0xd7a3},
    {0xf900,0xfa6d}, {0xfa70,0xfad9}, {0xfe10,0xfe19}, {0xfe30,0xfe52},
    {0xfe54,0xfe66}, {0xfe68,0xfe6b}, {0xff01,0xff60}, {0xffe0,0xffe6},
    {0x16fe0,0x16fe4}, {0x16ff0,0x16ff6}, {0x17000,0x18cd5}, {0x18cff,0x18d1e},
    {0x18d80,0x18df2}, {0x1aff0,0x1aff3}, {0x1aff5,0x1affb}, {0x1affd,0x1affe},
    {0x1b000,0x1b122}, {0x1b132,0x1b132}, {0x1b150,0x1b152}, {0x1b155,0x1b155},
    {0x1b164,0x1b167}, {0x1b170,0x1b2fb}, {0x1d300,0x1d356}, {0x1d360,0x1d376},
    {0x1f004,0x1f004}, {0x1f0cf,0x1f0cf}, {0x1f18e,0x1f18e}, {0x1f191,0x1f19a},
    {0x1f1e6,0x1f202}, {0x1f210,0x1f23b}, {0x1f240,0x1f248}, {0x1f250,0x1f251},
    {0x1f260,0x1f265}, {0x1f300,0x1f320}, {0x1f32d,0x1f335}, {0x1f337,0x1f37c},
    {0x1f37e,0x1f393}, {0x1f3a0,0x1f3ca}, {0x1f3cf,0x1f3d3}, {0x1f3e0,0x1f3f0},
    {0x1f3f4,0x1f3f4}, {0x1f3f8,0x1f43e}, {0x1f440,0x1f440}, {0x1f442,0x1f4fc},
    {0x1f4ff,0x1f53d}, {0x1f54b,0x1f54e}, {0x1f550,0x1f567}, {0x1f57a,0x1f57a},
    {0x1f595,0x1f596}, {0x1f5a4,0x1f5a4}, {0x1f5fb,0x1f64f}, {0x1f680,0x1f6c5},
    {0x1f6cc,0x1f6cc}, {0x1f6d0,0x1f6d2}, {0x1f6d5,0x1f6d8}, {0x1f6dc,0x1f6df},
    {0x1f6eb,0x1f6ec}, {0x1f6f4,0x1f6fc}, {0x1f7e0,0x1f7eb}, {0x1f7f0,0x1f7f0},
    {0x1f90c,0x1f93a}, {0x1f93c,0x1f945}, {0x1f947,0x1f9ff}, {0x1fa70,0x1fa7c},
    {0x1fa80,0x1fa8a}, {0x1fa8e,0x1fac6}, {0x1fac8,0x1fac8}, {0x1facd,0x1fadc},
    {0x1fadf,0x1faea}, {0x1faef,0x1faf8}, {0x20000,0x2a6df}, {0x2a700,0x2b81d},
    {0x2b820,0x2cead}, {0x2ceb0,0x2ebe0}, {0x2ebf0,0x2ee5d}, {0x2f800,0x2fa1d},
    {0x30000,0x3134a}, {0x31350,0x33479},
};
template<std::size_t N> inline bool contains(const Range (&ranges)[N], char32_t code) {
    auto at = std::upper_bound(std::begin(ranges), std::end(ranges), code, [](char32_t key, const auto& range) {return key < range.first;});
    return at != std::begin(ranges) && code <= (--at)->last;
}
inline int width(char32_t code) {return contains(zero_width, code) ? 0 : contains(double_width, code) ? 2 : 1;}
inline void append_utf8(std::string& text, char32_t code) {
    if (code < 0x80) text.push_back(static_cast<char>(code));
    else if (code < 0x800) {text.push_back(static_cast<char>(0xc0 | (code >> 6)));text.push_back(static_cast<char>(0x80 | (code & 0x3f)));}
    else if (code < 0x10000) {
        text.push_back(static_cast<char>(0xe0 | (code >> 12)));text.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3f)));
        text.push_back(static_cast<char>(0x80 | (code & 0x3f)));
    } else {
        text.push_back(static_cast<char>(0xf0 | (code >> 18)));text.push_back(static_cast<char>(0x80 | ((code >> 12) & 0x3f)));
        text.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3f)));text.push_back(static_cast<char>(0x80 | (code & 0x3f)));
    }
}
} // namespace terminal_unicode

// Bounded, UI-independent terminal state. It interprets display/editing commands only: OSC clipboard,
// hyperlinks, window commands and device-response requests never become host actions or generated input.
class TerminalScreen {
public:
    explicit TerminalScreen(std::size_t columns = 100, std::size_t rows = 30, std::size_t scrollback_limit = 5000)
        : columns_(columns), rows_(rows), scrollback_limit_(scrollback_limit) {
        dimensions(columns, rows);
        if (scrollback_limit > 10000) throw std::invalid_argument("Terminal scrollback exceeds its limit");
        initialize(main_); reset_tabs();
    }
    const std::vector<TerminalLine>& lines() const noexcept {return active().lines;}
    const std::deque<TerminalLine>& scrollback() const noexcept {return scrollback_;}
    TerminalCursor cursor() const noexcept {const auto& value=active();return {value.column,value.row,cursor_visible_};}
    std::size_t columns() const noexcept {return columns_;}
    std::size_t rows() const noexcept {return rows_;}
    const std::string& title() const noexcept {return title_;}
    bool alternate_screen() const noexcept {return alternate_active_;}
    bool bracketed_paste() const noexcept {return bracketed_paste_;}
    bool application_cursor_keys() const noexcept {return application_cursor_keys_;}
    std::size_t unsupported_sequences() const noexcept {return unsupported_;}
    static std::string line_text(const TerminalLine& line) {
        std::string result;
        for(const auto& cell:line)if(!cell.continuation)result+=cell.text;
        return result;
    }
    void clear_scrollback() noexcept {scrollback_.clear();scrollback_cells_=0;}
    void consume(std::string_view bytes) {for(const auto byte:bytes)consume_byte(static_cast<unsigned char>(byte));}
    void finish() {
        if(utf8_remaining_){utf8_remaining_=0;put(0xfffd);}
        state_=State::ground;sequence_.clear();sequence_overflow_=false;
    }
    void resize(std::size_t columns,std::size_t rows) {
        dimensions(columns,rows);
        if(columns==columns_&&rows==rows_)return;
        const auto old_columns=columns_,old_rows=rows_;
        columns_=columns;rows_=rows;
        resize_buffer(main_,old_rows,true);
        if(!alternate_.lines.empty())resize_buffer(alternate_,old_rows,false);
        tabs_.resize(columns_,false);
        for(auto column=old_columns;column<columns_;++column)if(column%8==0)tabs_[column]=true;
    }

private:
    enum class State {ground,escape,csi,osc,osc_escape,ignored_string,ignored_escape,charset,escape_intermediate};
    struct SavedCursor {std::size_t column{},row{};TerminalStyle style;bool origin{};};
    struct Buffer {
        std::vector<TerminalLine> lines;
        std::size_t column{},row{},top{},bottom{};
        bool wrap_pending{};
        SavedCursor saved;
    };
    std::size_t columns_,rows_,scrollback_limit_,scrollback_cells_{},unsupported_{};
    Buffer main_,alternate_;
    std::deque<TerminalLine> scrollback_;
    std::vector<bool> tabs_;
    TerminalStyle style_;
    State state_{State::ground};
    std::string sequence_,title_;
    bool sequence_overflow_{},alternate_active_{},cursor_visible_{true},auto_wrap_{true},origin_{},insert_mode_{},newline_mode_{};
    bool bracketed_paste_{},application_cursor_keys_{},g0_graphics_{},g1_graphics_{},use_g1_{};
    char charset_target_{},escape_intermediate_{};
    char32_t utf8_value_{},utf8_min_{};
    unsigned utf8_remaining_{};
    static constexpr std::size_t sequence_limit=4096,scrollback_cell_limit=200000,cell_text_limit=128;

    Buffer& active() noexcept {return alternate_active_?alternate_:main_;}
    const Buffer& active() const noexcept {return alternate_active_?alternate_:main_;}
    static void dimensions(std::size_t columns,std::size_t rows) {
        if(!columns||!rows||columns>1000||rows>500||columns>200000/rows)throw std::invalid_argument("Terminal grid exceeds its size limits");
    }
    TerminalCell blank() const {return {" ",style_,1,false};}
    TerminalLine blank_line() const {return TerminalLine(columns_,blank());}
    void initialize(Buffer& value) {value=Buffer{};value.lines.assign(rows_,blank_line());value.bottom=rows_-1;}
    void reset_tabs() {tabs_.assign(columns_,false);for(std::size_t column=8;column<columns_;column+=8)tabs_[column]=true;}
    void unsupported() noexcept {if(unsupported_!=std::numeric_limits<std::size_t>::max())++unsupported_;}
    void remember_line(TerminalLine line) {
        if(!scrollback_limit_)return;
        scrollback_cells_+=line.size();scrollback_.push_back(std::move(line));
        while(scrollback_.size()>scrollback_limit_||scrollback_cells_>scrollback_cell_limit){scrollback_cells_-=scrollback_.front().size();scrollback_.pop_front();}
    }
    void repair(TerminalLine& line) {
        for(std::size_t column=0;column<line.size();++column){
            auto& cell=line[column];
            if(cell.continuation&&(column==0||line[column-1].width!=2||line[column-1].continuation))cell=blank();
            else if(cell.width==2&&(column+1==line.size()||!line[column+1].continuation))cell=blank();
        }
    }
    void resize_buffer(Buffer& value,std::size_t old_rows,bool primary) {
        const auto removed=value.row>=rows_?value.row-rows_+1:0;
        for(std::size_t i=0;i<removed;++i){if(primary)remember_line(std::move(value.lines.front()));value.lines.erase(value.lines.begin());}
        value.row-=removed;
        value.lines.resize(rows_,blank_line());
        for(auto& line:value.lines){line.resize(columns_,blank());repair(line);}
        value.column=std::min(value.column,columns_-1);value.row=std::min(value.row,rows_-1);value.wrap_pending=false;
        if(value.bottom==old_rows-1)value.bottom=rows_-1;
        value.top=std::min(value.top,rows_-1);value.bottom=std::min(value.bottom,rows_-1);
        if(value.top>=value.bottom){value.top=0;value.bottom=rows_-1;}
        value.saved.column=std::min(value.saved.column,columns_-1);value.saved.row=std::min(value.saved.row,rows_-1);
    }
    void scroll_up(std::size_t count,std::size_t top,std::size_t bottom) {
        auto& value=active();count=std::min(count,bottom-top+1);
        for(std::size_t i=0;i<count;++i){
            if(!alternate_active_&&top==0&&bottom==rows_-1)remember_line(std::move(value.lines[top]));
            value.lines.erase(value.lines.begin()+static_cast<std::ptrdiff_t>(top));
            value.lines.insert(value.lines.begin()+static_cast<std::ptrdiff_t>(bottom),blank_line());
        }
    }
    void scroll_down(std::size_t count,std::size_t top,std::size_t bottom) {
        auto& value=active();count=std::min(count,bottom-top+1);
        for(std::size_t i=0;i<count;++i){value.lines.erase(value.lines.begin()+static_cast<std::ptrdiff_t>(bottom));value.lines.insert(value.lines.begin()+static_cast<std::ptrdiff_t>(top),blank_line());}
    }
    void index(bool reverse=false) {
        auto& value=active();value.wrap_pending=false;
        if(reverse){if(value.row==value.top)scroll_down(1,value.top,value.bottom);else if(value.row)--value.row;}
        else if(value.row==value.bottom)scroll_up(1,value.top,value.bottom);
        else if(value.row+1<rows_)++value.row;
    }
    void erase_cell(TerminalLine& line,std::size_t column) {
        if(line[column].continuation&&column){line[column-1]=blank();}
        else if(line[column].width==2&&column+1<columns_)line[column+1]=blank();
        line[column]=blank();
    }
    void erase_range(TerminalLine& line,std::size_t first,std::size_t last) {
        for(auto column=first;column<last;++column)erase_cell(line,column);
    }
    void characters(std::size_t count,bool insert) {
        auto& value=active();auto& line=value.lines[value.row];count=std::min(count,columns_-value.column);
        if(insert){line.insert(line.begin()+static_cast<std::ptrdiff_t>(value.column),count,blank());line.resize(columns_);}
        else{line.erase(line.begin()+static_cast<std::ptrdiff_t>(value.column),line.begin()+static_cast<std::ptrdiff_t>(value.column+count));line.resize(columns_,blank());}
        repair(line);value.wrap_pending=false;
    }
    TerminalCell* previous_cell() {
        auto& value=active();
        if(!value.column&&!value.wrap_pending)return nullptr;
        auto column=value.wrap_pending?value.column:value.column-1;
        if(value.lines[value.row][column].continuation&&column)--column;
        return &value.lines[value.row][column];
    }
    static char32_t graphics(char32_t code) {
        static constexpr char32_t mapping[]{0x25c6,0x2592,0x2409,0x240c,0x240d,0x240a,0x00b0,0x00b1,0x2424,0x240b,0x2518,0x2510,
            0x250c,0x2514,0x253c,0x23ba,0x23bb,0x2500,0x23bc,0x23bd,0x251c,0x2524,0x2534,0x252c,0x2502,0x2264,0x2265,0x03c0,0x2260,0x00a3,0x00b7};
        return code>=0x60&&code<=0x7e?mapping[code-0x60]:code;
    }
    void put(char32_t code) {
        if(code<0x20||(code>=0x7f&&code<=0x9f))return;
        if((use_g1_?g1_graphics_:g0_graphics_)&&code<0x80)code=graphics(code);
        const auto width=terminal_unicode::width(code);
        auto* previous=previous_cell();
        if(!width){
            if(previous&&previous->text.size()+4<=cell_text_limit)terminal_unicode::append_utf8(previous->text,code);
            return;
        }
        if(previous&&previous->text.size()+4<=cell_text_limit){
            bool regional_pair{};
            if(code>=0x1f1e6&&code<=0x1f1ff&&previous->text.size()==4){
                const auto& text=previous->text;
                const auto prior=((static_cast<unsigned char>(text[0])&7U)<<18)|((static_cast<unsigned char>(text[1])&0x3fU)<<12)
                    |((static_cast<unsigned char>(text[2])&0x3fU)<<6)|(static_cast<unsigned char>(text[3])&0x3fU);
                regional_pair=prior>=0x1f1e6&&prior<=0x1f1ff;
            }
            if(regional_pair||previous->text.ends_with("\xe2\x80\x8d")){terminal_unicode::append_utf8(previous->text,code);return;}
        }
        auto& value=active();
        if(value.wrap_pending){value.wrap_pending=false;if(auto_wrap_){value.column=0;index();}}
        auto cell_width=static_cast<std::size_t>(width);
        if(cell_width==2&&value.column+1>=columns_){
            if(auto_wrap_&&columns_>1){value.column=0;index();}
            else cell_width=1;
        }
        if(insert_mode_)characters(cell_width,true);
        auto& line=value.lines[value.row];
        erase_cell(line,value.column);
        if(cell_width==2)erase_cell(line,value.column+1);
        std::string text;terminal_unicode::append_utf8(text,code);
        line[value.column]={std::move(text),style_,static_cast<std::uint8_t>(cell_width),false};
        if(cell_width==2)line[value.column+1]={"",style_,0,true};
        if(value.column+cell_width>=columns_){value.column=columns_-1;value.wrap_pending=auto_wrap_;}
        else value.column+=cell_width;
    }
    void ground(unsigned char byte) {
        if(utf8_remaining_){
            if((byte&0xc0)==0x80){
                utf8_value_=(utf8_value_<<6)|(byte&0x3f);
                if(!--utf8_remaining_){const auto code=utf8_value_;put(code<utf8_min_||code>0x10ffff||(code>=0xd800&&code<=0xdfff)?0xfffd:code);}
                return;
            }
            utf8_remaining_=0;put(0xfffd);
        }
        auto& value=active();
        switch(byte){
        case 0x1b:state_=State::escape;return;
        case '\r':value.column=0;value.wrap_pending=false;return;
        case '\n':case '\v':case '\f':if(newline_mode_)value.column=0;index();return;
        case '\b':if(value.column)--value.column;value.wrap_pending=false;return;
        case '\t':tab(1,false);return;
        case 0x0e:use_g1_=true;return;
        case 0x0f:use_g1_=false;return;
        default:break;
        }
        if(byte<0x20||byte==0x7f)return;
        if(byte<0x80){put(byte);return;}
        if(byte>=0xc2&&byte<=0xdf){utf8_value_=byte&0x1f;utf8_remaining_=1;utf8_min_=0x80;}
        else if(byte>=0xe0&&byte<=0xef){utf8_value_=byte&0x0f;utf8_remaining_=2;utf8_min_=0x800;}
        else if(byte>=0xf0&&byte<=0xf4){utf8_value_=byte&7;utf8_remaining_=3;utf8_min_=0x10000;}
        else put(0xfffd);
    }
    void consume_byte(unsigned char byte) {
        if(byte==0x18||byte==0x1a){state_=State::ground;sequence_.clear();sequence_overflow_=false;utf8_remaining_=0;return;}
        switch(state_){
        case State::ground:ground(byte);break;
        case State::escape:escape(byte);break;
        case State::csi:
            if(byte>=0x40&&byte<=0x7e){if(sequence_overflow_)unsupported();else csi(static_cast<char>(byte));sequence_.clear();sequence_overflow_=false;state_=State::ground;}
            else if(byte==0x1b){state_=State::escape;sequence_.clear();sequence_overflow_=false;}
            else if(sequence_.size()<128)sequence_.push_back(static_cast<char>(byte));else sequence_overflow_=true;
            break;
        case State::osc:
            if(byte==7){osc();state_=State::ground;}
            else if(byte==0x1b)state_=State::osc_escape;
            else if(sequence_.size()<sequence_limit)sequence_.push_back(static_cast<char>(byte));else sequence_overflow_=true;
            break;
        case State::osc_escape:
            if(byte=='\\'){osc();state_=State::ground;}
            else{state_=State::osc;if(sequence_.size()+2<=sequence_limit){sequence_.push_back('\x1b');sequence_.push_back(static_cast<char>(byte));}else sequence_overflow_=true;}
            break;
        case State::ignored_string:if(byte==0x1b)state_=State::ignored_escape;break;
        case State::ignored_escape:state_=byte=='\\'?State::ground:State::ignored_string;break;
        case State::charset:
            if(byte=='0'||byte=='B'){if(charset_target_=='(')g0_graphics_=byte=='0';else g1_graphics_=byte=='0';}else unsupported();
            state_=State::ground;break;
        case State::escape_intermediate:
            if(escape_intermediate_=='#'&&byte=='8'){for(auto& line:active().lines)for(auto& cell:line)cell={"E",style_,1,false};}
            else if(!(escape_intermediate_=='%'&&byte=='G'))unsupported();
            state_=State::ground;break;
        }
    }
    void save_cursor() {auto& value=active();value.saved={value.column,value.row,style_,origin_};}
    void restore_cursor() {auto& value=active();value.column=std::min(value.saved.column,columns_-1);value.row=std::min(value.saved.row,rows_-1);style_=value.saved.style;origin_=value.saved.origin;value.wrap_pending=false;}
    void reset() {
        style_={};alternate_active_=false;initialize(main_);alternate_=Buffer{};clear_scrollback();reset_tabs();
        auto_wrap_=cursor_visible_=true;origin_=insert_mode_=newline_mode_=bracketed_paste_=application_cursor_keys_=false;
        g0_graphics_=g1_graphics_=use_g1_=false;utf8_remaining_=0;
    }
    void escape(unsigned char byte) {
        state_=State::ground;
        switch(byte){
        case '[':sequence_.clear();sequence_overflow_=false;state_=State::csi;break;
        case ']':sequence_.clear();sequence_overflow_=false;state_=State::osc;break;
        case 'P':case '^':case '_':unsupported();state_=State::ignored_string;break;
        case '7':save_cursor();break;
        case '8':restore_cursor();break;
        case 'D':index();break;
        case 'E':active().column=0;index();break;
        case 'M':index(true);break;
        case 'H':tabs_[active().column]=true;break;
        case '(' :case ')':charset_target_=static_cast<char>(byte);state_=State::charset;break;
        case '#':case '%':escape_intermediate_=static_cast<char>(byte);state_=State::escape_intermediate;break;
        case 'c':reset();break;
        case '=':case '>':break; // Numeric/application keypad mode does not trigger a host action.
        default:unsupported();break;
        }
    }
    void tab(std::size_t count,bool reverse) {
        auto& value=active();count=std::min(count,columns_);value.wrap_pending=false;
        for(std::size_t n=0;n<count;++n){
            if(reverse){if(value.column)--value.column;while(value.column&&!tabs_[value.column])--value.column;}
            else{if(value.column+1<columns_)++value.column;while(value.column+1<columns_&&!tabs_[value.column])++value.column;}
        }
    }
    void alternate(bool enabled,bool clear,bool save) {
        if(enabled){
            if(alternate_active_)return;
            if(save)save_cursor();
            if(clear||alternate_.lines.empty())initialize(alternate_);
            alternate_active_=true;
        }else if(alternate_active_){alternate_active_=false;if(save)restore_cursor();}
    }
    void modes(const std::vector<int>& parameters,bool private_mode,bool enabled) {
        for(const auto parameter:parameters){
            if(private_mode)switch(parameter){
            case 1:application_cursor_keys_=enabled;break;
            case 6:origin_=enabled;active().column=0;active().row=enabled?active().top:0;active().wrap_pending=false;break;
            case 7:auto_wrap_=enabled;active().wrap_pending=false;break;
            case 25:cursor_visible_=enabled;break;
            case 47:alternate(enabled,false,false);break;
            case 1047:alternate(enabled,true,false);break;
            case 1048:if(enabled)save_cursor();else restore_cursor();break;
            case 1049:alternate(enabled,true,true);break;
            case 2004:bracketed_paste_=enabled;break;
            default:unsupported();break;
            }
            else if(parameter==4)insert_mode_=enabled;else if(parameter==20)newline_mode_=enabled;else unsupported();
        }
    }
    void sgr(const std::vector<int>& parameters) {
        for(std::size_t i=0;i<parameters.size();++i){
            const auto value=parameters[i]<0?0:parameters[i];
            switch(value){
            case 0:style_={};break;
            case 1:style_.bold=true;break;case 2:style_.dim=true;break;case 3:style_.italic=true;break;
            case 4:case 21:style_.underline=true;break;case 7:style_.inverse=true;break;case 8:style_.conceal=true;break;case 9:style_.strikethrough=true;break;
            case 22:style_.bold=style_.dim=false;break;case 23:style_.italic=false;break;case 24:style_.underline=false;break;
            case 27:style_.inverse=false;break;case 28:style_.conceal=false;break;case 29:style_.strikethrough=false;break;
            case 39:style_.foreground={};break;case 49:style_.background={};break;
            case 38:case 48:{
                auto& color=value==38?style_.foreground:style_.background;
                if(i+2<parameters.size()&&parameters[i+1]==5&&parameters[i+2]>=0&&parameters[i+2]<=255){color={TerminalColor::Kind::indexed,static_cast<std::uint32_t>(parameters[i+2])};i+=2;}
                else if(i+4<parameters.size()&&parameters[i+1]==2&&std::all_of(parameters.begin()+static_cast<std::ptrdiff_t>(i+2),parameters.begin()+static_cast<std::ptrdiff_t>(i+5),[](auto part){return part>=0&&part<=255;})){
                    color={TerminalColor::Kind::rgb,static_cast<std::uint32_t>((parameters[i+2]<<16)|(parameters[i+3]<<8)|parameters[i+4])};i+=4;
                }else{unsupported();return;}
                break;
            }
            default:
                if(value>=30&&value<=37)style_.foreground={TerminalColor::Kind::indexed,static_cast<std::uint32_t>(value-30)};
                else if(value>=40&&value<=47)style_.background={TerminalColor::Kind::indexed,static_cast<std::uint32_t>(value-40)};
                else if(value>=90&&value<=97)style_.foreground={TerminalColor::Kind::indexed,static_cast<std::uint32_t>(value-90+8)};
                else if(value>=100&&value<=107)style_.background={TerminalColor::Kind::indexed,static_cast<std::uint32_t>(value-100+8)};
                else unsupported();
                break;
            }
        }
    }
    void csi(char command) {
        std::string_view raw=sequence_;bool private_mode{};
        if(!raw.empty()&&raw.front()=='?'){private_mode=true;raw.remove_prefix(1);}
        std::vector<int> values(1,-1);
        for(const auto byte:raw){
            if(byte==';'){if(values.size()>=32){unsupported();return;}values.push_back(-1);}
            else if(byte>='0'&&byte<='9'){auto& value=values.back();value=std::min(1000000,std::max(value,0)*10+(byte-'0'));}
            else{unsupported();return;}
        }
        if(command=='h'||command=='l'){modes(values,private_mode,command=='h');return;}
        if(private_mode){unsupported();return;}
        const auto parameter=[&](std::size_t at,int fallback){return at<values.size()&&values[at]>=0?values[at]:fallback;};
        const auto amount=static_cast<std::size_t>(std::max(parameter(0,1),1));
        auto& value=active();
        const auto vertical=[&](std::size_t row){value.row=std::clamp(row,origin_?value.top:0,origin_?value.bottom:rows_-1);};
        switch(command){
        case 'A':vertical(value.row>amount?value.row-amount:0);break;
        case 'B':case 'e':vertical(value.row+amount);break;
        case 'C':case 'a':value.column=std::min(columns_-1,value.column+amount);break;
        case 'D':value.column=value.column>amount?value.column-amount:0;break;
        case 'E':vertical(value.row+amount);value.column=0;break;
        case 'F':vertical(value.row>amount?value.row-amount:0);value.column=0;break;
        case 'G':case '`':value.column=std::min(columns_-1,amount-1);break;
        case 'd':vertical((origin_?value.top:0)+amount-1);break;
        case 'H':case 'f':vertical((origin_?value.top:0)+static_cast<std::size_t>(std::max(parameter(0,1),1))-1);value.column=std::min(columns_-1,static_cast<std::size_t>(std::max(parameter(1,1),1))-1);break;
        case 'J':{
            const auto mode=parameter(0,0);
            if(mode==3)clear_scrollback();
            else if(mode==2){for(auto& line:value.lines)line=blank_line();}
            else if(mode==0){erase_range(value.lines[value.row],value.column,columns_);for(auto row=value.row+1;row<rows_;++row)value.lines[row]=blank_line();}
            else if(mode==1){for(std::size_t row=0;row<value.row;++row)value.lines[row]=blank_line();erase_range(value.lines[value.row],0,value.column+1);}
            else unsupported();break;
        }
        case 'K':{const auto mode=parameter(0,0);if(mode==0)erase_range(value.lines[value.row],value.column,columns_);else if(mode==1)erase_range(value.lines[value.row],0,value.column+1);else if(mode==2)value.lines[value.row]=blank_line();else unsupported();break;}
        case 'X':erase_range(value.lines[value.row],value.column,std::min(columns_,value.column+amount));break;
        case '@':characters(amount,true);break;case 'P':characters(amount,false);break;
        case 'L':if(value.row>=value.top&&value.row<=value.bottom)scroll_down(amount,value.row,value.bottom);break;
        case 'M':if(value.row>=value.top&&value.row<=value.bottom)scroll_up(amount,value.row,value.bottom);break;
        case 'S':scroll_up(amount,value.top,value.bottom);break;case 'T':scroll_down(amount,value.top,value.bottom);break;
        case 'r':{const auto top=std::max(parameter(0,1),1),bottom=std::max(parameter(1,static_cast<int>(rows_)),1);if(top<bottom&&static_cast<std::size_t>(bottom)<=rows_){value.top=static_cast<std::size_t>(top-1);value.bottom=static_cast<std::size_t>(bottom-1);value.column=0;value.row=origin_?value.top:0;}else unsupported();break;}
        case 's':save_cursor();break;case 'u':restore_cursor();break;
        case 'I':tab(amount,false);break;case 'Z':tab(amount,true);break;
        case 'g':if(parameter(0,0)==0)tabs_[value.column]=false;else if(parameter(0,0)==3)std::fill(tabs_.begin(),tabs_.end(),false);else unsupported();break;
        case 'm':sgr(values);return;
        default:unsupported();break;
        }
        value.wrap_pending=false;
    }
    static std::string title_text(std::string_view input) {
        std::string result;
        for(std::size_t offset=0;offset<input.size();){
            const auto byte=static_cast<unsigned char>(input[offset++]);char32_t code=byte;unsigned count{};char32_t minimum{};
            if(byte>=0xc2&&byte<=0xdf){code=byte&0x1f;count=1;minimum=0x80;}
            else if(byte>=0xe0&&byte<=0xef){code=byte&15;count=2;minimum=0x800;}
            else if(byte>=0xf0&&byte<=0xf4){code=byte&7;count=3;minimum=0x10000;}
            else if(byte>=0x80)code=0xfffd;
            bool valid=true;
            for(unsigned i=0;i<count;++i){if(offset==input.size()||(static_cast<unsigned char>(input[offset])&0xc0)!=0x80){valid=false;break;}code=(code<<6)|(static_cast<unsigned char>(input[offset++])&0x3f);}
            if(!valid||code<minimum||code>0x10ffff||(code>=0xd800&&code<=0xdfff))code=0xfffd;
            if(code>=0x20&&!(code>=0x7f&&code<=0x9f))terminal_unicode::append_utf8(result,code);
        }
        return result;
    }
    void osc() {
        if(sequence_overflow_){unsupported();sequence_.clear();sequence_overflow_=false;return;}
        const auto separator=sequence_.find(';');
        const auto command=std::string_view(sequence_).substr(0,separator);
        if(separator!=std::string::npos&&(command=="0"||command=="2"))title_=title_text(std::string_view(sequence_).substr(separator+1));
        else unsupported();
        sequence_.clear();sequence_overflow_=false;
    }
};
} // namespace coincide
