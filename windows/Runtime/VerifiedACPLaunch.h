#pragma once
#include "ProviderAccounts.h"

namespace coincide {
// The app supplies its explicit selected account and historical native binding. Construction
// checks cached metadata only; the worker performs fresh native status before every delivery.
inline ACPLaunchOptions make_verified_acp_options(const ACPLaunchSpec& spec,const ProviderAccountProgram& program,
        const ProviderAccountRecord& record,const std::filesystem::path& profile,const std::filesystem::path& cache,
        const ProviderAccountMetadata& metadata,const std::string& saved_scope={},bool resuming=false) {
    if(spec.provider!="cursor"||program.provider!=spec.provider||record.provider!=spec.provider||program.command_prefix!=spec.options.command_prefix)
        throw std::invalid_argument("This ACP provider has no compatible verified Windows account flow yet");
    std::error_code error;if(!std::filesystem::equivalent(program.executable,spec.executable,error)||error)throw std::invalid_argument("The account check and ACP runtime must use the same native provider program");
    auto bound=ProviderAccounts::bind(spec,record,profile,cache,metadata,saved_scope,resuming);auto result=std::move(bound.options);
    result.provider=record.provider;result.profile_id=record.id;result.executable=bound.executable;
    const auto pinned_profile=result.profile_lease->root();
    result.verify_account=[program,record,pinned_profile](const std::shared_ptr<std::atomic_bool>& cancel) {
        const auto current=ProviderAccounts::check(program,record,pinned_profile,cancel);
        if(!ProviderAccounts::current(current,record,pinned_profile))throw std::runtime_error("Verify the original provider account before continuing this ACP conversation");
        return ACPVerifiedAccount{record.id,current.scope,current.identity_source,current.label,current.credential_revision};
    };
    result.credential_revision=[pinned_profile,provider=record.provider]{return ProviderAccounts::credential_revision(pinned_profile,provider);};
    return result;
}
} // namespace coincide
