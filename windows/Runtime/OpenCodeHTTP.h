#pragma once
#include <windows.h>
#include <winhttp.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <deque>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#pragma comment(lib, "winhttp.lib")

namespace coincide {
// One asynchronous, direct-loopback request. Callback state outlives cancellation until WinHTTP's
// final HANDLE_CLOSING notification; no callback holds a session/UI/COM object or a borrowed buffer.
class OpenCodeHTTP {
public:
    struct Snapshot {
        unsigned status{}; bool headers{}, done{}; DWORD error{};
        std::string body; std::deque<std::string> chunks;
        std::chrono::steady_clock::time_point activity;
    };
    OpenCodeHTTP(unsigned short port, const std::wstring& authorization, const std::wstring& method,
            const std::wstring& path, std::string body = {}, bool stream = false, int timeout = 45000)
        : state_(std::make_shared<State>()) {
        auto& state = *state_; state.stream = stream; state.body = std::move(body);
        if (!port || path.empty() || path.front() != L'/' || path.find_first_of(L"\r\n") != std::wstring::npos || state.body.size() > limit)
            throw std::invalid_argument("Invalid OpenCode loopback request");
        state.session = WinHttpOpen(L"Coincide/Windows", WINHTTP_ACCESS_TYPE_NO_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, WINHTTP_FLAG_ASYNC);
        if (!state.session) throw std::runtime_error("Could not initialize the Windows HTTP client");
        if (!WinHttpSetTimeouts(state.session, 5000, 5000, 10000, timeout)) throw std::runtime_error("Could not set OpenCode request timeouts");
        state.connection = WinHttpConnect(state.session, L"127.0.0.1", port, 0);
        if (!state.connection) throw std::runtime_error("Could not connect to the OpenCode loopback server");
        state.request = WinHttpOpenRequest(state.connection, method.c_str(), path.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
        if (!state.request) throw std::runtime_error("Could not create an OpenCode HTTP request");
        DWORD disabled = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_COOKIES | WINHTTP_DISABLE_AUTHENTICATION;
        if (!WinHttpSetOption(state.request, WINHTTP_OPTION_DISABLE_FEATURE, &disabled, sizeof(disabled))) throw std::runtime_error("Could not isolate the OpenCode HTTP request");
        const auto headers = L"Authorization: " + authorization + L"\r\nAccept: " + (stream ? L"text/event-stream" : L"application/json")
            + L"\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n";
        if (!WinHttpAddRequestHeaders(state.request, headers.c_str(), static_cast<DWORD>(headers.size()), WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE))
            throw std::runtime_error("Could not authorize the OpenCode loopback request");
        if (WinHttpSetStatusCallback(state.request, callback, WINHTTP_CALLBACK_FLAG_ALL_COMPLETIONS | WINHTTP_CALLBACK_FLAG_HANDLES, 0) == WINHTTP_INVALID_STATUS_CALLBACK)
            throw std::runtime_error("Could not initialize OpenCode asynchronous HTTP");
        auto* context = new std::shared_ptr<State>(state_);
        auto value = reinterpret_cast<DWORD_PTR>(context);
        if (!WinHttpSetOption(state.request, WINHTTP_OPTION_CONTEXT_VALUE, &value, sizeof(value))) {delete context; throw std::runtime_error("Could not bind OpenCode HTTP lifetime");}
        state.bound = true;
        // An asynchronous completion may arrive before SendRequest returns.
        std::lock_guard lock(state.mutex);
        if (!WinHttpSendRequest(state.request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                state.body.empty() ? WINHTTP_NO_REQUEST_DATA : state.body.data(), static_cast<DWORD>(state.body.size()), static_cast<DWORD>(state.body.size()), value)) {
            state.error = GetLastError(); state.done = true;
        }
    }
    ~OpenCodeHTTP() {cancel();}
    OpenCodeHTTP(const OpenCodeHTTP&) = delete;
    OpenCodeHTTP& operator=(const OpenCodeHTTP&) = delete;
    Snapshot take() {
        std::lock_guard lock(state_->mutex); Snapshot result;
        result.status = state_->status; result.headers = state_->headers; result.done = state_->done; result.error = state_->error; result.activity = state_->activity;
        result.chunks.swap(state_->chunks); state_->queued = 0;
        if (result.done) result.body = state_->response; return result;
    }
    void cancel() noexcept {
        if (!state_) return;
        std::lock_guard lock(state_->mutex); state_->stopping = true;
        if (auto request = std::exchange(state_->request, nullptr)) WinHttpCloseHandle(request);
    }
private:
    static constexpr std::size_t limit = 64 * 1024 * 1024;
    struct State {
        std::recursive_mutex mutex;
        HINTERNET session{}, connection{}, request{};
        std::string body, response;
        std::deque<std::string> chunks;
        std::array<char, 65536> buffer{};
        std::size_t queued{};
        unsigned status{}; DWORD error{};
        bool stream{}, headers{}, done{}, stopping{}, bound{};
        std::chrono::steady_clock::time_point activity{std::chrono::steady_clock::now()};
        ~State() {
            // A bound request retains State until HANDLE_CLOSING. Constructor failures before the
            // context was bound have no outstanding asynchronous operation and can close directly.
            if (request) WinHttpCloseHandle(request);
            if (connection) WinHttpCloseHandle(connection);
            if (session) WinHttpCloseHandle(session);
        }
    };
    std::shared_ptr<State> state_;
    static void CALLBACK callback(HINTERNET, DWORD_PTR context, DWORD event, void* data, DWORD count) noexcept {
        if (!context) return;
        auto* holder = reinterpret_cast<std::shared_ptr<State>*>(context); auto state = *holder;
        if (event == WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING) {delete holder; return;}
        std::lock_guard lock(state->mutex);
        if (state->stopping || state->done || !state->request) return;
        try {
            const auto fail = [&](DWORD error) {state->error = error; state->done = true;};
            const auto read = [&] {if (!WinHttpQueryDataAvailable(state->request, nullptr)) fail(GetLastError());};
            switch (event) {
            case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE:
                if (!WinHttpReceiveResponse(state->request, nullptr)) fail(GetLastError()); break;
            case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE: {
                DWORD status{}, bytes = sizeof(status);
                if (!WinHttpQueryHeaders(state->request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status, &bytes, WINHTTP_NO_HEADER_INDEX)) {fail(GetLastError()); break;}
                state->status = status; state->headers = true; state->activity = std::chrono::steady_clock::now();
                if (state->stream && status == 200) {
                    wchar_t content_type[256]{}; bytes = sizeof(content_type);
                    if (!WinHttpQueryHeaders(state->request, WINHTTP_QUERY_CONTENT_TYPE, WINHTTP_HEADER_NAME_BY_INDEX, content_type, &bytes, WINHTTP_NO_HEADER_INDEX)
                            || std::wstring_view(content_type).substr(0, 17) != L"text/event-stream") {fail(ERROR_WINHTTP_INVALID_SERVER_RESPONSE); break;}
                }
                read(); break;
            }
            case WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE: {
                if (!data || count < sizeof(DWORD)) {fail(ERROR_WINHTTP_INVALID_SERVER_RESPONSE); break;}
                const auto available = *static_cast<DWORD*>(data);
                if (!available) {state->done = true; break;}
                if (!WinHttpReadData(state->request, state->buffer.data(), std::min<DWORD>(available, static_cast<DWORD>(state->buffer.size())), nullptr)) fail(GetLastError());
                break;
            }
            case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
                state->activity = std::chrono::steady_clock::now();
                if (!count) {state->done = true; break;}
                if (state->stream && state->status == 200) {
                    if (count > limit - state->queued || state->chunks.size() >= 65536) {fail(ERROR_NOT_ENOUGH_MEMORY); break;}
                    state->queued += count; state->chunks.emplace_back(static_cast<const char*>(data), count);
                } else {
                    if (count > limit - state->response.size()) {fail(ERROR_NOT_ENOUGH_MEMORY); break;}
                    state->response.append(static_cast<const char*>(data), count);
                }
                read(); break;
            case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR:
                fail(data && count >= sizeof(WINHTTP_ASYNC_RESULT) ? static_cast<WINHTTP_ASYNC_RESULT*>(data)->dwError : ERROR_WINHTTP_INTERNAL_ERROR); break;
            default: break;
            }
        } catch (...) {state->error = ERROR_NOT_ENOUGH_MEMORY; state->done = true;}
    }
};

// SSE boundaries are independent of HTTP reads and UTF-8 code points. Validate complete events only.
class OpenCodeSSE {
public:
    explicit OpenCodeSSE(std::size_t limit = 8 * 1024 * 1024) : limit_(limit) {}
    template<class F> void consume(std::string_view bytes, F&& emit) {
        for (const auto ch : bytes) {
            if (skip_lf_) {skip_lf_ = false; if (ch == '\n') continue;}
            if (ch == '\r' || ch == '\n') {line(emit); skip_lf_ = ch == '\r';}
            else {if (line_.size() >= limit_) throw std::length_error("OpenCode SSE line exceeds its limit"); line_ += ch;}
        }
    }
    static bool valid_utf8(const std::string& value) {
        return value.empty() || (value.size() <= static_cast<std::size_t>(INT_MAX)
            && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0) > 0);
    }
private:
    std::size_t limit_;
    std::string line_, event_;
    bool first_{true}, skip_lf_{};
    template<class F> void line(F& emit) {
        if (first_) {first_ = false; if (line_.starts_with("\xef\xbb\xbf")) line_.erase(0, 3);}
        if (line_.empty()) {
            if (!event_.empty()) {
                event_.pop_back(); auto value = std::move(event_); event_.clear();
                if (!valid_utf8(value)) throw std::runtime_error("OpenCode emitted invalid UTF-8"); emit(std::move(value));
            }
        } else if (line_.starts_with("data:") || line_ == "data") {
            auto value = std::string_view(line_).substr(std::min<std::size_t>(5, line_.size()));
            if (value.starts_with(' ')) value.remove_prefix(1);
            if (value.size() >= limit_ - event_.size()) throw std::length_error("OpenCode SSE event exceeds its limit");
            event_.append(value); event_ += '\n';
        }
        line_.clear();
    }
};
} // namespace coincide
