#pragma once
#include "WindowsProcess.h"
#include <aclapi.h>
#include <cwctype>
#include <climits>
#include <string_view>
#include <objbase.h>
#pragma comment(lib, "advapi32.lib")

namespace coincide {
// ACP's client filesystem never interprets a shell path. Ancestor handles deny replacement while an
// operation is in flight. Reparse points, alternate streams, device aliases and remote volumes are
// refused even in full access: selecting full access grants operations, not a different project root.
class ACPFileSystem {
public:
    static constexpr std::size_t max_bytes = 8 * 1024 * 1024;
    explicit ACPFileSystem(const std::filesystem::path& root) {
        const auto declared = root_alias(std::filesystem::absolute(root));
        root_ = root_alias(std::filesystem::canonical(root)); validate_literal(root_); validate_literal(declared);
        const auto drive = root_.root_path().wstring(); const auto type = GetDriveTypeW(drive.c_str());
        if (type != DRIVE_FIXED && type != DRIVE_RAMDISK) throw std::invalid_argument("ACP requires a local project folder");
        root_handle_ = directory(root_); root_name_ = final_name(root_handle_.get());
        // TEMP can use an 8.3 name or a DOS drive alias while canonical() returns its physical
        // spelling. Freeze only the explicitly selected root spellings, then map them onto the
        // pinned handle's physical root. Never canonicalize an untrusted descendant to admit it.
        if (!root_name_.starts_with(L"\\\\?\\")) throw std::invalid_argument("ACP requires a local DOS project path");
        const auto physical = root_alias(std::filesystem::path(root_name_.substr(4))); validate_literal(physical);
        root_aliases_ = {physical, root_, declared}; root_ = physical;
    }
    const std::filesystem::path& root() const {return root_;}
    std::filesystem::path literal(const std::string& requested, bool allow_root = false) const {
        const std::filesystem::path value(wide(requested)); validate_literal(value);
        const auto name = value.lexically_normal().wstring();
        const auto equal = [](std::wstring_view a, std::wstring_view b) {return a.size() == b.size() && CompareStringOrdinal(a.data(), static_cast<int>(a.size()), b.data(), static_cast<int>(b.size()), TRUE) == CSTR_EQUAL;};
        for (const auto& alias : root_aliases_) {
            const auto base = alias.wstring();
            if (equal(name, base)) {if (allow_root) return root_; throw std::invalid_argument("An ACP file path must name a file inside the project");}
            const auto prefix = base.ends_with(L'\\') ? base : base + L"\\";
            if (name.size() > prefix.size() && equal(std::wstring_view(name).substr(0, prefix.size()), prefix)) return root_ / std::filesystem::path(name.substr(prefix.size()));
        }
        throw std::invalid_argument("The ACP path is outside the project");
    }
    std::filesystem::path working_directory(const std::string& requested) const {
        const auto value = requested.empty() ? root_ : literal(requested, true); auto pinned = parents(value, true, false); static_cast<void>(pinned); return value;
    }
    std::string read(const std::string& requested) const {
        const auto value = literal(requested); auto pinned = parents(value.parent_path(), true, false);
        NativeHandle file(CreateFileW(value.c_str(), GENERIC_READ | FILE_READ_ATTRIBUTES, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr));
        inspect(file.get()); LARGE_INTEGER size{};
        if (!GetFileSizeEx(file.get(), &size) || size.QuadPart < 0 || size.QuadPart > static_cast<LONGLONG>(max_bytes)) throw std::invalid_argument("ACP can read text files up to 8 MB");
        std::string bytes(static_cast<std::size_t>(size.QuadPart), '\0'); std::size_t offset{};
        while (offset < bytes.size()) {DWORD count{}; if (!ReadFile(file.get(), bytes.data() + offset, static_cast<DWORD>(bytes.size() - offset), &count, nullptr) || !count) throw std::runtime_error("Could not read the ACP project file"); offset += count;}
        if (!valid_utf8(bytes)) throw std::invalid_argument("ACP can only read UTF-8 text files"); return bytes;
    }
    void write(const std::string& requested, const std::string& bytes) const {
        if (bytes.size() > max_bytes || !valid_utf8(bytes)) throw std::invalid_argument("ACP can write UTF-8 text files up to 8 MB");
        const auto value = literal(requested); auto pinned = parents(value.parent_path(), true, true);
        std::vector<unsigned char> security;
        const auto attributes = GetFileAttributesW(value.c_str());
        if (attributes != INVALID_FILE_ATTRIBUTES) {
            NativeHandle previous(CreateFileW(value.c_str(), GENERIC_READ | READ_CONTROL, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr)); inspect(previous.get());
            if (attributes & FILE_ATTRIBUTE_READONLY) throw std::invalid_argument("The ACP project file is read-only");
            DWORD needed{}; GetKernelObjectSecurity(previous.get(), DACL_SECURITY_INFORMATION, nullptr, 0, &needed);
            if (!needed || needed > 1024 * 1024) throw std::runtime_error("Could not preserve the ACP file permissions"); security.resize(needed);
            if (!GetKernelObjectSecurity(previous.get(), DACL_SECURITY_INFORMATION, reinterpret_cast<PSECURITY_DESCRIPTOR>(security.data()), needed, &needed)) throw std::runtime_error("Could not preserve the ACP file permissions");
        }
        GUID id{}; if (FAILED(CoCreateGuid(&id))) throw std::runtime_error("Could not create a unique ACP write");
        wchar_t text[40]{}; StringFromGUID2(id, text, 40); const auto temporary = value.parent_path() / (L".coincide-acp-" + std::wstring(text) + L".tmp");
        struct Cleanup {std::filesystem::path value; ~Cleanup() {DeleteFileW(value.c_str());}} cleanup{temporary};
        NativeHandle file(CreateFileW(temporary.c_str(), GENERIC_WRITE | FILE_READ_ATTRIBUTES | WRITE_DAC, FILE_SHARE_READ, nullptr, CREATE_NEW, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
        if (file.get() == INVALID_HANDLE_VALUE) throw std::runtime_error("Could not prepare the ACP project write");
        if (!security.empty() && !SetKernelObjectSecurity(file.get(), DACL_SECURITY_INFORMATION, reinterpret_cast<PSECURITY_DESCRIPTOR>(security.data()))) throw std::runtime_error("Could not preserve the ACP file permissions");
        std::size_t offset{};
        while (offset < bytes.size()) {DWORD count{}; if (!WriteFile(file.get(), bytes.data() + offset, static_cast<DWORD>(bytes.size() - offset), &count, nullptr) || !count) throw std::runtime_error("Could not write the ACP project file"); offset += count;}
        if (!FlushFileBuffers(file.get())) throw std::runtime_error("Could not flush the ACP project write"); file.reset();
        // MoveFileEx replaces the directory entry (including a raced leaf symlink), never follows it.
        // Every ancestor remains pinned, so the replacement cannot escape into another directory.
        if (!MoveFileExW(temporary.c_str(), value.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) throw std::runtime_error("Could not replace the ACP project file");
    }
    static std::wstring wide(const std::string& value) {
        if (!valid_utf8(value) || value.find('\0') != std::string::npos) throw std::invalid_argument("Invalid ACP UTF-8 text");
        if (value.empty()) return {}; const auto count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
        std::wstring result(static_cast<std::size_t>(count), L'\0'); MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), count); return result;
    }
    static bool valid_utf8(const std::string& value) {return value.empty() || (value.size() <= INT_MAX && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0) > 0);}
private:
    std::filesystem::path root_; NativeHandle root_handle_; std::wstring root_name_;
    std::vector<std::filesystem::path> root_aliases_;
    static std::filesystem::path root_alias(std::filesystem::path value) {
        value = value.lexically_normal();
        while (value != value.root_path() && !value.has_filename()) value = value.parent_path();
        return value;
    }
    static void validate_literal(const std::filesystem::path& value) {
        const auto name = value.wstring();
        if (!value.is_absolute() || name.size() > 240 || name.starts_with(L"\\\\") || name.find_first_of(L"\0*?<>|\"", 0, 7) != std::wstring::npos || name.find(L':', 2) != std::wstring::npos || value.root_name().wstring().size() != 2)
            throw std::invalid_argument("ACP requires a literal absolute local Windows path");
        unsigned depth{};
        for (const auto& part : value.relative_path()) {
            auto component = part.wstring(); if (component.empty() || component == L"." || component == L".." || component.back() == L'.' || component.back() == L' ' || ++depth > 64) throw std::invalid_argument("ACP refuses ambiguous path components");
            component = component.substr(0, component.find(L'.')); std::transform(component.begin(), component.end(), component.begin(), [](wchar_t ch) {return static_cast<wchar_t>(std::towupper(ch));});
            if (component == L"CON" || component == L"PRN" || component == L"AUX" || component == L"NUL" || component == L"CLOCK$" || ((component.starts_with(L"COM") || component.starts_with(L"LPT")) && component.size() == 4 && component[3] >= L'0' && component[3] <= L'9'))
                throw std::invalid_argument("ACP refuses Windows device path aliases");
        }
    }
    static NativeHandle directory(const std::filesystem::path& value) {
        NativeHandle handle(CreateFileW(value.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
        if (handle.get() == INVALID_HANDLE_VALUE) throw std::runtime_error("Could not pin the ACP project directory");
        BY_HANDLE_FILE_INFORMATION info{};
        if (!GetFileInformationByHandle(handle.get(), &info) || !(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) throw std::invalid_argument("ACP refuses linked project directories");
        return handle;
    }
    static std::wstring final_name(HANDLE handle) {
        wchar_t name[32768]{}; const auto count = GetFinalPathNameByHandleW(handle, name, 32768, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
        if (!count || count >= 32768) throw std::runtime_error("Could not resolve the ACP project handle"); return std::wstring(name, count);
    }
    void inspect(HANDLE handle) const {
        BY_HANDLE_FILE_INFORMATION info{};
        if (handle == INVALID_HANDLE_VALUE || GetFileType(handle) != FILE_TYPE_DISK || !GetFileInformationByHandle(handle, &info)) throw std::runtime_error("Could not open the ACP project file");
        if ((info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_OFFLINE | 0x00400000 | 0x00040000)) || info.nNumberOfLinks > 1) throw std::invalid_argument("ACP refuses linked, remote or placeholder files");
        const auto name = final_name(handle); const auto prefix = root_name_.ends_with(L'\\') ? root_name_ : root_name_ + L"\\";
        if (name.size() <= prefix.size() || CompareStringOrdinal(name.data(), static_cast<int>(prefix.size()), prefix.data(), static_cast<int>(prefix.size()), TRUE) != CSTR_EQUAL) throw std::invalid_argument("The ACP file handle resolves outside the project");
    }
    std::vector<NativeHandle> parents(const std::filesystem::path& value, bool include_leaf, bool create) const {
        std::vector<NativeHandle> result;
        auto folder = root_; const auto relative = value.lexically_relative(root_);
        if (relative.empty() || relative == L".") return result;
        unsigned depth{};
        for (const auto& part : relative) {
            if (part == L".." || ++depth > 64) throw std::invalid_argument("The ACP directory is outside the project");
            folder /= part;
            if (create && !CreateDirectoryW(folder.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) throw std::runtime_error("Could not create the ACP project directory");
            result.push_back(directory(folder));
        }
        static_cast<void>(include_leaf); return result;
    }
};
} // namespace coincide
