#pragma once
#include <windows.h>
#include "../Core/LineFramer.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <map>
#include <mutex>
#include <optional>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

namespace coincide {
class NativeHandle {
public:
    NativeHandle() = default;
    explicit NativeHandle(HANDLE value) : value_(value) {}
    ~NativeHandle() { reset(); }
    NativeHandle(const NativeHandle&) = delete;
    NativeHandle& operator=(const NativeHandle&) = delete;
    NativeHandle(NativeHandle&& other) noexcept : value_(other.release()) {}
    NativeHandle& operator=(NativeHandle&& other) noexcept { if (this != &other) reset(other.release()); return *this; }
    HANDLE get() const { return value_; }
    HANDLE release() { return std::exchange(value_, nullptr); }
    void reset(HANDLE value = nullptr) { if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_); value_ = value; }
private:
    HANDLE value_{};
};

// Owned by a session/agent host, not by a transcript row. This class never launches through cmd.exe or a shell.
// Callbacks run on a reader thread and must return promptly; the host dispatches events to the UI separately.
// Lifecycle calls (wait/stop/destruction) are serialized on the owning host thread, not inside reader callbacks.
class WindowsProcess {
public:
    struct Exit { DWORD status{}; std::string stderr_tail; std::string channel_error; bool stdout_truncated{}; };
    using OnLine = std::function<void(std::string)>;
    using OnBytes = std::function<void(std::string_view)>;
    // A null value removes a variable in the child only; an empty string remains an explicit empty value.
    using Environment = std::vector<std::pair<std::wstring, std::optional<std::wstring>>>;

    static std::unique_ptr<WindowsProcess> start(const std::filesystem::path& executable,
            const std::vector<std::wstring>& arguments, const std::filesystem::path& cwd, OnLine on_line,
            const Environment& environment = {}) {
        auto result = std::unique_ptr<WindowsProcess>(new WindowsProcess);
        result->on_line_ = std::move(on_line);
        result->launch(executable, arguments, cwd, environment);
        try {
            result->stdout_reader_ = std::thread([p=result.get()] { p->read_stdout(); });
            result->stderr_reader_ = std::thread([p=result.get()] { p->read_stderr(); });
        } catch (...) {
            result->stop();
            throw;
        }
        return result;
    }

    // Git's NUL-delimited paths and binary previews must not pass through JSONL/CRLF normalization.
    // The callback must consume the view before returning. Exceeding the cap terminates only this job.
    static std::unique_ptr<WindowsProcess> start_bytes(const std::filesystem::path& executable,
            const std::vector<std::wstring>& arguments, const std::filesystem::path& cwd,
            OnBytes on_bytes, std::size_t output_limit = 16 * 1024 * 1024,
            const Environment& environment = {}, bool merge_stderr = false) {
        if (!output_limit) throw std::invalid_argument("A raw process output limit is required");
        auto result = std::unique_ptr<WindowsProcess>(new WindowsProcess);
        result->on_bytes_ = std::move(on_bytes);
        result->raw_output_ = true; result->output_limit_ = output_limit;
        result->launch(executable, arguments, cwd, environment, merge_stderr);
        try {
            result->stdout_reader_ = std::thread([p=result.get()] {p->read_stdout();});
            if (!merge_stderr) result->stderr_reader_ = std::thread([p=result.get()] {p->read_stderr();});
        } catch (...) {result->stop(); throw;}
        return result;
    }

    ~WindowsProcess() { stop(); }
    WindowsProcess(const WindowsProcess&) = delete;
    WindowsProcess& operator=(const WindowsProcess&) = delete;

    void write_line(std::string_view line) {
        if (line.find('\n') != std::string_view::npos || line.find('\r') != std::string_view::npos) {
            throw std::invalid_argument("Process messages must be a single framed line");
        }
        std::string bytes(line); bytes += '\n';
        write_input(bytes);
    }

    void write_bytes(std::string_view bytes) {
        if (!raw_output_) throw std::logic_error("Raw input is only available to a raw process");
        write_input(bytes);
    }

private:
    void write_input(std::string_view bytes) {
        std::lock_guard lock(writer_);
        if (!stdin_write_.get()) throw std::runtime_error("The agent input channel is closed");
        std::size_t offset{};
        while (offset < bytes.size()) {
            DWORD written{};
            const auto count = static_cast<DWORD>(std::min<std::size_t>(bytes.size() - offset, 64 * 1024));
            if (!WriteFile(stdin_write_.get(), bytes.data() + offset, count, &written, nullptr)) fail();
            if (!written) throw std::runtime_error("The agent input channel stopped accepting data");
            offset += written;
        }
    }

public:
    void close_input() { std::lock_guard lock(writer_); stdin_write_.reset(); }

    std::optional<Exit> wait(std::chrono::milliseconds timeout) {
        if (completed_) return completed_;
        const auto delay = static_cast<DWORD>(std::clamp<std::int64_t>(timeout.count(), 0, MAXDWORD - 1));
        const auto status = WaitForSingleObject(process_.get(), delay);
        if (status == WAIT_TIMEOUT) return std::nullopt;
        if (status != WAIT_OBJECT_0) fail();
        DWORD exit{}; if (!GetExitCodeProcess(process_.get(), &exit)) fail();
        // The session ended. Close its descendant processes so inherited output pipes cannot remain open forever.
        TerminateJobObject(job_.get(), ERROR_PROCESS_ABORTED);
        join_readers();
        std::lock_guard lock(output_);
        completed_ = Exit{exit, stderr_tail_, channel_error_, stdout_truncated_};
        return completed_;
    }

    void stop() noexcept {
        if (job_.get()) TerminateJobObject(job_.get(), ERROR_CANCELLED);
        if (process_.get()) WaitForSingleObject(process_.get(), 2000);
        join_readers();
        // A blocked writer is released by terminating the job before taking its mutex.
        close_input();
    }

private:
    NativeHandle process_, job_, stdin_write_, stdout_read_, stderr_read_;
    std::thread stdout_reader_, stderr_reader_;
    std::mutex writer_, output_;
    OnLine on_line_;
    OnBytes on_bytes_;
    bool raw_output_{}, stdout_truncated_{};
    std::size_t output_limit_{};
    std::string stderr_tail_, channel_error_;
    std::optional<Exit> completed_;
    WindowsProcess() = default;

    [[noreturn]] static void fail() { throw std::system_error(static_cast<int>(GetLastError()), std::system_category()); }
    static void pipe(NativeHandle& read, NativeHandle& write) {
        SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
        HANDLE r{}, w{};
        if (!CreatePipe(&r, &w, &security, 0)) fail();
        read.reset(r); write.reset(w);
    }

    struct EnvironmentOrder {
        bool operator()(const std::wstring& a, const std::wstring& b) const {
            return CompareStringOrdinal(a.c_str(), static_cast<int>(a.size()), b.c_str(),
                static_cast<int>(b.size()), TRUE) == CSTR_LESS_THAN;
        }
    };
    static std::vector<wchar_t> child_environment(const Environment& overrides) {
        std::map<std::wstring, std::wstring, EnvironmentOrder> values;
        auto inherited = GetEnvironmentStringsW();
        if (!inherited) fail();
        struct ReleaseEnvironment {wchar_t* value; ~ReleaseEnvironment(){FreeEnvironmentStringsW(value);}} release{inherited};
        for (auto at = inherited; *at; at += wcslen(at) + 1) {
            const std::wstring entry(at);
            const auto separator = entry.find(L'=', entry.front() == L'=' ? 1 : 0);
            if (separator != std::wstring::npos) values.insert_or_assign(entry.substr(0, separator), entry.substr(separator + 1));
        }
        for (const auto& [key, value] : overrides) {
            if (key.empty() || key.find_first_of(L"=\0", 0, 2) != std::wstring::npos
                    || (value && value->find(L'\0') != std::wstring::npos)) throw std::invalid_argument("Invalid child environment override");
            if (value) values.insert_or_assign(key, *value);
            else values.erase(key);
        }
        std::vector<wchar_t> block;
        for (const auto& [key, value] : values) {
            block.insert(block.end(), key.begin(), key.end()); block.push_back(L'=');
            block.insert(block.end(), value.begin(), value.end()); block.push_back(L'\0');
        }
        block.push_back(L'\0');
        return block;
    }

    void launch(const std::filesystem::path& executable, const std::vector<std::wstring>& arguments,
            const std::filesystem::path& cwd, const Environment& overrides, bool merge_stderr = false) {
        NativeHandle child_input, child_output, child_error;
        pipe(child_input, stdin_write_); pipe(stdout_read_, child_output);
        if (!merge_stderr) pipe(stderr_read_, child_error);
        for (const auto handle : {stdin_write_.get(), stdout_read_.get(), stderr_read_.get()}) {
            if (handle && !SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0)) fail();
        }
        job_.reset(CreateJobObjectW(nullptr, nullptr));
        if (!job_.get()) fail();
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!SetInformationJobObject(job_.get(), JobObjectExtendedLimitInformation, &limits, sizeof(limits))) fail();

        SIZE_T size{};
        InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
        std::vector<std::byte> bytes(size);
        auto attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(bytes.data());
        if (!InitializeProcThreadAttributeList(attributes, 1, 0, &size)) fail();
        struct DeleteAttributes {
            LPPROC_THREAD_ATTRIBUTE_LIST value;
            ~DeleteAttributes() { DeleteProcThreadAttributeList(value); }
        } cleanup{attributes};
        std::vector<HANDLE> inherited{child_input.get(), child_output.get()};
        if (!merge_stderr) inherited.push_back(child_error.get());
        if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited.data(), inherited.size() * sizeof(HANDLE), nullptr, nullptr)) fail();

        STARTUPINFOEXW startup{};
        startup.StartupInfo.cb = sizeof(startup);
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = child_input.get();
        startup.StartupInfo.hStdOutput = child_output.get();
        startup.StartupInfo.hStdError = merge_stderr ? child_output.get() : child_error.get();
        startup.lpAttributeList = attributes;
        auto command = quote_windows_argument(executable.wstring());
        for (const auto& argument : arguments) command += L" " + quote_windows_argument(argument);
        PROCESS_INFORMATION process{};
        auto environment = overrides.empty() ? std::vector<wchar_t>{} : child_environment(overrides);
        if (!CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, TRUE,
                EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
                environment.empty() ? nullptr : environment.data(), cwd.c_str(), &startup.StartupInfo, &process)) fail();
        process_.reset(process.hProcess);
        NativeHandle thread(process.hThread);
        if (!AssignProcessToJobObject(job_.get(), process_.get())) {
            const auto error = GetLastError();
            TerminateProcess(process_.get(), ERROR_CANCELLED);
            WaitForSingleObject(process_.get(), 2000);
            throw std::system_error(static_cast<int>(error), std::system_category());
        }
        if (ResumeThread(thread.get()) == static_cast<DWORD>(-1)) fail();
    }

    void channel_error(const char* message) noexcept {
        { std::lock_guard lock(output_); channel_error_ = message; }
        if (job_.get()) TerminateJobObject(job_.get(), ERROR_BAD_FORMAT);
    }

    void read_stdout() noexcept {
        try {
            LineFramer lines;
            std::array<char, 8192> buffer{};
            std::size_t received{};
            DWORD count{};
            while (ReadFile(stdout_read_.get(), buffer.data(), static_cast<DWORD>(buffer.size()), &count, nullptr) && count) {
                if (raw_output_) {
                    const auto accepted = std::min<std::size_t>(count, output_limit_ - received);
                    if (accepted && on_bytes_) on_bytes_(std::string_view(buffer.data(), accepted));
                    received += accepted;
                    if (accepted != count) {
                        {std::lock_guard lock(output_); stdout_truncated_ = true;}
                        TerminateJobObject(job_.get(), ERROR_BUFFER_OVERFLOW);
                        return;
                    }
                } else lines.consume(std::string_view(buffer.data(), count), on_line_);
            }
            if (!raw_output_) lines.finish(on_line_);
        } catch (...) { channel_error("The agent output channel failed"); }
    }

    void read_stderr() noexcept {
        try {
            std::array<char, 8192> buffer{};
            DWORD count{};
            while (ReadFile(stderr_read_.get(), buffer.data(), static_cast<DWORD>(buffer.size()), &count, nullptr) && count) {
                std::lock_guard lock(output_);
                stderr_tail_.append(buffer.data(), count);
                if (stderr_tail_.size() > 8192) stderr_tail_.erase(0, stderr_tail_.size() - 8192);
            }
        } catch (...) { channel_error("The agent error channel failed"); }
    }

    void join_readers() noexcept {
        for (auto* reader : {&stdout_reader_, &stderr_reader_}) {
            if (!reader->joinable()) continue;
            if (WaitForSingleObject(reader->native_handle(), 2000) == WAIT_TIMEOUT) CancelSynchronousIo(reader->native_handle());
            reader->join();
        }
    }
};
} // namespace coincide
