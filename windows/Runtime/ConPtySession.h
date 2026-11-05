#pragma once
#include "WindowsProcess.h"
#include <condition_variable>
#include <deque>
#include <limits>

namespace coincide {
struct TerminalLaunch {
    std::filesystem::path executable;
    std::vector<std::wstring> arguments;
    std::filesystem::path cwd;
    std::int16_t columns{100}, rows{30};
    std::size_t output_limit{4 * 1024 * 1024}, input_limit{1024 * 1024};
};
struct TerminalEvent {
    enum class Kind { output, resized, exited, error };
    Kind kind;
    std::string bytes;
    DWORD exit_code{};
    std::int16_t columns{}, rows{};
};

// ConPTY always exchanges UTF-8/VT bytes. Readers and writers are independent; the owner consumes
// events on its UI thread and decodes across chunk boundaries. No shell is inserted by this host.
class ConPtySession {
public:
    static std::unique_ptr<ConPtySession> start(TerminalLaunch launch) {
        auto result = std::unique_ptr<ConPtySession>(new ConPtySession(std::move(launch)));
        result->launch();
        return result;
    }
    ~ConPtySession() { shutdown(); }
    ConPtySession(const ConPtySession&) = delete;
    ConPtySession& operator=(const ConPtySession&) = delete;

    bool write(std::string_view bytes) {
        std::lock_guard lock(input_mutex_);
        if (stopping_ || !running_) return false;
        if (bytes.empty()) return true;
        if (bytes.size() > options_.input_limit - input_bytes_) return false;
        if (!input_.empty() && input_.back().size() + bytes.size() <= 64 * 1024) input_.back().append(bytes);
        else {
            if (input_.size() >= event_limit) return false;
            input_.emplace_back(bytes);
        }
        input_bytes_ += bytes.size(); input_cv_.notify_one(); return true;
    }
    // Coalesce resize requests and perform the OS call on the monitor thread, never on the UI thread.
    bool resize(std::int16_t columns, std::int16_t rows) {
        dimensions(columns, rows);
        std::lock_guard lock(resize_mutex_);
        if (stopping_ || !running_) return false;
        pending_size_ = COORD{columns, rows};
        SetEvent(resize_event_.get()); return true;
    }
    std::vector<TerminalEvent> take_events() {
        std::lock_guard lock(output_mutex_);
        std::vector<TerminalEvent> result; result.swap(events_); output_bytes_ = 0; return result;
    }
    bool running() const noexcept { return running_; }
    DWORD process_id() const noexcept { return process_id_; }
    void stop() noexcept {
        // Pair the predicate transition with write_input's condition-variable mutex.
        // An atomic alone permits notify to occur between its predicate check and wait.
        { std::lock_guard lock(input_mutex_); stopping_ = true; }
        // Never retain input_mutex_ across OS calls or the finish()/shutdown() joins.
        if (stop_event_.get()) SetEvent(stop_event_.get());
        input_cv_.notify_all();
    }
    bool wait_for_exit(std::chrono::milliseconds timeout) {
        std::unique_lock lock(finish_mutex_);
        return finish_cv_.wait_for(lock, timeout, [&] { return finished_.load(); });
    }
    // Lifecycle calls are serialized by the owner. stop/write/resize/take_events are thread-safe.
    void shutdown() noexcept {
        stop();
        if (monitor_.joinable()) monitor_.join();
        else if (!finished_) finish();
    }

private:
    TerminalLaunch options_;
    NativeHandle process_, job_, input_write_, output_read_, stop_event_, resize_event_;
    HPCON console_{};
    DWORD process_id_{};
    std::atomic<bool> running_{}, stopping_{}, finished_{}, error_reported_{};
    std::thread reader_, writer_, monitor_;
    std::mutex input_mutex_, output_mutex_, resize_mutex_, finish_mutex_;
    std::condition_variable input_cv_, finish_cv_;
    std::deque<std::string> input_;
    std::vector<TerminalEvent> events_;
    std::size_t input_bytes_{}, output_bytes_{};
    std::optional<COORD> pending_size_;
    bool output_overflow_{};
    static constexpr std::size_t event_limit = 4096;

    explicit ConPtySession(TerminalLaunch options) : options_(std::move(options)) {
        dimensions(options_.columns, options_.rows);
        if (!options_.output_limit || options_.output_limit > 64ULL * 1024 * 1024 || !options_.input_limit
                || options_.input_limit > 16ULL * 1024 * 1024) throw std::invalid_argument("Invalid terminal buffer limit");
        if (options_.executable.empty() || options_.cwd.empty() || options_.executable.wstring().find(L'\0') != std::wstring::npos
                || options_.cwd.wstring().find(L'\0') != std::wstring::npos) throw std::invalid_argument("Terminal executable and folder are required");
        for (const auto& argument : options_.arguments) if (argument.find(L'\0') != std::wstring::npos) {
            throw std::invalid_argument("Terminal arguments cannot contain NUL characters");
        }
    }
    static void dimensions(std::int16_t columns, std::int16_t rows) {
        if (columns <= 0 || rows <= 0) throw std::invalid_argument("Terminal dimensions must be positive");
    }
    [[noreturn]] static void fail() { throw std::system_error(static_cast<int>(GetLastError()), std::system_category()); }
    static void check(HRESULT result) {
        if (FAILED(result)) throw std::system_error(static_cast<int>(result), std::system_category());
    }
    static void pipe(NativeHandle& read, NativeHandle& write) {
        HANDLE r{}, w{};
        if (!CreatePipe(&r, &w, nullptr, 0)) fail();
        read.reset(r); write.reset(w);
    }
    void launch() {
        stop_event_.reset(CreateEventW(nullptr, TRUE, FALSE, nullptr));
        resize_event_.reset(CreateEventW(nullptr, FALSE, FALSE, nullptr));
        if (!stop_event_.get() || !resize_event_.get()) fail();
        job_.reset(CreateJobObjectW(nullptr, nullptr));
        if (!job_.get()) fail();
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (!SetInformationJobObject(job_.get(), JobObjectExtendedLimitInformation, &limits, sizeof(limits))) fail();

        NativeHandle input_read, output_write;
        pipe(input_read, input_write_); pipe(output_read_, output_write);
        check(CreatePseudoConsole({options_.columns, options_.rows}, input_read.get(), output_write.get(), 0, &console_));
        // Start draining before any later allocation/process-launch failure can require closing the console.
        reader_ = std::thread([this] { read_output(); });
        writer_ = std::thread([this] { write_input(); });

        SIZE_T size{}; InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
        std::vector<std::byte> storage(size);
        auto attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
        if (!InitializeProcThreadAttributeList(attributes, 1, 0, &size)) fail();
        struct DeleteAttributes { LPPROC_THREAD_ATTRIBUTE_LIST value; ~DeleteAttributes() { DeleteProcThreadAttributeList(value); } } cleanup{attributes};
        if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, console_, sizeof(console_), nullptr, nullptr)) fail();
        STARTUPINFOEXW startup{}; startup.StartupInfo.cb = sizeof(startup); startup.lpAttributeList = attributes;
        auto command = quote_windows_argument(options_.executable.wstring());
        for (const auto& argument : options_.arguments) command += L" " + quote_windows_argument(argument);
        if (command.size() >= 32767) throw std::invalid_argument("The terminal command line is too long");
        PROCESS_INFORMATION process{};
        if (!CreateProcessW(options_.executable.c_str(), command.data(), nullptr, nullptr, FALSE,
                EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT,
                nullptr, options_.cwd.c_str(), &startup.StartupInfo, &process)) fail();
        process_.reset(process.hProcess); process_id_ = process.dwProcessId; NativeHandle thread(process.hThread);
        if (!AssignProcessToJobObject(job_.get(), process_.get())) {
            const auto error = GetLastError(); TerminateProcess(process_.get(), ERROR_CANCELLED);
            throw std::system_error(static_cast<int>(error), std::system_category());
        }
        running_ = true;
        if (ResumeThread(thread.get()) == static_cast<DWORD>(-1)) fail();
        // These copies must close before shutdown so EOF can be detected on the host's pipe ends.
        input_read.reset(); output_write.reset();
        monitor_ = std::thread([this] { monitor(); });
    }
    void signal_error(const char* message) noexcept {
        stop();
        if (error_reported_.exchange(true)) return;
        try { std::lock_guard lock(output_mutex_); events_.push_back({TerminalEvent::Kind::error, message}); } catch (...) { }
    }
    void output(std::string_view bytes) {
        bool overflow{};
        {
            std::lock_guard lock(output_mutex_);
            if (output_overflow_) return; // Continue draining the pipe without growing memory during teardown.
            if (bytes.size() > options_.output_limit - output_bytes_ || events_.size() >= event_limit) {
                output_overflow_ = overflow = true;
            } else {
                if (!events_.empty() && events_.back().kind == TerminalEvent::Kind::output
                        && events_.back().bytes.size() + bytes.size() <= 64 * 1024) events_.back().bytes.append(bytes);
                else events_.push_back({TerminalEvent::Kind::output, std::string(bytes)});
                output_bytes_ += bytes.size();
            }
        }
        if (overflow) signal_error("Terminal output exceeded the unread buffer limit; its owned session was stopped.");
    }
    void read_output() noexcept {
        try {
            std::array<char, 8192> buffer{};
            for (;;) {
                DWORD count{};
                if (!ReadFile(output_read_.get(), buffer.data(), static_cast<DWORD>(buffer.size()), &count, nullptr)) {
                    const auto error = GetLastError();
                    if (error != ERROR_BROKEN_PIPE && error != ERROR_OPERATION_ABORTED && error != ERROR_HANDLE_EOF) {
                        signal_error("The terminal output pipe failed.");
                    }
                    break;
                }
                if (!count) break;
                output(std::string_view(buffer.data(), count));
            }
        } catch (...) { signal_error("The terminal output reader failed."); }
    }
    void write_input() noexcept {
        try {
            for (;;) {
                std::string bytes;
                {
                    std::unique_lock lock(input_mutex_);
                    input_cv_.wait(lock, [&] { return stopping_ || !input_.empty(); });
                    if (stopping_) return;
                    bytes = std::move(input_.front()); input_.pop_front();
                }
                std::size_t offset{};
                while (offset < bytes.size() && !stopping_) {
                    DWORD written{};
                    const auto count = static_cast<DWORD>(std::min<std::size_t>(bytes.size() - offset, 64 * 1024));
                    if (!WriteFile(input_write_.get(), bytes.data() + offset, count, &written, nullptr) || !written) {
                        if (!stopping_) signal_error("The terminal input pipe failed.");
                        return;
                    }
                    offset += written;
                }
                std::lock_guard lock(input_mutex_); input_bytes_ -= bytes.size();
            }
        } catch (...) { signal_error("The terminal input writer failed."); }
    }
    void monitor() noexcept {
        try {
            const HANDLE handles[]{process_.get(), stop_event_.get(), resize_event_.get()};
            for (;;) {
                const auto result = WaitForMultipleObjects(3, handles, FALSE, INFINITE);
                if (result == WAIT_OBJECT_0 || result == WAIT_OBJECT_0 + 1) break;
                if (result != WAIT_OBJECT_0 + 2) { signal_error("The terminal process monitor failed."); break; }
                std::optional<COORD> size;
                { std::lock_guard lock(resize_mutex_); size.swap(pending_size_); }
                if (stopping_) break;
                if (!size) continue;
                if (FAILED(ResizePseudoConsole(console_, *size))) { signal_error("The terminal could not be resized."); break; }
                bool overflow{};
                {
                    std::lock_guard lock(output_mutex_);
                    if (!events_.empty() && events_.back().kind == TerminalEvent::Kind::resized) {
                        events_.back().columns = size->X; events_.back().rows = size->Y;
                    } else if (events_.size() < event_limit) events_.push_back({TerminalEvent::Kind::resized, {}, 0, size->X, size->Y});
                    else overflow = true;
                }
                if (overflow) { signal_error("The terminal event queue is full."); break; }
            }
        } catch (...) { signal_error("The terminal process monitor failed."); }
        finish();
    }
    static void join_io(std::thread& thread) noexcept {
        if (!thread.joinable()) return;
        if (WaitForSingleObject(thread.native_handle(), 2000) == WAIT_TIMEOUT) CancelSynchronousIo(thread.native_handle());
        thread.join();
    }
    void finish() noexcept {
        running_ = false; stop();
        if (job_.get()) TerminateJobObject(job_.get(), ERROR_CANCELLED);
        DWORD exit = ERROR_CANCELLED;
        if (process_.get()) {
            if (WaitForSingleObject(process_.get(), 2000) == WAIT_TIMEOUT) {
                TerminateProcess(process_.get(), ERROR_CANCELLED); WaitForSingleObject(process_.get(), 2000);
            }
            DWORD code{}; if (GetExitCodeProcess(process_.get(), &code)) exit = code;
        }
        join_io(writer_); input_write_.reset();
        // Older Windows versions can wait here for the final VT frame; the reader remains alive and drains it.
        if (!reader_.joinable()) output_read_.reset();
        if (console_) { ClosePseudoConsole(console_); console_ = nullptr; }
        join_io(reader_); output_read_.reset();
        { std::lock_guard lock(input_mutex_); input_.clear(); input_bytes_ = 0; }
        try { std::lock_guard lock(output_mutex_); events_.push_back({TerminalEvent::Kind::exited, {}, exit}); } catch (...) { }
        { std::lock_guard lock(finish_mutex_); finished_ = true; }
        finish_cv_.notify_all();
    }
};
} // namespace coincide
