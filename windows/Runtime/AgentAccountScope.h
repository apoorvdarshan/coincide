#pragma once
#include <windows.h>
#include <bcrypt.h>
#include <array>
#include <climits>
#include <stdexcept>
#include <string>
#pragma comment(lib, "bcrypt.lib")

namespace coincide {
// This is a routing guard, not authentication. Inputs must be a provider's verified non-secret
// account ID and profile location. Never derive this value from a token, API key or password.
struct AgentAccountScope {
    std::string current, saved;
    void require_resume() const {
        if (saved.empty()) return; // Legacy unscoped records require explicit migration by the UI.
        if (current.empty()) throw std::runtime_error("Verify this provider account before resuming its saved conversation");
        if (saved != current) throw std::runtime_error("This saved conversation belongs to another provider account; select that account or start a new conversation");
    }
    static std::string fingerprint(const std::string& provider, const std::string& account_id, const std::string& profile) {
        if (provider.empty() || account_id.empty()) return {};
        std::string input; for (const auto* value : {&provider, &account_id, &profile}) input += std::to_string(value->size()) + ":" + *value;
        BCRYPT_ALG_HANDLE algorithm{}; if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) < 0) throw std::runtime_error("Could not initialize account routing protection");
        struct Close {BCRYPT_ALG_HANDLE value; ~Close() {BCryptCloseAlgorithmProvider(value, 0);}} close{algorithm};
        std::array<unsigned char, 32> digest{};
        if (input.size() > ULONG_MAX || BCryptHash(algorithm, nullptr, 0, reinterpret_cast<PUCHAR>(input.data()), static_cast<ULONG>(input.size()), digest.data(), static_cast<ULONG>(digest.size())) < 0)
            throw std::runtime_error("Could not fingerprint the provider account identity");
        static constexpr char hex[] = "0123456789abcdef"; std::string output;
        for (const auto byte : digest) {output += hex[byte >> 4]; output += hex[byte & 15];} return output;
    }
};
} // namespace coincide
