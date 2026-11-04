#pragma once
#include "RpcPeer.h"
#include "WindowsProcess.h"
#include <condition_variable>
#include <deque>

namespace coincide {
// Transport ownership lives on a dedicated host thread. Pipe reads only enqueue bytes, and
// writes have their own worker, so a child that stops reading cannot freeze the UI or deadlines.
// Callbacks run on the host thread: enqueue their plain UTF-8 values to the UI and return promptly.
class RpcConnection {
public:
    using Notification = std::function<void(std::string, std::string)>;
    using ServerRequest = std::function<void(std::string, std::string, std::string)>;
    using Closed = std::function<void(std::string)>;

    RpcConnection(std::filesystem::path executable, std::vector<std::wstring> arguments,
            std::filesystem::path cwd, Notification notification = {}, ServerRequest request = {}, Closed closed = {})
        : executable_(std::move(executable)), arguments_(std::move(arguments)), cwd_(std::move(cwd)),
          notification_(std::move(notification)), request_(std::move(request)), closed_(std::move(closed)),
          host_([this] { run(); }) {}
    ~RpcConnection() { shutdown(); }
    RpcConnection(const RpcConnection&) = delete;
    RpcConnection& operator=(const RpcConnection&) = delete;

    std::future<std::string> call(std::string method, std::string params,
            std::chrono::milliseconds timeout = std::chrono::seconds(30)) {
        auto completion = std::make_shared<std::promise<std::string>>();
        auto result = completion->get_future();
        Task task;
        task.completion = completion;
        task.action = [method=std::move(method), params=std::move(params), timeout, completion](RpcPeer& peer, auto& pending) {
            auto call = peer.request(method, rpc_json::JsonValue::Parse(winrt::to_hstring(params)), timeout);
            pending.push_back({std::move(call.result), completion});
        };
        submit(std::move(task));
        return result;
    }

    void notify(std::string method, std::string params = "{}") {
        Task task;
        task.action = [method=std::move(method), params=std::move(params)](RpcPeer& peer, auto&) {
            peer.notify(method, rpc_json::JsonValue::Parse(winrt::to_hstring(params)));
        };
        submit(std::move(task));
    }

    void respond(std::string id_json, std::string result_json) {
        Task task;
        task.action = [id=std::move(id_json), result=std::move(result_json)](RpcPeer& peer, auto&) {
            peer.respond(rpc_json::JsonValue::Parse(winrt::to_hstring(id)), rpc_json::JsonValue::Parse(winrt::to_hstring(result)));
        };
        submit(std::move(task));
    }

    void reject(std::string id_json, const std::string& message) {
        Task task;
        task.action = [id=std::move(id_json), message](RpcPeer& peer, auto&) {
            peer.respond_error(rpc_json::JsonValue::Parse(winrt::to_hstring(id)), -32601, message);
        };
        submit(std::move(task));
    }

    // Nonblocking cancellation request. Destruction joins the owned workers after cancelling the child job.
    void close() noexcept {
        stopping_ = true;
        incoming_cv_.notify_all(); outgoing_cv_.notify_all();
    }
    void shutdown() noexcept {
        close();
        if (host_.joinable()) host_.join();
    }

private:
    struct Pending { std::future<rpc_json::IJsonValue> result; std::shared_ptr<std::promise<std::string>> completion; };
    struct Task {
        std::function<void(RpcPeer&, std::vector<Pending>&)> action;
        std::shared_ptr<std::promise<std::string>> completion;
    };
    static constexpr std::size_t queue_limit = 64 * 1024 * 1024;
    std::filesystem::path executable_;
    std::vector<std::wstring> arguments_;
    std::filesystem::path cwd_;
    Notification notification_;
    ServerRequest request_;
    Closed closed_;
    std::mutex incoming_mutex_, outgoing_mutex_;
    std::condition_variable incoming_cv_, outgoing_cv_;
    std::deque<std::string> lines_, writes_;
    std::deque<Task> tasks_;
    std::size_t incoming_bytes_{}, outgoing_bytes_{};
    std::atomic<bool> stopping_{};
    std::atomic<bool> transport_failed_{};
    std::thread host_; // Last: every field above is initialized before the worker can observe this object.

    void submit(Task task) {
        std::lock_guard lock(incoming_mutex_);
        if (stopping_) throw RpcError("The agent connection is closed");
        if (tasks_.size() >= 1024) throw RpcError("The agent request queue is full");
        tasks_.push_back(std::move(task)); incoming_cv_.notify_one();
    }
    void enqueue_line(std::string line) {
        std::lock_guard lock(incoming_mutex_);
        if (stopping_ || line.empty()) return;
        if (lines_.size() >= 65536 || line.size() > queue_limit - incoming_bytes_) {
            transport_failed_ = true;
        } else {
            incoming_bytes_ += line.size(); lines_.push_back(std::move(line));
        }
        incoming_cv_.notify_one();
    }
    void enqueue_write(std::string line) {
        std::lock_guard lock(outgoing_mutex_);
        if (stopping_ || transport_failed_) throw RpcError("The agent transport is closed");
        if (line.size() > queue_limit - outgoing_bytes_) {
            transport_failed_ = true; incoming_cv_.notify_one();
            throw RpcError("The agent write queue is full");
        }
        outgoing_bytes_ += line.size(); writes_.push_back(std::move(line)); outgoing_cv_.notify_one();
    }
    void write_loop(WindowsProcess& process) noexcept {
        try {
            for (;;) {
                std::string line;
                {
                    std::unique_lock lock(outgoing_mutex_);
                    outgoing_cv_.wait(lock, [&] {return stopping_ || !writes_.empty();});
                    if (stopping_) return;
                    line = std::move(writes_.front()); writes_.pop_front(); outgoing_bytes_ -= line.size();
                }
                process.write_line(line);
            }
        } catch (...) { transport_failed_ = true; incoming_cv_.notify_one(); }
    }
    static void collect(std::vector<Pending>& pending) {
        for (auto at = pending.begin(); at != pending.end();) {
            if (at->result.wait_for(std::chrono::milliseconds(0)) != std::future_status::ready) {++at; continue;}
            try {at->completion->set_value(winrt::to_string(at->result.get().Stringify()));}
            catch (...) {at->completion->set_exception(std::current_exception());}
            at = pending.erase(at);
        }
    }
    void run() noexcept {
        std::vector<Pending> pending;
        std::unique_ptr<WindowsProcess> process;
        std::thread writer;
        std::exception_ptr failure;
        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
            struct Apartment {~Apartment(){winrt::uninit_apartment();}} apartment;
            RpcPeer peer([this](auto line) {enqueue_write(std::move(line));},
                [this](auto method, auto params) {
                    if (notification_) notification_(std::move(method), winrt::to_string(params.Stringify()));
                }, [this](auto id, auto method, auto params) {
                    if (request_) request_(winrt::to_string(id.Stringify()), std::move(method), winrt::to_string(params.Stringify()));
                    else { // No registered approver is never permission to execute a command.
                        Task task;
                        task.action = [id](RpcPeer& p, auto&) {p.respond_error(id, -32601, "The client does not implement this request");};
                        submit(std::move(task));
                    }
                });
            process = WindowsProcess::start(executable_, arguments_, cwd_, [this](auto line) {enqueue_line(std::move(line));});
            writer = std::thread([this, raw=process.get()] {write_loop(*raw);});
            while (!stopping_) {
                std::deque<Task> tasks;
                std::deque<std::string> lines;
                {
                    std::unique_lock lock(incoming_mutex_);
                    incoming_cv_.wait_for(lock, std::chrono::milliseconds(10), [&] {
                        return stopping_ || transport_failed_ || !tasks_.empty() || !lines_.empty();
                    });
                    tasks.swap(tasks_); lines.swap(lines_); incoming_bytes_ = 0;
                }
                if (stopping_ || transport_failed_) {
                    // Retain tasks for the common failure path below, which resolves every caller.
                    std::lock_guard lock(incoming_mutex_);
                    tasks_.insert(tasks_.end(), std::make_move_iterator(tasks.begin()), std::make_move_iterator(tasks.end()));
                    if (transport_failed_) throw RpcError("The agent transport failed");
                    break;
                }
                for (auto& task : tasks) {
                    try {task.action(peer, pending);}
                    catch (...) {if (task.completion) task.completion->set_exception(std::current_exception()); else throw;}
                }
                for (const auto& line : lines) peer.receive(line);
                peer.expire(); collect(pending);
                if (auto exit = process->wait(std::chrono::milliseconds(0))) {
                    // wait() drains stdout before returning; consume final responses before reporting the exit.
                    std::deque<std::string> final_lines;
                    {std::lock_guard lock(incoming_mutex_); final_lines.swap(lines_); incoming_bytes_ = 0;}
                    for (const auto& line : final_lines) peer.receive(line);
                    collect(pending);
                    throw RpcError("The agent process exited with status " + std::to_string(exit->status));
                }
            }
            peer.close(); collect(pending);
        } catch (...) {failure = std::current_exception();}
        stopping_ = true; outgoing_cv_.notify_all();
        if (process) process->stop(); // Unblocks an outstanding WriteFile before joining its worker.
        if (writer.joinable()) writer.join();
        if (!failure) failure = std::make_exception_ptr(RpcError("The agent connection closed"));
        for (auto& value : pending) {try {value.completion->set_exception(failure);} catch (...) {}}
        std::deque<Task> abandoned;
        {std::lock_guard lock(incoming_mutex_); abandoned.swap(tasks_); lines_.clear(); incoming_bytes_ = 0;}
        for (auto& task : abandoned) if (task.completion) {try {task.completion->set_exception(failure);} catch (...) {}}
        if (closed_) {
            try {std::rethrow_exception(failure);}
            catch (const std::exception& error) {try {closed_(error.what());} catch (...) {}}
            catch (...) {try {closed_("The agent connection closed");} catch (...) {}}
        }
    }
};
} // namespace coincide
