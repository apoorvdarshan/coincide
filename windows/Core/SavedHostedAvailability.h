#pragma once
#include <optional>
#include <string>

namespace coincide {
struct SavedHostedAvailability {
    bool enabled{},metadata_available{true},journal_retired{},runtime_unmatched{};
    std::optional<std::string> saved_epoch,journal_epoch;
    // This is an availability restriction, never proof that earlier input was not
    // delivered. It changes no journal, saved prefix, provider or input identity.
    bool needs_review()const noexcept {
        if(!enabled)return false;
        if(!metadata_available)return true;
        if(journal_retired)return false;
        if(saved_epoch.has_value()!=journal_epoch.has_value())return true;
        if(saved_epoch&&(saved_epoch->empty()||journal_epoch->empty()||saved_epoch!=journal_epoch))return true;
        return runtime_unmatched;
    }
};
} // namespace coincide
