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
