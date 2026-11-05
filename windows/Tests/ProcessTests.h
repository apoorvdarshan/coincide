#pragma once
#include "../Runtime/WindowsProcess.h"

namespace coincide {
inline std::string process_utf8(std::wstring_view text) {
    if (text.empty()) return {};
    const auto count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (!count) throw std::runtime_error("Cannot encode a Windows argument");
    std::string result(static_cast<std::size_t>(count), '\0');
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), count, nullptr, nullptr)) {
        throw std::runtime_error("Cannot encode a Windows argument");
    }
    return result;
}

inline void fixture_write(HANDLE destination, std::string_view text) {
    std::size_t offset{};
    while (offset < text.size()) {
        DWORD count{};
        if (!WriteFile(destination, text.data() + offset, static_cast<DWORD>(text.size() - offset), &count, nullptr) || !count) return;
        offset += count;
    }
}

// Local deterministic subprocess fixture. It never authenticates, calls a provider, or contacts a network.
inline int process_fixture(int argc, wchar_t** argv) {
    if (argc < 3) return 2;
    const auto mode = std::wstring_view(argv[2]);
    const auto output = GetStdHandle(STD_OUTPUT_HANDLE);
    if (mode == L"args") {
        for (int i = 3; i < argc; ++i) fixture_write(output, process_utf8(argv[i]) + "\n");
        return 0;
    }
    if (mode == L"stderr") {
        fixture_write(GetStdHandle(STD_ERROR_HANDLE), std::string(24000, 'x') + "error-tail-marker");
        return 7;
    }
    if (mode == L"wait") { Sleep(30000); return 0; }
    if (mode == L"raw") {
        fixture_write(output, std::string_view("raw\0record\r\nlast\r", 17)); return 0;
    }
    if (mode == L"raw-flood") {
        for (int i = 0; i < 1024; ++i) fixture_write(output, std::string(4096, 'x'));
        return 0;
    }
    if (mode == L"merged") {
        fixture_write(output, "out"); fixture_write(GetStdHandle(STD_ERROR_HANDLE), std::string_view("err\0\r", 5));
        fixture_write(output, "last"); return 7;
    }
    if (mode == L"merged-wait") {
        fixture_write(output, "live"); fixture_write(GetStdHandle(STD_ERROR_HANDLE), "-error"); Sleep(30000); return 0;
    }
    if (mode == L"merged-flood") {
        for (int i = 0; i < 1024; ++i) fixture_write(GetStdHandle(STD_ERROR_HANDLE), std::string(4096, 'e'));
        return 0;
    }
    if (mode == L"environment") {
        wchar_t value[256]{};
        const auto count = GetEnvironmentVariableW(L"COINCIDE_PROCESS_ENV_PROBE", value, 256);
        if (!count || count >= 256) return 3;
        fixture_write(output, process_utf8(std::wstring_view(value, count))); return 0;
    }
    if (mode == L"environment-unset") {
        SetLastError(ERROR_SUCCESS);
        if (GetEnvironmentVariableW(L"PATH", nullptr, 0) || GetLastError() != ERROR_ENVVAR_NOT_FOUND) return 3;
        fixture_write(output, "unset"); return 0;
    }
    if (mode == L"cwd") { fixture_write(output, process_utf8(std::filesystem::current_path().wstring()) + "\n"); return 0; }
    if (mode == L"echo") {
        LineFramer framer;
        std::array<char, 1024> bytes{};
        DWORD count{};
        auto echo = [&](std::string line) {
            // Split writes in the middle of UTF-8 too; the receiver must preserve exact bytes.
            const auto middle = line.size() / 2;
            fixture_write(output, std::string_view(line).substr(0, middle));
            fixture_write(output, std::string_view(line).substr(middle));
            fixture_write(output, "\n");
        };
        while (ReadFile(GetStdHandle(STD_INPUT_HANDLE), bytes.data(), static_cast<DWORD>(bytes.size()), &count, nullptr) && count) {
            framer.consume(std::string_view(bytes.data(), count), echo);
        }
        framer.finish(echo);
        fixture_write(output, "final-without-newline");
        return 0;
    }
    return 2;
}

template<class Check, class Rejects> void process_tests(Check&& check, Rejects&& rejects) {
    wchar_t module[32768]{};
    const auto length = GetModuleFileNameW(nullptr, module, 32768);
    if (!length || length >= 32768) throw std::runtime_error("Cannot locate the process fixture executable");
    auto directory = std::filesystem::temp_directory_path() /
        (L"Coincide process tests 会話 " + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()));
    if (!std::filesystem::create_directory(directory)) throw std::runtime_error("The unique process test directory already exists");
    struct Cleanup {
        std::filesystem::path path;
        ~Cleanup() { std::error_code ignored; std::filesystem::remove_all(path, ignored); }
    } cleanup{directory};
    const auto executable = directory / L"Agent fixture.exe";
    std::filesystem::copy_file(std::filesystem::path(module), executable);

    std::string raw;
    auto raw_process = WindowsProcess::start_bytes(executable, {L"--process-fixture", L"raw"}, directory,
        [&](std::string_view bytes) {raw.append(bytes);});
    raw_process->close_input();
    const auto raw_exit = raw_process->wait(std::chrono::seconds(5));
    check(raw_exit && raw_exit->status == 0 && !raw_exit->stdout_truncated, "raw subprocess output must finish normally");
    check(raw == std::string("raw\0record\r\nlast\r", 17), "raw output must preserve NULs and carriage returns exactly");
    raw.clear();
    auto merged = WindowsProcess::start_bytes(executable, {L"--process-fixture", L"merged"}, directory,
        [&](std::string_view bytes) {raw.append(bytes);}, 1024, {}, true);
    merged->close_input();
    const auto merged_exit = merged->wait(std::chrono::seconds(5));
    check(merged_exit && merged_exit->status == 7 && merged_exit->stderr_tail.empty() && raw == std::string("outerr\0\rlast", 12),
        "merged terminal bytes must retain write order, NULs and carriage returns without a second stderr copy");
    raw.clear();
    merged = WindowsProcess::start_bytes(executable, {L"--process-fixture", L"merged-flood"}, directory,
        [&](std::string_view bytes) {raw.append(bytes);}, 1024, {}, true);
    merged->close_input();
    const auto merged_cap = merged->wait(std::chrono::seconds(5));
    check(merged_cap && merged_cap->stdout_truncated && merged_cap->stderr_tail.empty() && raw == std::string(1024, 'e'),
        "merged stderr must share the bounded byte capture and terminate only its owned producer on overflow");
    std::atomic<std::size_t> live_bytes{};
    merged = WindowsProcess::start_bytes(executable, {L"--process-fixture", L"merged-wait"}, directory,
        [&](std::string_view bytes) {live_bytes += bytes.size();}, 1024, {}, true);
    const auto live_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (live_bytes < 10 && std::chrono::steady_clock::now() < live_deadline) Sleep(10);
    check(live_bytes == 10 && !merged->wait(std::chrono::milliseconds(0)), "merged terminal output must stream while its process is still running");
    merged->stop();
    check(merged->wait(std::chrono::seconds(5)).has_value(), "a merged terminal process must release its pipes promptly after Stop");
    raw.clear();
    raw_process = WindowsProcess::start_bytes(executable, {L"--process-fixture", L"raw-flood"}, directory,
        [&](std::string_view bytes) {raw.append(bytes);}, 1024);
    raw_process->close_input();
    const auto bounded_exit = raw_process->wait(std::chrono::seconds(5));
    check(bounded_exit && bounded_exit->stdout_truncated, "a raw output cap must terminate the owned producer and release its waiting caller");
    check(raw.size() == 1024 && bounded_exit->channel_error.empty(), "a bounded preview must retain exactly its prefix and report truncation separately");
    wchar_t original_probe[256]{};
    const auto original_count = GetEnvironmentVariableW(L"COINCIDE_PROCESS_ENV_PROBE", original_probe, 256);
    raw.clear();
    raw_process = WindowsProcess::start_bytes(executable, {L"--process-fixture", L"environment"}, directory,
        [&](std::string_view bytes) {raw.append(bytes);}, 1024, {{L"COINCIDE_PROCESS_ENV_PROBE", L"child-only-你好"}});
    raw_process->close_input();
    const auto environment_exit = raw_process->wait(std::chrono::seconds(5));
    check(environment_exit && environment_exit->status == 0 && raw == "child-only-你好", "child environment overrides must preserve Unicode");
    wchar_t after_probe[256]{};
    const auto after_count = GetEnvironmentVariableW(L"COINCIDE_PROCESS_ENV_PROBE", after_probe, 256);
    check(original_count == after_count && std::wstring_view(original_probe) == std::wstring_view(after_probe),
        "a child environment override must never modify the parent process environment");
    const auto path_before = GetEnvironmentVariableW(L"PATH", nullptr, 0);
    raw.clear();
    raw_process = WindowsProcess::start_bytes(executable, {L"--process-fixture", L"environment-unset"}, directory,
        [&](std::string_view bytes) {raw.append(bytes);}, 1024, {{L"PATH", std::nullopt}});
    raw_process->close_input();
    const auto unset_exit = raw_process->wait(std::chrono::seconds(5));
    check(unset_exit && unset_exit->status == 0 && raw == "unset", "explicit child removals must remove variables instead of assigning an empty value");
    check(path_before == GetEnvironmentVariableW(L"PATH", nullptr, 0), "child environment removal must preserve the parent's PATH without logging its contents");
    raw.clear();
    auto framed_environment = WindowsProcess::start(executable, {L"--process-fixture", L"environment"}, directory,
        [&](std::string line) {raw += line;}, {{L"COINCIDE_PROCESS_ENV_PROBE", L"framed-child-你好"}});
    framed_environment->close_input();
    const auto framed_exit = framed_environment->wait(std::chrono::seconds(5));
    check(framed_exit && framed_exit->status == 0 && raw == "framed-child-你好", "framed RPC subprocesses must support the same isolated child environment overrides");

    std::vector<std::string> lines;
    auto process = WindowsProcess::start(executable, {L"--process-fixture", L"echo"}, directory,
        [&](std::string line) { lines.push_back(std::move(line)); });
    process->write_line("A message with spaces");
    process->write_line("नमस्ते — 你好");
    process->write_line("");
    rejects([&]{process->write_line("bad\nframe");}, "literal newlines must not inject extra protocol messages");
    process->close_input();
    const auto exit = process->wait(std::chrono::seconds(5));
    check(exit && exit->status == 0 && exit->channel_error.empty(), "a normal child must exit cleanly");
    check(lines == std::vector<std::string>{"A message with spaces", "नमस्ते — 你好", "", "final-without-newline"},
        "process streams must retain ordered Unicode, empty lines and the final unterminated line");
    rejects([&]{process->write_line("closed");}, "writes after EOF must fail clearly");

    lines.clear();
    const std::vector<std::wstring> arguments{L"", L"two words", L"embedded\"quote", L"trailing\\", L"a\\\"b\\", L"नमस्ते 你好", L"& | > $(literal)"};
    std::vector<std::wstring> launch{L"--process-fixture", L"args"};
    launch.insert(launch.end(), arguments.begin(), arguments.end());
    process = WindowsProcess::start(executable, launch, directory, [&](std::string line) {lines.push_back(std::move(line));});
    const auto arg_exit = process->wait(std::chrono::seconds(5));
    check(arg_exit && arg_exit->status == 0, "the argument fixture must exit successfully");
    std::vector<std::string> expected;
    for (const auto& argument : arguments) expected.push_back(process_utf8(argument));
    check(lines == expected, "Windows arguments must round trip without shell interpretation or Unicode loss");

    lines.clear();
    process = WindowsProcess::start(executable, {L"--process-fixture", L"cwd"}, directory,
        [&](std::string line) {lines.push_back(std::move(line));});
    const auto cwd_exit = process->wait(std::chrono::seconds(5));
    check(cwd_exit && cwd_exit->status == 0 && lines == std::vector<std::string>{process_utf8(directory.wstring())},
        "children must use the selected project folder, including Unicode and spaces");

    process = WindowsProcess::start(executable, {L"--process-fixture", L"stderr"}, directory, [](auto){});
    const auto error = process->wait(std::chrono::seconds(5));
    check(error && error->status == 7, "nonzero child exit codes must be preserved");
    check(error && error->stderr_tail.size() == 8192 && error->stderr_tail.ends_with("error-tail-marker"),
        "stderr must be bounded while keeping its final diagnostic");

    process = WindowsProcess::start(executable, {L"--process-fixture", L"wait"}, directory, [](auto){});
    check(!process->wait(std::chrono::milliseconds(20)), "waiting must time out without claiming the process completed");
    const auto before_stop = std::chrono::steady_clock::now();
    process->stop();
    const auto stopped = process->wait(std::chrono::seconds(1));
    check(stopped && stopped->status == ERROR_CANCELLED, "stop must terminate the owned child process");
    check(std::chrono::steady_clock::now() - before_stop < std::chrono::seconds(5), "stop must release blocked pipe readers promptly");

    rejects([&]{(void)WindowsProcess::start(directory / L"missing.exe", {}, directory, [](auto){});},
        "missing executables must fail without starting a substitute shell");
    rejects([&]{(void)WindowsProcess::start(executable, {}, directory / L"missing-folder", [](auto){});},
        "missing project folders must fail without changing the working directory");
}
} // namespace coincide
