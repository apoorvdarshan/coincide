#pragma once

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_set>
#include <utility>
#include <vector>

namespace coincide {

// Wire identifiers match CoincideKit/Models/Models.swift. Display names are localized by the UI.
inline constexpr std::array<std::string_view, 6> provider_ids{
    "claude", "codex", "cursor", "grok", "opencode", "antigravity"};

inline bool known_provider(std::string_view id) {
    return std::find(provider_ids.begin(), provider_ids.end(), id) != provider_ids.end();
}

namespace workspace_text {
// Invariant Unicode 17.0.0 case folding. The compact ranges and expansions are generated from
// Python's Unicode casefold data; lookup is portable and does not depend on the process's active locale.
struct FoldRange { char32_t first, last; std::uint32_t stride; std::int32_t delta; };
inline constexpr FoldRange fold_ranges[]{
        {0x41, 0x5a, 1, 32},
        {0xb5, 0xb5, 1, 775},
        {0xc0, 0xd6, 1, 32},
        {0xd8, 0xde, 1, 32},
        {0x100, 0x12e, 2, 1},
        {0x132, 0x136, 2, 1},
        {0x139, 0x147, 2, 1},
        {0x14a, 0x176, 2, 1},
        {0x178, 0x178, 1, -121},
        {0x179, 0x17d, 2, 1},
        {0x17f, 0x17f, 1, -268},
        {0x181, 0x181, 1, 210},
        {0x182, 0x184, 2, 1},
        {0x186, 0x186, 1, 206},
        {0x187, 0x187, 1, 1},
        {0x189, 0x18a, 1, 205},
        {0x18b, 0x18b, 1, 1},
        {0x18e, 0x18e, 1, 79},
        {0x18f, 0x18f, 1, 202},
        {0x190, 0x190, 1, 203},
        {0x191, 0x191, 1, 1},
        {0x193, 0x193, 1, 205},
        {0x194, 0x194, 1, 207},
        {0x196, 0x196, 1, 211},
        {0x197, 0x197, 1, 209},
        {0x198, 0x198, 1, 1},
        {0x19c, 0x19c, 1, 211},
        {0x19d, 0x19d, 1, 213},
        {0x19f, 0x19f, 1, 214},
        {0x1a0, 0x1a4, 2, 1},
        {0x1a6, 0x1a6, 1, 218},
        {0x1a7, 0x1a7, 1, 1},
        {0x1a9, 0x1a9, 1, 218},
        {0x1ac, 0x1ac, 1, 1},
        {0x1ae, 0x1ae, 1, 218},
        {0x1af, 0x1af, 1, 1},
        {0x1b1, 0x1b2, 1, 217},
        {0x1b3, 0x1b5, 2, 1},
        {0x1b7, 0x1b7, 1, 219},
        {0x1b8, 0x1b8, 1, 1},
        {0x1bc, 0x1bc, 1, 1},
        {0x1c4, 0x1c4, 1, 2},
        {0x1c5, 0x1c5, 1, 1},
        {0x1c7, 0x1c7, 1, 2},
        {0x1c8, 0x1c8, 1, 1},
        {0x1ca, 0x1ca, 1, 2},
        {0x1cb, 0x1db, 2, 1},
        {0x1de, 0x1ee, 2, 1},
        {0x1f1, 0x1f1, 1, 2},
        {0x1f2, 0x1f4, 2, 1},
        {0x1f6, 0x1f6, 1, -97},
        {0x1f7, 0x1f7, 1, -56},
        {0x1f8, 0x21e, 2, 1},
        {0x220, 0x220, 1, -130},
        {0x222, 0x232, 2, 1},
        {0x23a, 0x23a, 1, 10795},
        {0x23b, 0x23b, 1, 1},
        {0x23d, 0x23d, 1, -163},
        {0x23e, 0x23e, 1, 10792},
        {0x241, 0x241, 1, 1},
        {0x243, 0x243, 1, -195},
        {0x244, 0x244, 1, 69},
        {0x245, 0x245, 1, 71},
        {0x246, 0x24e, 2, 1},
        {0x345, 0x345, 1, 116},
        {0x370, 0x372, 2, 1},
        {0x376, 0x376, 1, 1},
        {0x37f, 0x37f, 1, 116},
        {0x386, 0x386, 1, 38},
        {0x388, 0x38a, 1, 37},
        {0x38c, 0x38c, 1, 64},
        {0x38e, 0x38f, 1, 63},
        {0x391, 0x3a1, 1, 32},
        {0x3a3, 0x3ab, 1, 32},
        {0x3c2, 0x3c2, 1, 1},
        {0x3cf, 0x3cf, 1, 8},
        {0x3d0, 0x3d0, 1, -30},
        {0x3d1, 0x3d1, 1, -25},
        {0x3d5, 0x3d5, 1, -15},
        {0x3d6, 0x3d6, 1, -22},
        {0x3d8, 0x3ee, 2, 1},
        {0x3f0, 0x3f0, 1, -54},
        {0x3f1, 0x3f1, 1, -48},
        {0x3f4, 0x3f4, 1, -60},
        {0x3f5, 0x3f5, 1, -64},
        {0x3f7, 0x3f7, 1, 1},
        {0x3f9, 0x3f9, 1, -7},
        {0x3fa, 0x3fa, 1, 1},
        {0x3fd, 0x3ff, 1, -130},
        {0x400, 0x40f, 1, 80},
        {0x410, 0x42f, 1, 32},
        {0x460, 0x480, 2, 1},
        {0x48a, 0x4be, 2, 1},
        {0x4c0, 0x4c0, 1, 15},
        {0x4c1, 0x4cd, 2, 1},
        {0x4d0, 0x52e, 2, 1},
        {0x531, 0x556, 1, 48},
        {0x10a0, 0x10c5, 1, 7264},
        {0x10c7, 0x10c7, 1, 7264},
        {0x10cd, 0x10cd, 1, 7264},
        {0x13f8, 0x13fd, 1, -8},
        {0x1c80, 0x1c80, 1, -6222},
        {0x1c81, 0x1c81, 1, -6221},
        {0x1c82, 0x1c82, 1, -6212},
        {0x1c83, 0x1c84, 1, -6210},
        {0x1c85, 0x1c85, 1, -6211},
        {0x1c86, 0x1c86, 1, -6204},
        {0x1c87, 0x1c87, 1, -6180},
        {0x1c88, 0x1c88, 1, 35267},
        {0x1c89, 0x1c89, 1, 1},
        {0x1c90, 0x1cba, 1, -3008},
        {0x1cbd, 0x1cbf, 1, -3008},
        {0x1e00, 0x1e94, 2, 1},
        {0x1e9b, 0x1e9b, 1, -58},
        {0x1ea0, 0x1efe, 2, 1},
        {0x1f08, 0x1f0f, 1, -8},
        {0x1f18, 0x1f1d, 1, -8},
        {0x1f28, 0x1f2f, 1, -8},
        {0x1f38, 0x1f3f, 1, -8},
        {0x1f48, 0x1f4d, 1, -8},
        {0x1f59, 0x1f5f, 2, -8},
        {0x1f68, 0x1f6f, 1, -8},
        {0x1fb8, 0x1fb9, 1, -8},
        {0x1fba, 0x1fbb, 1, -74},
        {0x1fbe, 0x1fbe, 1, -7173},
        {0x1fc8, 0x1fcb, 1, -86},
        {0x1fd8, 0x1fd9, 1, -8},
        {0x1fda, 0x1fdb, 1, -100},
        {0x1fe8, 0x1fe9, 1, -8},
        {0x1fea, 0x1feb, 1, -112},
        {0x1fec, 0x1fec, 1, -7},
        {0x1ff8, 0x1ff9, 1, -128},
        {0x1ffa, 0x1ffb, 1, -126},
        {0x2126, 0x2126, 1, -7517},
        {0x212a, 0x212a, 1, -8383},
        {0x212b, 0x212b, 1, -8262},
        {0x2132, 0x2132, 1, 28},
        {0x2160, 0x216f, 1, 16},
        {0x2183, 0x2183, 1, 1},
        {0x24b6, 0x24cf, 1, 26},
        {0x2c00, 0x2c2f, 1, 48},
        {0x2c60, 0x2c60, 1, 1},
        {0x2c62, 0x2c62, 1, -10743},
        {0x2c63, 0x2c63, 1, -3814},
        {0x2c64, 0x2c64, 1, -10727},
        {0x2c67, 0x2c6b, 2, 1},
        {0x2c6d, 0x2c6d, 1, -10780},
        {0x2c6e, 0x2c6e, 1, -10749},
        {0x2c6f, 0x2c6f, 1, -10783},
        {0x2c70, 0x2c70, 1, -10782},
        {0x2c72, 0x2c72, 1, 1},
        {0x2c75, 0x2c75, 1, 1},
        {0x2c7e, 0x2c7f, 1, -10815},
        {0x2c80, 0x2ce2, 2, 1},
        {0x2ceb, 0x2ced, 2, 1},
        {0x2cf2, 0x2cf2, 1, 1},
        {0xa640, 0xa66c, 2, 1},
        {0xa680, 0xa69a, 2, 1},
        {0xa722, 0xa72e, 2, 1},
        {0xa732, 0xa76e, 2, 1},
        {0xa779, 0xa77b, 2, 1},
        {0xa77d, 0xa77d, 1, -35332},
        {0xa77e, 0xa786, 2, 1},
        {0xa78b, 0xa78b, 1, 1},
        {0xa78d, 0xa78d, 1, -42280},
        {0xa790, 0xa792, 2, 1},
        {0xa796, 0xa7a8, 2, 1},
        {0xa7aa, 0xa7aa, 1, -42308},
        {0xa7ab, 0xa7ab, 1, -42319},
        {0xa7ac, 0xa7ac, 1, -42315},
        {0xa7ad, 0xa7ad, 1, -42305},
        {0xa7ae, 0xa7ae, 1, -42308},
        {0xa7b0, 0xa7b0, 1, -42258},
        {0xa7b1, 0xa7b1, 1, -42282},
        {0xa7b2, 0xa7b2, 1, -42261},
        {0xa7b3, 0xa7b3, 1, 928},
        {0xa7b4, 0xa7c2, 2, 1},
        {0xa7c4, 0xa7c4, 1, -48},
        {0xa7c5, 0xa7c5, 1, -42307},
        {0xa7c6, 0xa7c6, 1, -35384},
        {0xa7c7, 0xa7c9, 2, 1},
        {0xa7cb, 0xa7cb, 1, -42343},
        {0xa7cc, 0xa7da, 2, 1},
        {0xa7dc, 0xa7dc, 1, -42561},
        {0xa7f5, 0xa7f5, 1, 1},
        {0xab70, 0xabbf, 1, -38864},
        {0xff21, 0xff3a, 1, 32},
        {0x10400, 0x10427, 1, 40},
        {0x104b0, 0x104d3, 1, 40},
        {0x10570, 0x1057a, 1, 39},
        {0x1057c, 0x1058a, 1, 39},
        {0x1058c, 0x10592, 1, 39},
        {0x10594, 0x10595, 1, 39},
        {0x10c80, 0x10cb2, 1, 64},
        {0x10d50, 0x10d65, 1, 32},
        {0x118a0, 0x118bf, 1, 32},
        {0x16e40, 0x16e5f, 1, 32},
        {0x16ea0, 0x16eb8, 1, 27},
        {0x1e900, 0x1e921, 1, 34},
};
struct FoldExpansion { char32_t code; std::string_view text; };
inline constexpr FoldExpansion fold_expansions[]{
        {0xdf, "\x73\x73"},
        {0x130, "\x69\xcc\x87"},
        {0x149, "\xca\xbc\x6e"},
        {0x1f0, "\x6a\xcc\x8c"},
        {0x390, "\xce\xb9\xcc\x88\xcc\x81"},
        {0x3b0, "\xcf\x85\xcc\x88\xcc\x81"},
        {0x587, "\xd5\xa5\xd6\x82"},
        {0x1e96, "\x68\xcc\xb1"},
        {0x1e97, "\x74\xcc\x88"},
        {0x1e98, "\x77\xcc\x8a"},
        {0x1e99, "\x79\xcc\x8a"},
        {0x1e9a, "\x61\xca\xbe"},
        {0x1e9e, "\x73\x73"},
        {0x1f50, "\xcf\x85\xcc\x93"},
        {0x1f52, "\xcf\x85\xcc\x93\xcc\x80"},
        {0x1f54, "\xcf\x85\xcc\x93\xcc\x81"},
        {0x1f56, "\xcf\x85\xcc\x93\xcd\x82"},
        {0x1f80, "\xe1\xbc\x80\xce\xb9"},
        {0x1f81, "\xe1\xbc\x81\xce\xb9"},
        {0x1f82, "\xe1\xbc\x82\xce\xb9"},
        {0x1f83, "\xe1\xbc\x83\xce\xb9"},
        {0x1f84, "\xe1\xbc\x84\xce\xb9"},
        {0x1f85, "\xe1\xbc\x85\xce\xb9"},
        {0x1f86, "\xe1\xbc\x86\xce\xb9"},
        {0x1f87, "\xe1\xbc\x87\xce\xb9"},
        {0x1f88, "\xe1\xbc\x80\xce\xb9"},
        {0x1f89, "\xe1\xbc\x81\xce\xb9"},
        {0x1f8a, "\xe1\xbc\x82\xce\xb9"},
        {0x1f8b, "\xe1\xbc\x83\xce\xb9"},
        {0x1f8c, "\xe1\xbc\x84\xce\xb9"},
        {0x1f8d, "\xe1\xbc\x85\xce\xb9"},
        {0x1f8e, "\xe1\xbc\x86\xce\xb9"},
        {0x1f8f, "\xe1\xbc\x87\xce\xb9"},
        {0x1f90, "\xe1\xbc\xa0\xce\xb9"},
        {0x1f91, "\xe1\xbc\xa1\xce\xb9"},
        {0x1f92, "\xe1\xbc\xa2\xce\xb9"},
        {0x1f93, "\xe1\xbc\xa3\xce\xb9"},
        {0x1f94, "\xe1\xbc\xa4\xce\xb9"},
        {0x1f95, "\xe1\xbc\xa5\xce\xb9"},
        {0x1f96, "\xe1\xbc\xa6\xce\xb9"},
        {0x1f97, "\xe1\xbc\xa7\xce\xb9"},
        {0x1f98, "\xe1\xbc\xa0\xce\xb9"},
        {0x1f99, "\xe1\xbc\xa1\xce\xb9"},
        {0x1f9a, "\xe1\xbc\xa2\xce\xb9"},
        {0x1f9b, "\xe1\xbc\xa3\xce\xb9"},
        {0x1f9c, "\xe1\xbc\xa4\xce\xb9"},
        {0x1f9d, "\xe1\xbc\xa5\xce\xb9"},
        {0x1f9e, "\xe1\xbc\xa6\xce\xb9"},
        {0x1f9f, "\xe1\xbc\xa7\xce\xb9"},
        {0x1fa0, "\xe1\xbd\xa0\xce\xb9"},
        {0x1fa1, "\xe1\xbd\xa1\xce\xb9"},
        {0x1fa2, "\xe1\xbd\xa2\xce\xb9"},
        {0x1fa3, "\xe1\xbd\xa3\xce\xb9"},
        {0x1fa4, "\xe1\xbd\xa4\xce\xb9"},
        {0x1fa5, "\xe1\xbd\xa5\xce\xb9"},
        {0x1fa6, "\xe1\xbd\xa6\xce\xb9"},
        {0x1fa7, "\xe1\xbd\xa7\xce\xb9"},
        {0x1fa8, "\xe1\xbd\xa0\xce\xb9"},
        {0x1fa9, "\xe1\xbd\xa1\xce\xb9"},
        {0x1faa, "\xe1\xbd\xa2\xce\xb9"},
        {0x1fab, "\xe1\xbd\xa3\xce\xb9"},
        {0x1fac, "\xe1\xbd\xa4\xce\xb9"},
        {0x1fad, "\xe1\xbd\xa5\xce\xb9"},
        {0x1fae, "\xe1\xbd\xa6\xce\xb9"},
        {0x1faf, "\xe1\xbd\xa7\xce\xb9"},
        {0x1fb2, "\xe1\xbd\xb0\xce\xb9"},
        {0x1fb3, "\xce\xb1\xce\xb9"},
        {0x1fb4, "\xce\xac\xce\xb9"},
        {0x1fb6, "\xce\xb1\xcd\x82"},
        {0x1fb7, "\xce\xb1\xcd\x82\xce\xb9"},
        {0x1fbc, "\xce\xb1\xce\xb9"},
        {0x1fc2, "\xe1\xbd\xb4\xce\xb9"},
        {0x1fc3, "\xce\xb7\xce\xb9"},
        {0x1fc4, "\xce\xae\xce\xb9"},
        {0x1fc6, "\xce\xb7\xcd\x82"},
        {0x1fc7, "\xce\xb7\xcd\x82\xce\xb9"},
        {0x1fcc, "\xce\xb7\xce\xb9"},
        {0x1fd2, "\xce\xb9\xcc\x88\xcc\x80"},
        {0x1fd3, "\xce\xb9\xcc\x88\xcc\x81"},
        {0x1fd6, "\xce\xb9\xcd\x82"},
        {0x1fd7, "\xce\xb9\xcc\x88\xcd\x82"},
        {0x1fe2, "\xcf\x85\xcc\x88\xcc\x80"},
        {0x1fe3, "\xcf\x85\xcc\x88\xcc\x81"},
        {0x1fe4, "\xcf\x81\xcc\x93"},
        {0x1fe6, "\xcf\x85\xcd\x82"},
        {0x1fe7, "\xcf\x85\xcc\x88\xcd\x82"},
        {0x1ff2, "\xe1\xbd\xbc\xce\xb9"},
        {0x1ff3, "\xcf\x89\xce\xb9"},
        {0x1ff4, "\xcf\x8e\xce\xb9"},
        {0x1ff6, "\xcf\x89\xcd\x82"},
        {0x1ff7, "\xcf\x89\xcd\x82\xce\xb9"},
        {0x1ffc, "\xcf\x89\xce\xb9"},
        {0xfb00, "\x66\x66"},
        {0xfb01, "\x66\x69"},
        {0xfb02, "\x66\x6c"},
        {0xfb03, "\x66\x66\x69"},
        {0xfb04, "\x66\x66\x6c"},
        {0xfb05, "\x73\x74"},
        {0xfb06, "\x73\x74"},
        {0xfb13, "\xd5\xb4\xd5\xb6"},
        {0xfb14, "\xd5\xb4\xd5\xa5"},
        {0xfb15, "\xd5\xb4\xd5\xab"},
        {0xfb16, "\xd5\xbe\xd5\xb6"},
        {0xfb17, "\xd5\xb4\xd5\xad"},
};

inline char32_t next(std::string_view value, std::size_t& offset) {
    const auto first = static_cast<unsigned char>(value[offset++]);
    if (first < 0x80) return first;
    const auto count = first >= 0xc2 && first <= 0xdf ? 2U : first >= 0xe0 && first <= 0xef ? 3U
        : first >= 0xf0 && first <= 0xf4 ? 4U : 0U;
    if (!count || value.size() - offset < count - 1) throw std::invalid_argument("Invalid UTF-8 text");
    char32_t code = first & (0x7fU >> count);
    for (unsigned i = 1; i < count; ++i) {
        const auto byte = static_cast<unsigned char>(value[offset++]);
        if ((byte & 0xc0) != 0x80) throw std::invalid_argument("Invalid UTF-8 text");
        code = (code << 6) | (byte & 0x3f);
    }
    if ((count == 2 && code < 0x80) || (count == 3 && code < 0x800) || (count == 4 && code < 0x10000)
            || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) throw std::invalid_argument("Invalid UTF-8 text");
    return code;
}
inline void append(std::string& value, char32_t code) {
    if (code < 0x80) value.push_back(static_cast<char>(code));
    else if (code < 0x800) {
        value.push_back(static_cast<char>(0xc0 | (code >> 6))); value.push_back(static_cast<char>(0x80 | (code & 0x3f)));
    } else if (code < 0x10000) {
        value.push_back(static_cast<char>(0xe0 | (code >> 12))); value.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3f)));
        value.push_back(static_cast<char>(0x80 | (code & 0x3f)));
    } else {
        value.push_back(static_cast<char>(0xf0 | (code >> 18))); value.push_back(static_cast<char>(0x80 | ((code >> 12) & 0x3f)));
        value.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3f))); value.push_back(static_cast<char>(0x80 | (code & 0x3f)));
    }
}
inline std::string fold(std::string_view value) {
    std::string result; result.reserve(value.size());
    for (std::size_t offset = 0; offset < value.size();) {
        const auto code = next(value, offset);
        const auto expansion = std::lower_bound(std::begin(fold_expansions), std::end(fold_expansions), code,
            [](const auto& item, char32_t key) { return item.code < key; });
        if (expansion != std::end(fold_expansions) && expansion->code == code) { result += expansion->text; continue; }
        auto range = std::upper_bound(std::begin(fold_ranges), std::end(fold_ranges), code,
            [](char32_t key, const auto& item) { return key < item.first; });
        if (range != std::begin(fold_ranges)) {
            --range;
            if (code <= range->last && (code - range->first) % range->stride == 0) {
                append(result, static_cast<char32_t>(static_cast<std::int64_t>(code) + range->delta)); continue;
            }
        }
        append(result, code);
    }
    return result;
}
inline bool whitespace(char32_t code) {
    return (code >= 9 && code <= 13) || code == 0x20 || code == 0x85 || code == 0xa0 || code == 0x1680
        || (code >= 0x2000 && code <= 0x200a) || code == 0x2028 || code == 0x2029 || code == 0x202f
        || code == 0x205f || code == 0x3000;
}
inline std::string label(std::string_view value, std::size_t limit) {
    if (value.size() > limit) throw std::invalid_argument("The name is too long");
    std::size_t first = value.size(), last{};
    for (std::size_t offset = 0; offset < value.size();) {
        const auto start = offset;
        if (!whitespace(next(value, offset))) { first = std::min(first, start); last = offset; }
    }
    if (first >= last) throw std::invalid_argument("A name cannot be blank");
    const auto trimmed = value.substr(first, last - first);
    for (std::size_t offset = 0; offset < trimmed.size();) {
        const auto code = next(trimmed, offset);
        if (code < 0x20 || (code >= 0x7f && code <= 0x9f) || code == 0x2028 || code == 0x2029) {
            throw std::invalid_argument("A name must be a single line without control characters");
        }
    }
    return std::string(trimmed);
}
} // namespace workspace_text

struct Project { std::string id, name, path; };
struct MessageAttachment { std::string path, name, media_type; };
struct Message {
    std::string id, role, text, provider;
    std::vector<MessageAttachment> attachments{};
};
struct QueuedInput {
    std::string id, text, model, effort, service_tier;
    bool plan{}, full_access{};
    std::vector<MessageAttachment> attachments{};
};
struct NativeSession {
    std::string provider, id;
    std::size_t acknowledged_messages{};
};
struct ProviderModelPreference {
    std::string provider, model, effort, service_tier;
    bool plan{}, full_access{};
};
struct Thread {
    std::string id, title;
    std::optional<std::string> project_id;
    std::string provider{"claude"};
    std::string model, draft;
    bool pinned{}, archived{};
    std::vector<Message> messages;
    std::vector<NativeSession> sessions;
    std::vector<MessageAttachment> draft_attachments;
    std::vector<QueuedInput> queued_inputs;
    std::vector<ProviderModelPreference> model_preferences;
    std::string effort, service_tier;
    bool plan{}, full_access{}, titled_by_user{};
    // UTC Unix seconds; zero means absent. Old workspaces keep their original stable order.
    std::int64_t created_at{}, updated_at{}, snoozed_until{}, settled_at{}, deleted_at{};
};
enum class ThreadView { inbox, archived, snoozed, settled, trash, all };

// Metadata history never copies or rewrites transcripts, drafts, or native provider sessions.
class Workspace {
public:
    std::vector<Project> projects;
    std::vector<Thread> threads;
    static std::int64_t now_seconds() {
        return std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    }
    static void validate_timestamp(std::int64_t value) {
        if (value < 0 || value > 253402300799LL) throw std::invalid_argument("Invalid conversation timestamp");
    }
    static bool is_settled(const Thread& value) { return value.settled_at > 0 && value.settled_at >= value.updated_at; }
    const Project& project(std::string_view id) const {
        const auto at = std::find_if(projects.begin(), projects.end(), [&](const auto& value) { return value.id == id; });
        if (at == projects.end()) throw std::out_of_range("Unknown project");
        return *at;
    }
    Project& project(std::string_view id) { return const_cast<Project&>(std::as_const(*this).project(id)); }
    const Thread& thread(std::string_view id) const {
        const auto at = std::find_if(threads.begin(), threads.end(), [&](const auto& value) { return value.id == id; });
        if (at == threads.end()) throw std::out_of_range("Unknown thread");
        return *at;
    }
    Thread& thread(std::string_view id) { return const_cast<Thread&>(std::as_const(*this).thread(id)); }

    void add_project(Project value) {
        if (value.id.empty() || value.path.empty() || value.path.size() > 32768 || value.path.find('\0') != std::string::npos) {
            throw std::invalid_argument("Project needs an identity and folder");
        }
        value.name = workspace_text::label(value.name, 512);
        if (std::any_of(projects.begin(), projects.end(), [&](const auto& p) { return p.id == value.id; })) {
            throw std::invalid_argument("Duplicate project identity");
        }
        projects.push_back(std::move(value));
        redo_.clear();
    }
    void add_thread(Thread value) {
        if (value.id.empty()) throw std::invalid_argument("Thread needs an identity");
        value.title = workspace_text::label(value.title, 4096);
        if (!known_provider(value.provider)) throw std::invalid_argument("Unknown provider");
        if (std::any_of(threads.begin(), threads.end(), [&](const auto& t) { return t.id == value.id; })) {
            throw std::invalid_argument("Duplicate thread identity");
        }
        if (value.project_id) (void)project(*value.project_id);
        validate_thread_metadata(value);
        threads.push_back(std::move(value));
        redo_.clear();
    }
    static void validate_thread_metadata(const Thread& value) {
        for (const auto stamp : {value.created_at, value.updated_at, value.snoozed_until, value.settled_at, value.deleted_at}) {
            validate_timestamp(stamp);
        }
        validate_model_fields(value.model, value.effort, value.service_tier);
        validate_model_preferences(value.model_preferences);
    }
    static void validate_model_fields(const std::string& model, const std::string& effort, const std::string& service_tier) {
        for (const auto* setting : {&model, &effort, &service_tier}) {
            if (setting->size() > 1024 || setting->find('\0') != std::string::npos) throw std::invalid_argument("Invalid model preference");
            (void)workspace_text::fold(*setting); // Validate UTF-8 without restricting future provider identifiers.
        }
    }
    static void validate_model_preferences(const std::vector<ProviderModelPreference>& preferences) {
        if (preferences.size() > provider_ids.size()) throw std::invalid_argument("Too many provider model preferences");
        std::unordered_set<std::string> providers;
        for (const auto& preference : preferences) {
            if (!known_provider(preference.provider) || !providers.insert(preference.provider).second) throw std::invalid_argument("Invalid provider model preference");
            validate_model_fields(preference.model, preference.effort, preference.service_tier);
        }
    }
    void select_provider(std::string_view id, std::string provider) {
        if (!known_provider(provider)) throw std::invalid_argument("Unknown provider");
        auto& value = thread(id);
        if (!known_provider(value.provider)) throw std::invalid_argument("Unknown existing provider");
        validate_thread_metadata(value);
        auto preferences = value.model_preferences;
        ProviderModelPreference current{value.provider, value.model, value.effort, value.service_tier, value.plan, value.full_access};
        const auto previous = std::find_if(preferences.begin(), preferences.end(), [&](const auto& item) { return item.provider == value.provider; });
        if (previous == preferences.end()) preferences.push_back(std::move(current)); else *previous = std::move(current);
        const auto target = std::find_if(preferences.begin(), preferences.end(), [&](const auto& item) { return item.provider == provider; });
        auto selected = target == preferences.end() ? ProviderModelPreference{provider, {}, {}, {}, false, false} : *target;
        value.provider.swap(provider); value.model.swap(selected.model); value.effort.swap(selected.effort);
        value.service_tier.swap(selected.service_tier); value.plan = selected.plan; value.full_access = selected.full_access;
        value.model_preferences.swap(preferences);
    }

    void rename_thread(std::string_view id, std::string title) {
        title = workspace_text::label(title, 4096);
        mutate({std::string(id)}, title_field | named_field, [&](auto& value) { value.title = title; value.titled_by_user = true; });
    }
    void pin(const std::vector<std::string>& ids, bool pinned) {
        mutate(ids, pin_field, [&](auto& value) { value.pinned = pinned; });
    }
    void archive(const std::vector<std::string>& ids, bool archived) {
        mutate(ids, archive_field, [&](auto& value) { value.archived = archived; });
    }
    void settle(const std::vector<std::string>& ids, bool settled, std::int64_t now = now_seconds()) {
        validate_timestamp(now);
        if (settled && !now) throw std::invalid_argument("Settlement needs a timestamp");
        mutate(ids, settled_field, [&](auto& value) { value.settled_at = settled ? std::max(now, value.updated_at) : 0; });
    }
    void snooze(const std::vector<std::string>& ids, std::int64_t until) {
        validate_timestamp(until);
        mutate(ids, snooze_field, [&](auto& value) { value.snoozed_until = until; });
    }
    void delete_threads(const std::vector<std::string>& ids, std::int64_t now = now_seconds()) {
        validate_timestamp(now);
        if (!now) throw std::invalid_argument("Deletion needs a timestamp");
        mutate(ids, deleted_field, [&](auto& value) { if (!value.deleted_at) value.deleted_at = now; });
    }
    void restore_threads(const std::vector<std::string>& ids) {
        mutate(ids, deleted_field, [](auto& value) { value.deleted_at = 0; });
    }
    void move_threads(const std::vector<std::string>& ids, std::optional<std::string> destination) {
        if (destination) (void)project(*destination);
        mutate(ids, project_field, [&](auto& value) { value.project_id = destination; });
    }
    void rename_project(std::string_view id, std::string name) {
        name = workspace_text::label(name, 512);
        auto before = project(id), after = before;
        if (after.name == name) return;
        after.name = std::move(name);
        HistoryEntry entry; entry.project = ProjectChange{before.id, before, after, project_position(id)};
        record(std::move(entry));
    }
    // Removing a project only detaches its conversations. It never deletes a folder or transcript.
    void remove_project(std::string_view id) {
        const auto before = project(id);
        HistoryEntry entry; entry.project = ProjectChange{before.id, before, std::nullopt, project_position(id)};
        for (const auto& value : threads) if (value.project_id && *value.project_id == id) {
            auto old = metadata(value), next = old; next.project_id.reset();
            entry.threads.push_back({value.id, std::move(old), std::move(next), project_field});
        }
        record(std::move(entry));
    }
    // A new message reopens a settled conversation. Input requests also wake a snoozed one.
    void note_activity(std::string_view id, std::int64_t now = now_seconds(), bool needs_response = false) {
        validate_timestamp(now);
        auto& value = thread(id);
        if (!value.created_at) value.created_at = now;
        value.updated_at = std::max(value.updated_at, now);
        value.settled_at = 0;
        if (needs_response) value.snoozed_until = 0;
    }

    bool can_undo() const noexcept { return !undo_.empty(); }
    bool can_redo() const noexcept { return !redo_.empty(); }
    bool undo() { return replay(undo_, redo_, false); }
    bool redo() { return replay(redo_, undo_, true); }
    bool undo_archive() { return undo(); } // Compatibility: all metadata actions share one session history.
    bool redo_archive() { return redo(); }

    std::vector<std::string> listed_threads(ThreadView view, std::string_view query = {}, std::int64_t now = now_seconds()) const {
        validate_timestamp(now);
        const auto folded_query = workspace_text::fold(query);
        std::vector<const Thread*> matching;
        for (const auto& value : threads) {
            bool shown{};
            switch (view) {
            case ThreadView::trash: shown = value.deleted_at > 0; break;
            case ThreadView::all: shown = !value.deleted_at; break;
            case ThreadView::archived: shown = !value.deleted_at && value.archived; break;
            case ThreadView::snoozed: shown = !value.deleted_at && !value.archived && value.snoozed_until > now; break;
            case ThreadView::settled: shown = !value.deleted_at && !value.archived && is_settled(value); break;
            case ThreadView::inbox: shown = !value.deleted_at && !value.archived && value.snoozed_until <= now && !is_settled(value); break;
            }
            if (!shown) continue;
            auto haystack = workspace_text::fold(value.title + "\n" + value.provider);
            if (value.project_id) haystack += "\n" + workspace_text::fold(project(*value.project_id).name);
            if (folded_query.empty() || haystack.find(folded_query) != std::string::npos) matching.push_back(&value);
        }
        std::stable_sort(matching.begin(), matching.end(), [](const auto* a, const auto* b) {
            return a->pinned != b->pinned ? a->pinned : a->updated_at > b->updated_at;
        });
        std::vector<std::string> result; result.reserve(matching.size());
        for (const auto* value : matching) result.push_back(value->id);
        return result;
    }
    std::vector<std::string> visible_threads(std::string_view query = {}, bool archived = false, std::int64_t now = now_seconds()) const {
        return listed_threads(archived ? ThreadView::archived : ThreadView::inbox, query, now);
    }

    void remember_session(std::string_view thread_id, NativeSession session) {
        auto& value = thread(thread_id);
        if (!known_provider(session.provider) || session.id.empty() || session.acknowledged_messages > value.messages.size()) {
            throw std::invalid_argument("Invalid native session");
        }
        auto at = std::find_if(value.sessions.begin(), value.sessions.end(), [&](const auto& item) { return item.provider == session.provider; });
        if (at == value.sessions.end()) value.sessions.push_back(std::move(session));
        else *at = std::move(session);
    }
    std::vector<Message> missed_messages(std::string_view thread_id, std::string_view provider) const {
        if (!known_provider(provider)) throw std::invalid_argument("Unknown provider");
        const auto& value = thread(thread_id);
        const auto session = std::find_if(value.sessions.begin(), value.sessions.end(), [&](const auto& item) { return item.provider == provider; });
        const auto start = session == value.sessions.end() ? 0 : std::min(session->acknowledged_messages, value.messages.size());
        return {value.messages.begin() + static_cast<std::ptrdiff_t>(start), value.messages.end()};
    }

private:
    enum Field : std::uint32_t { title_field=1, project_field=2, pin_field=4, archive_field=8, snooze_field=16,
        settled_field=32, deleted_field=64, named_field=128 };
    struct Metadata {
        std::string title;
        std::optional<std::string> project_id;
        bool pinned{}, archived{}, titled_by_user{};
        std::int64_t snoozed_until{}, settled_at{}, deleted_at{}, updated_at{};
        bool operator==(const Metadata&) const = default;
    };
    struct ThreadChange { std::string id; Metadata before, after; std::uint32_t fields; };
    struct ProjectChange { std::string id; std::optional<Project> before, after; std::size_t position; };
    struct HistoryEntry { std::vector<ThreadChange> threads; std::optional<ProjectChange> project; };
    using History = std::vector<HistoryEntry>;
    History undo_, redo_;
    static constexpr std::size_t history_limit = 20;

    static Metadata metadata(const Thread& value) {
        return {value.title, value.project_id, value.pinned, value.archived, value.titled_by_user,
            value.snoozed_until, value.settled_at, value.deleted_at, value.updated_at};
    }
    static void apply(Thread& value, Metadata& desired, std::uint32_t fields) noexcept {
        if (fields & title_field) value.title.swap(desired.title);
        if (fields & project_field) value.project_id.swap(desired.project_id);
        if (fields & pin_field) value.pinned = desired.pinned;
        if (fields & archive_field) value.archived = desired.archived;
        if (fields & named_field) value.titled_by_user = desired.titled_by_user;
        if (fields & snooze_field) value.snoozed_until = desired.snoozed_until;
        if (fields & settled_field) value.settled_at = desired.settled_at;
        if (fields & deleted_field) value.deleted_at = desired.deleted_at;
    }
    template<class Operation> void mutate(const std::vector<std::string>& ids, std::uint32_t fields, Operation operation) {
        HistoryEntry entry;
        std::unordered_set<std::string> seen;
        for (const auto& id : ids) {
            const auto& value = thread(id);
            if (!seen.insert(id).second) continue;
            auto before = metadata(value), after = before;
            operation(after);
            if (after != before) entry.threads.push_back({id, std::move(before), std::move(after), fields});
        }
        if (!entry.threads.empty()) record(std::move(entry));
    }
    std::size_t project_position(std::string_view id) const {
        return static_cast<std::size_t>(std::distance(projects.begin(), std::find_if(projects.begin(), projects.end(),
            [&](const auto& value) { return value.id == id; })));
    }
    // All validation, copies and capacity growth precede the no-throw swaps, making a batch atomic.
    void apply_entry(const HistoryEntry& entry, bool forward) {
        std::vector<std::pair<Thread*, Metadata>> prepared; prepared.reserve(entry.threads.size());
        const auto desired_project = entry.project ? (forward ? entry.project->after : entry.project->before) : std::optional<Project>{};
        auto project_copy = desired_project;
        for (const auto& change : entry.threads) {
            auto& value = thread(change.id);
            auto desired = forward ? change.after : change.before;
            if ((change.fields & project_field) && desired.project_id) {
                if (!desired_project || desired_project->id != *desired.project_id) (void)project(*desired.project_id);
            }
            prepared.emplace_back(&value, std::move(desired));
        }
        const auto project_at = entry.project ? project_position(entry.project->id) : projects.size();
        if (entry.project) {
            const auto& expected = forward ? entry.project->before : entry.project->after;
            if (expected.has_value() != (project_at != projects.size())) throw std::logic_error("The project changed since this action");
            if (expected && (projects[project_at].name != expected->name || projects[project_at].path != expected->path)) {
                throw std::logic_error("The project changed since this action");
            }
            if (!desired_project) for (const auto& value : threads) if (value.project_id == std::optional<std::string>(entry.project->id)) {
                if (std::none_of(entry.threads.begin(), entry.threads.end(), [&](const auto& change) {
                        return change.id == value.id && (change.fields & project_field)
                            && (forward ? change.after : change.before).project_id != value.project_id;
                    })) throw std::logic_error("New conversations must be detached before removing this project");
            }
            if (desired_project && project_at == projects.size()) projects.reserve(projects.size() + 1);
            if (!desired_project && project_at == projects.size()) throw std::out_of_range("The project no longer exists");
        }
        if (entry.project && project_copy) {
            if (project_at == projects.size()) projects.insert(projects.begin() + static_cast<std::ptrdiff_t>(std::min(entry.project->position, projects.size())), std::move(*project_copy));
            else std::swap(projects[project_at], *project_copy);
        }
        for (std::size_t i = 0; i < prepared.size(); ++i) apply(*prepared[i].first, prepared[i].second, entry.threads[i].fields);
        if (entry.project && !desired_project) projects.erase(projects.begin() + static_cast<std::ptrdiff_t>(project_at));
    }
    void record(HistoryEntry entry) {
        // Keep the entry separate from history until applying it succeeds. Reserve before mutating the workspace.
        undo_.reserve(undo_.size() + 1);
        apply_entry(entry, true);
        undo_.push_back(std::move(entry));
        if (undo_.size() > history_limit) undo_.erase(undo_.begin());
        redo_.clear();
    }
    bool replay(History& from, History& to, bool forward) {
        if (from.empty()) return false;
        to.reserve(to.size() + 1);
        apply_entry(from.back(), forward);
        to.push_back(std::move(from.back())); from.pop_back();
        return true;
    }
};
} // namespace coincide
