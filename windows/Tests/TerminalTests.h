#pragma once
#include "../Runtime/ConPtySession.h"
#include "../Core/TerminalScreen.h"
#include <fstream>

namespace coincide {
inline std::string terminal_utf8(std::wstring_view text) {
    if (text.empty()) return {};
    const auto count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (!count) throw std::runtime_error("Cannot encode the terminal fixture text");
    std::string result(static_cast<std::size_t>(count), '\0');
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), count, nullptr, nullptr)) {
        throw std::runtime_error("Cannot encode the terminal fixture text");
    }
    return result;
}
inline std::string terminal_hex(std::string_view bytes) {
    static constexpr char digits[] = "0123456789abcdef";
    std::string result; result.reserve(bytes.size() * 2);
    for (const auto value : bytes) {
        const auto byte = static_cast<unsigned char>(value);
        result.push_back(digits[byte >> 4]); result.push_back(digits[byte & 15]);
    }
    return result;
}
inline void terminal_fixture_write(HANDLE output, std::string_view bytes) {
    while (!bytes.empty()) {
        DWORD written{};
        const auto count = static_cast<DWORD>(std::min<std::size_t>(bytes.size(), 8192));
        if (!WriteFile(output, bytes.data(), count, &written, nullptr) || !written) throw std::runtime_error("The terminal fixture output failed");
        bytes.remove_prefix(written);
    }
}
// Deterministic console child only. No account, network, actual user command, console window, or audible output.
inline int terminal_fixture(int argc, wchar_t** argv) {
    if (argc < 3) return 2;
    try {
        const auto mode = std::wstring_view(argv[2]);
        const auto output = GetStdHandle(STD_OUTPUT_HANDLE), input = GetStdHandle(STD_INPUT_HANDLE);
        if (!SetConsoleCP(CP_UTF8) || !SetConsoleOutputCP(CP_UTF8)
                || !SetConsoleMode(output, ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN)
                || !SetConsoleMode(input, ENABLE_VIRTUAL_TERMINAL_INPUT)) return 3;
        if (mode == L"wait") { terminal_fixture_write(output, "WAIT_READY\r\n"); Sleep(30000); return 0; }
        if (mode == L"flood") {
            const std::string block(8192, 'x');
            for (int i = 0; i < 2048; ++i) terminal_fixture_write(output, block);
            return 0;
        }
        if (mode == L"descendant") {
            wchar_t module[32768]{};
            if (!GetModuleFileNameW(nullptr, module, 32768)) return 4;
            auto command = quote_windows_argument(module) + L" --terminal-fixture wait";
            STARTUPINFOW startup{}; startup.cb = sizeof(startup); PROCESS_INFORMATION process{};
            if (!CreateProcessW(module, command.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &startup, &process)) return 5;
            NativeHandle child(process.hProcess), thread(process.hThread);
            terminal_fixture_write(output, "CHILD_PID:" + std::to_string(process.dwProcessId) + "\r\n");
            WaitForSingleObject(child.get(), 30000); return 0;
        }
        if (mode == L"interactive") {
            terminal_fixture_write(output, "\x1b[32mTERMINAL_FIXTURE_READY 你好\x1b[0m\r\n");
            std::string line;
            std::array<char,256> bytes{};
            for (;;) {
                DWORD count{};
                if (!ReadFile(input,bytes.data(),static_cast<DWORD>(bytes.size()),&count,nullptr)||!count) return 0;
                for(DWORD i=0;i<count;++i){
                    const auto byte=bytes[i];
                    if(byte=='\r'||byte=='\n'){
                        if(line=="exit")return 0;
                        if(line=="size"){
                            CONSOLE_SCREEN_BUFFER_INFO info{};if(!GetConsoleScreenBufferInfo(output,&info))return 8;
                            terminal_fixture_write(output,"SIZE:"+std::to_string(info.dwSize.X)+"x"+std::to_string(info.dwSize.Y)+"\r\n");
                        }else if(line.find('\x1b')!=std::string::npos)terminal_fixture_write(output,"INPUTHEX:"+terminal_hex(line)+"\r\n");
                        else terminal_fixture_write(output,"ECHO:"+line+"\r\n");
                        line.clear();
                    }else if(byte==3){line.clear();terminal_fixture_write(output,"CTRL_C_MARKER\r\n");}
                    else if(byte=='\b'||byte=='\x7f'){
                        if(!line.empty()){auto at=line.size()-1;while(at&&(static_cast<unsigned char>(line[at])&0xc0)==0x80)--at;line.erase(at);}
                    }else if(line.size()<8192)line.push_back(byte);
                }
            }
        }
        if (mode != L"echo" && mode != L"size") return 2;
        if (mode == L"echo") {
            const std::string greeting = "\x1b[31mUTF8_MARKER_你好\x1b[0m\r\n";
            const auto split = greeting.find("你") + 1; // Split a UTF-8 sequence across actual child writes.
            terminal_fixture_write(output, std::string_view(greeting).substr(0, split));
            terminal_fixture_write(output, std::string_view(greeting).substr(split));
            terminal_fixture_write(GetStdHandle(STD_ERROR_HANDLE), "STDERR_MARKER\r\n");
            terminal_fixture_write(output, "CWD:" + terminal_utf8(std::filesystem::current_path().wstring()) + "\r\n");
            if (argc > 3) terminal_fixture_write(output, "ARG:" + terminal_utf8(argv[3]) + "\r\n");
        }
        terminal_fixture_write(output, "READY\r\n");
        std::string received;
        std::array<char, 256> bytes{};
        while (received.find('\r') == std::string::npos && received.find('\n') == std::string::npos) {
            DWORD count{};
            if (!ReadFile(input, bytes.data(), static_cast<DWORD>(bytes.size()), &count, nullptr) || !count) return 6;
            received.append(bytes.data(), count);
            if (received.size() > 8192) return 7;
        }
        if (mode == L"size") {
            CONSOLE_SCREEN_BUFFER_INFO info{};
            if (!GetConsoleScreenBufferInfo(output, &info)) return 8;
            terminal_fixture_write(output, "SIZE:" + std::to_string(info.dwSize.X) + "x" + std::to_string(info.dwSize.Y) + "\r\n");
        } else terminal_fixture_write(output, "INPUTHEX:" + terminal_hex(received) + "\r\n");
        return 37;
    } catch (...) { return 9; }
}

inline int terminal_tests(const std::filesystem::path& report,const std::filesystem::path& fixture_override={}) {
    using namespace std::chrono_literals;
    int checks{};
    auto check = [&](bool value, const char* message) { ++checks; if (!value) throw std::runtime_error(message); };
    auto rejects = [&](auto&& operation, const char* message) {
        bool rejected{}; try { operation(); } catch (...) { rejected = true; } check(rejected, message);
    };
    auto directory = std::filesystem::temp_directory_path() / (L"Coincide terminal tests 会話 " + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()));
    struct Cleanup {std::filesystem::path path; ~Cleanup() {std::error_code ignored; std::filesystem::remove_all(path, ignored);}} cleanup{directory};
    struct Result {
        std::string output;
        TerminalScreen screen{500,30};
        std::vector<TerminalEvent> events;
        bool exited{}, error{};
        DWORD exit_code{};
        void collect(ConPtySession& session) {
            for (auto& event : session.take_events()) {
                if (event.kind == TerminalEvent::Kind::output) {output += event.bytes;screen.consume(event.bytes);}
                if (event.kind == TerminalEvent::Kind::resized) screen.resize(event.columns,event.rows);
                if (event.kind == TerminalEvent::Kind::error) error = true;
                if (event.kind == TerminalEvent::Kind::exited) {exited = true; exit_code = event.exit_code;}
                events.push_back(std::move(event));
            }
        }
        std::string displayed()const{std::string result;for(const auto& line:screen.lines()){result+=TerminalScreen::line_text(line);result+='\n';}return result;}
    };
    auto until = [&](ConPtySession& session, Result& result, auto condition, const char* failure) {
        const auto deadline = std::chrono::steady_clock::now() + 5s;
        do {
            result.collect(session);
            if (condition()) return;
            if (result.exited) break;
            Sleep(10);
        } while (std::chrono::steady_clock::now() < deadline);
        throw std::runtime_error(failure);
    };
    try {
        if (!std::filesystem::create_directory(directory)) throw std::runtime_error("The unique terminal test directory already exists");
        wchar_t module[32768]{};
        if (!GetModuleFileNameW(nullptr, module, 32768)) throw std::runtime_error("Cannot locate the terminal test host");
        const auto host = std::filesystem::path(module);
        const auto fixture = fixture_override.empty()?host.parent_path().parent_path().parent_path() / "core-x64" / host.parent_path().filename() / "CoincideWorkspaceTests.exe":fixture_override;
        if (!std::filesystem::is_regular_file(fixture)) throw std::runtime_error("Build the console-subsystem workspace fixture before terminal tests");
        auto launch = [&](std::wstring mode) {
            TerminalLaunch value; value.executable = fixture; value.arguments = {L"--terminal-fixture", std::move(mode)};
            value.cwd = directory; value.columns = 500; value.rows = 30; return value;
        };
        {
        // Destroy every owned ConPTY/process/thread handle before publishing success.
        // wait_for_exit alone does not join the monitor thread; teardown is acceptance.
        auto options = launch(L"echo"); options.arguments.push_back(L"literal & | > $(text) 你好");
        auto session = ConPtySession::start(options);
        Result echo;
        until(*session, echo, [&] {return echo.displayed().find("READY") != std::string::npos;}, "The terminal fixture did not initialize");
        // ConPTY paints a VT screen and may interpose OSC title/cursor/SGR sequences
        // between child writes. Assert the actual rendered cells, not a raw log substring.
        check(echo.displayed().find("UTF8_MARKER_你好") != std::string::npos, "ConPTY must preserve UTF-8 emitted across child writes");
        check(echo.output.find('\x1b') != std::string::npos, "ConPTY output must retain VT sequences for the renderer");
        check(echo.displayed().find("STDERR_MARKER") != std::string::npos, "A terminal must include the child's stderr on the console surface");
        check(echo.displayed().find("CWD:" + terminal_utf8(directory.wstring())) != std::string::npos, "The terminal must use its selected Unicode working folder");
        check(echo.displayed().find("ARG:literal & | > $(text) 你好") != std::string::npos, "Terminal arguments must pass directly without shell interpretation");
        const std::string input = "\x1b[Aनमस्ते✓\r";
        check(session->write(input), "The terminal must accept raw keyboard/VT input");
        check(session->wait_for_exit(5s), "The terminal child must finish without a user interaction");
        echo.collect(*session);
        check(echo.displayed().find("INPUTHEX:" + terminal_hex(input)) != std::string::npos, "Raw input must arrive at the pseudoconsole without JSONL or newline rewriting");
        check(echo.exited && echo.exit_code == 37 && !echo.error, "The terminal must report its real child's exit code");
        check(!echo.events.empty() && echo.events.back().kind == TerminalEvent::Kind::exited, "Final output must be drained before the exit event");
        check(!session->running() && !session->write("after exit"), "An exited terminal must reject new input");
        session->shutdown(); session->shutdown();
        check(session->take_events().empty(), "Repeated shutdown must not fabricate another exit event");

        auto sized = ConPtySession::start(launch(L"size")); Result size;
        until(*sized, size, [&] {return size.output.find("READY") != std::string::npos;}, "The terminal resize fixture did not initialize");
        check(sized->resize(117, 41), "A live terminal must accept a new character grid");
        until(*sized, size, [&] {return std::any_of(size.events.begin(), size.events.end(), [](const auto& event) {
            return event.kind == TerminalEvent::Kind::resized && event.columns == 117 && event.rows == 41;
        });}, "The asynchronous terminal resize was not acknowledged");
        check(sized->write("size\r"), "The resized terminal must keep accepting input");
        check(sized->wait_for_exit(5s), "The resized terminal must exit cleanly"); size.collect(*sized);
        check(size.displayed().find("SIZE:117x41") != std::string::npos && !size.error, "The console child must observe the resized grid");
        rejects([&] {sized->resize(0, 10);}, "A zero-width terminal must be rejected");

        auto bounded_options = launch(L"wait"); bounded_options.input_limit = 32;
        auto bounded = ConPtySession::start(bounded_options); Result waiting;
        until(*bounded, waiting, [&] {return waiting.output.find("WAIT_READY") != std::string::npos;}, "The bounded-input fixture did not initialize");
        check(!bounded->write(std::string(33, 'x')), "An oversized input must be rejected before filling an unbounded queue");
        bounded->stop(); check(bounded->wait_for_exit(5s), "Stop must finish a terminal whose child is waiting");

        auto blocked_options = launch(L"wait"); blocked_options.input_limit = 8 * 1024 * 1024;
        auto blocked = ConPtySession::start(blocked_options); Result blocked_result;
        until(*blocked, blocked_result, [&] {return blocked_result.output.find("WAIT_READY") != std::string::npos;}, "The blocked-input fixture did not initialize");
        check(blocked->write(std::string(8 * 1024 * 1024, 'x')), "A bounded large write must be queued off the caller thread");
        blocked->stop(); check(blocked->wait_for_exit(5s), "Stop must unblock an owned terminal writer even when the child never reads");

        auto flood_options = launch(L"flood"); flood_options.output_limit = 256; flood_options.columns = 80;
        auto flood = ConPtySession::start(flood_options);
        check(flood->wait_for_exit(5s), "An unread terminal output overflow must stop its owned session");
        Result overflow; overflow.collect(*flood);
        check(overflow.error && overflow.exited && overflow.output.size() <= 256, "Output overflow must be explicit and keep unread bytes bounded");

        auto descendants = ConPtySession::start(launch(L"descendant")); Result tree;
        until(*descendants, tree, [&] {return tree.output.find("CHILD_PID:") != std::string::npos;}, "The descendant fixture did not initialize");
        const auto at = tree.output.find("CHILD_PID:") + 10;
        const auto child_id = static_cast<DWORD>(std::stoul(tree.output.substr(at)));
        NativeHandle child(OpenProcess(SYNCHRONIZE, FALSE, child_id));
        check(child.get() != nullptr, "The terminal's owned descendant must exist before stopping");
        descendants->stop(); check(descendants->wait_for_exit(5s), "Stopping a terminal must finish its job");
        check(WaitForSingleObject(child.get(), 2000) == WAIT_OBJECT_0, "Stopping a terminal must terminate its descendants as well");

        auto invalid = launch(L"wait"); invalid.output_limit = 0;
        rejects([&] {auto rejected = ConPtySession::start(invalid);}, "A terminal cannot disable its output bound");
        invalid = launch(L"wait"); invalid.cwd = directory / "missing-folder";
        rejects([&] {auto rejected = ConPtySession::start(invalid);}, "Invalid terminal folders must fail without a shell or visible fallback");
        }
        std::ofstream output(report); output << "PASS: " << checks << " native ConPTY terminal checks\n";
        return output ? 0 : 2;
    } catch (const std::exception& error) {
        std::ofstream(report) << "FAIL: " << error.what() << '\n'; return 1;
    }
}
} // namespace coincide
