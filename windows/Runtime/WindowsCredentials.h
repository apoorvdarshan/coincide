#pragma once
#include <windows.h>
#include <wincred.h>
#include <algorithm>
#include <cstdint>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>
#pragma comment(lib, "advapi32.lib")

namespace coincide {
// The Windows Credential Manager protects these generic entries for the signed-in Windows user.
// Each app owner/profile has an explicit namespace; no account discovery or sign-in is performed.
class CredentialSecret {
public:
    CredentialSecret() = default;
    explicit CredentialSecret(std::span<const std::uint8_t> bytes) : bytes_(bytes.begin(), bytes.end()) {}
    CredentialSecret(const CredentialSecret&) = delete;
    CredentialSecret& operator=(const CredentialSecret&) = delete;
    CredentialSecret(CredentialSecret&& other) noexcept : bytes_(std::move(other.bytes_)) {}
    CredentialSecret& operator=(CredentialSecret&& other) noexcept {if (this != &other) {clear(); bytes_ = std::move(other.bytes_);} return *this;}
    ~CredentialSecret() {clear();}
    std::span<const std::uint8_t> bytes() const noexcept {return bytes_;}
private:
    std::vector<std::uint8_t> bytes_;
    void clear() noexcept {if (!bytes_.empty()) SecureZeroMemory(bytes_.data(), bytes_.size()); bytes_.clear();}
};
struct WindowsCredential {std::wstring username; CredentialSecret secret;};

class WindowsCredentials {
public:
    explicit WindowsCredentials(std::wstring owner_scope) {
        if (!valid_name(owner_scope)) throw std::invalid_argument("Invalid credential owner scope");
        prefix_ = L"Coincide/" + std::move(owner_scope) + L"/";
    }
    void save(std::wstring_view name, std::wstring_view username, std::span<const std::uint8_t> secret) const {
        const auto target = key(name);
        if (username.size() > CRED_MAX_USERNAME_LENGTH || username.find(L'\0') != std::wstring_view::npos
                || secret.size() > CRED_MAX_CREDENTIAL_BLOB_SIZE) throw std::invalid_argument("Credential data exceeds Windows storage bounds");
        const std::wstring user(username);
        CREDENTIALW credential{}; credential.Type = CRED_TYPE_GENERIC;
        credential.TargetName = const_cast<wchar_t*>(target.c_str()); credential.UserName = const_cast<wchar_t*>(user.c_str());
        credential.CredentialBlobSize = static_cast<DWORD>(secret.size());
        credential.CredentialBlob = const_cast<BYTE*>(secret.data()); credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
        if (!CredWriteW(&credential, 0)) fail("Could not save the Windows credential");
    }
    std::optional<WindowsCredential> load(std::wstring_view name) const {
        const auto target = key(name); PCREDENTIALW raw{};
        if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &raw)) {
            if (GetLastError() == ERROR_NOT_FOUND) return std::nullopt; fail("Could not read the Windows credential");
        }
        Entry entry{raw};
        if (raw->Type != CRED_TYPE_GENERIC || !raw->TargetName || target != raw->TargetName
                || raw->CredentialBlobSize > CRED_MAX_CREDENTIAL_BLOB_SIZE || (raw->CredentialBlobSize && !raw->CredentialBlob))
            throw std::runtime_error("Invalid Windows credential entry");
        WindowsCredential result;
        if (raw->UserName) {
            const auto length = wcsnlen_s(raw->UserName, CRED_MAX_USERNAME_LENGTH + 1);
            if (length > CRED_MAX_USERNAME_LENGTH) throw std::runtime_error("Invalid Windows credential username");
            result.username.assign(raw->UserName, length);
        }
        result.secret = CredentialSecret(std::span<const std::uint8_t>(raw->CredentialBlob, raw->CredentialBlobSize));
        return result;
    }
    bool erase(std::wstring_view name) const {
        const auto target = key(name);
        if (CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0)) return true;
        if (GetLastError() == ERROR_NOT_FOUND) return false; fail("Could not remove the Windows credential");
    }
    std::vector<std::wstring> names() const {
        const auto filter = prefix_ + L"*"; DWORD count{}; PCREDENTIALW* values{};
        if (!CredEnumerateW(filter.c_str(), 0, &count, &values)) {
            if (GetLastError() == ERROR_NOT_FOUND) return {}; fail("Could not list Windows credential names");
        }
        struct Entries {DWORD count; PCREDENTIALW* values; ~Entries(){for (DWORD i = 0; i < count; ++i) wipe(values[i]); CredFree(values);}} entries{count, values};
        std::vector<std::wstring> result;
        if (count > 4096) throw std::runtime_error("Credential owner scope exceeds its entry limit");
        for (DWORD i = 0; i < count; ++i) {
            const auto credential = values[i];
            if (!credential || credential->Type != CRED_TYPE_GENERIC || !credential->TargetName) continue;
            const std::wstring_view target(credential->TargetName);
            if (target.starts_with(prefix_) && valid_name(target.substr(prefix_.size()))) result.emplace_back(target.substr(prefix_.size()));
        }
        std::sort(result.begin(), result.end()); return result;
    }
    static bool valid_name(std::wstring_view name) noexcept {
        return !name.empty() && name.size() <= 80 && std::all_of(name.begin(), name.end(), [](wchar_t ch) {
            return (ch >= L'a' && ch <= L'z') || (ch >= L'A' && ch <= L'Z') || (ch >= L'0' && ch <= L'9') || ch == L'-' || ch == L'_';
        });
    }
private:
    std::wstring prefix_;
    static void wipe(PCREDENTIALW value) noexcept {
        if (value && value->CredentialBlob && value->CredentialBlobSize) SecureZeroMemory(value->CredentialBlob, value->CredentialBlobSize);
    }
    struct Entry {PCREDENTIALW value; ~Entry(){wipe(value); CredFree(value);}};
    std::wstring key(std::wstring_view name) const {
        if (!valid_name(name)) throw std::invalid_argument("Invalid credential name");
        return prefix_ + std::wstring(name);
    }
    [[noreturn]] static void fail(const char* operation) {throw std::system_error(static_cast<int>(GetLastError()), std::system_category(), operation);}
};
} // namespace coincide
