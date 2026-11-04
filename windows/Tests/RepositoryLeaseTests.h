#pragma once
#include "../Runtime/RepositoryLease.h"
#include "GitRepositoryIdentityTests.h"

namespace coincide {
inline int repository_lease_tests(const std::filesystem::path& report){
    using namespace repository_lease;using namespace git_identity_fixture;std::size_t checks{};
    const auto check=[&](bool value,const char* message){++checks;if(!value)throw std::runtime_error(message);};
    try{
        Directory owned;const auto main=owned.folder(L"main"),first=owned.folder(L"first/src"),second=owned.folder(L"second"),other=owned.folder(L"other");
        owned.folder(L"main/.git/worktrees/first");owned.folder(L"main/.git/worktrees/second");owned.folder(L"other/.git");
        owned.write(L"first/.git","gitdir: ../main/.git/worktrees/first\n");owned.write(L"second/.git","gitdir: ../main/.git/worktrees/second\n");
        owned.write(L"main/.git/worktrees/first/commondir","../..\n");owned.write(L"main/.git/worktrees/second/commondir","../..\n");
        check(conflicts({main,main},first),"A mutation in the main checkout must reserve an active linked worktree");
        check(conflicts({first,first},second),"Sibling worktrees must reserve their shared repository metadata");
        check(conflicts({second,second},first),"Repository leases must protect agents and mutations in both directions");
        check(!conflicts({main,main},other),"An independent active repository must not block a mutation");
        check(conflicts({main,owned.path/L"new-review"},owned.path),"An active ancestor must protect a future review-worktree folder");
        check(!conflicts({main,owned.path/L"new-review"},other),"A future worktree may be created while an unrelated repository is active");
        check(conflicts({other,first},first),"A mutation target must be reserved independently of its source repository");
        check(conflicts({main,main},main/L"missing-child"),"A contained active path stays protected even if currently unavailable");
        const auto broken=owned.folder(L"broken");owned.write(L"broken/.git","unsupported metadata\n");
        check(conflicts({main,main},broken),"Unproved active repository metadata must fail closed");
        check(conflicts({broken,broken},other),"Unproved mutation metadata must fail closed");
        check(conflicts({{},{}},other),"A mutation without a repository must not acquire a lease");
        check(contains(main,main)&&!contains(main,owned.path/L"main-suffix"),"Directory boundaries must not confuse similarly named repositories");
        std::filesystem::rename(second,owned.path/L"second-moved");
        check(std::filesystem::is_directory(owned.path/L"second-moved"),"Short lease decisions must release their directory pins before returning");
        std::ofstream output(report);output<<"PASS: "<<checks<<" repository/worktree lease checks\n";return output?0:2;
    }catch(const std::exception& error){std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';return 1;}
}
} // namespace coincide
