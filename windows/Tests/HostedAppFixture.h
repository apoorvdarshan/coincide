#pragma once
#include <filesystem>
namespace coincide::tests {
// Test-only host. The fixed temporary marker and exact application image are mandatory.
int run_hosted_app_fixture(const std::filesystem::path& directory) noexcept;
// Prepares only an authenticated empty synthetic host from a caller outside a restrictive
// UI test job. No Start/input/provider operation is sent. Zero means ready and empty;
// nonzero preserves uncertain ownership and never authorizes an in-app fallback.
int bootstrap_hosted_app_fixture(const std::filesystem::path& directory) noexcept;
}
