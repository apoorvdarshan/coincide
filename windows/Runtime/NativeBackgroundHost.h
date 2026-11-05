#pragma once
#include <filesystem>

namespace coincide {
// Invoke only for the fixed --background-agent-host <physical-data-directory> mode,
// before initializing the normal UI apartment. No UI, registration or startup task.
// 0: orderly exit; 2: invalid scope/apartment/image; 3: host setup/runtime failure.
int run_native_background_host(const std::filesystem::path& physical_data_directory) noexcept;
} // namespace coincide
