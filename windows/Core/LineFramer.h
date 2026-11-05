#pragma once
#include <functional>
#include <stdexcept>
#include <string>
#include <string_view>

namespace coincide {
// Child-process stdout is a byte stream: neither ReadFile boundaries nor UTF-8 boundaries are lines.
class LineFramer {
public:
    explicit LineFramer(std::size_t limit = 256 * 1024 * 1024) : limit_(limit) {}

    template<class F> void consume(std::string_view bytes, F&& emit) {
        for (;;) {
            const auto newline = bytes.find('\n');
            const auto count = newline == std::string_view::npos ? bytes.size() : newline;
            if (count > limit_ - pending_.size()) throw std::length_error("Agent output exceeded the line limit");
            pending_.append(bytes.substr(0, count));
            if (newline == std::string_view::npos) return;
            if (!pending_.empty() && pending_.back() == '\r') pending_.pop_back();
            auto line = std::move(pending_); pending_.clear();
            emit(std::move(line));
            bytes.remove_prefix(newline + 1);
        }
    }

    template<class F> void finish(F&& emit) {
        if (pending_.empty()) return;
        auto line = std::move(pending_); pending_.clear();
        if (!line.empty() && line.back() == '\r') line.pop_back();
        emit(std::move(line));
    }
private:
    std::size_t limit_;
    std::string pending_;
};

// CommandLineToArgvW/MSVC escaping; user messages go through stdin, never through this command line.
inline std::wstring quote_windows_argument(std::wstring_view value) {
    std::wstring result = L"\"";
    std::size_t slashes{};
    for (const auto ch : value) {
        if (ch == L'\\') { ++slashes; continue; }
        if (ch == L'\"') {
            result.append(slashes * 2 + 1, L'\\');
            result += L'\"';
        } else {
            result.append(slashes, L'\\');
            result += ch;
        }
        slashes = 0;
    }
    result.append(slashes * 2, L'\\');
    result += L'\"';
    return result;
}
} // namespace coincide
