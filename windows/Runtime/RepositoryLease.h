#pragma once
#include "GitRepositoryIdentity.h"

namespace coincide::repository_lease {
struct Mutation {std::filesystem::path repository,target;};
inline bool contains(const std::filesystem::path& folder,const std::filesystem::path& candidate){
    auto parent=std::filesystem::weakly_canonical(folder).wstring();const auto child=std::filesystem::weakly_canonical(candidate).wstring();
    while(parent.size()>3&&(parent.back()==L'\\'||parent.back()==L'/'))parent.pop_back();
    if(parent.empty()||parent.size()>INT_MAX||child.size()<parent.size()||CompareStringOrdinal(parent.data(),static_cast<int>(parent.size()),child.data(),static_cast<int>(parent.size()),TRUE)!=CSTR_EQUAL)return false;
    return child.size()==parent.size()||parent.back()==L'\\'||parent.back()==L'/'||child[parent.size()]==L'\\'||child[parent.size()]==L'/';
}
// The target can be a not-yet-created review worktree. Its path reserves that folder;
// the existing source repository reserves shared Git metadata across sibling worktrees.
// All physical identity pins end with this short lease decision.
inline bool conflicts(const Mutation& mutation,const std::filesystem::path& active_folder){
    try{
        if(mutation.repository.empty()||active_folder.empty())return true;
        const auto overlaps=[&](const auto& path){return !path.empty()&&(contains(path,active_folder)||contains(active_folder,path));};
        if(overlaps(mutation.repository)||overlaps(mutation.target))return true;
        const auto repository=git_identity::lookup(mutation.repository),active=git_identity::lookup(active_folder);
        if(repository.state==git_identity::State::unavailable||active.state==git_identity::State::unavailable)return true;
        return repository.value&&active.value&&git_identity::same_repository(*repository.value,*active.value);
    }catch(...){return true;}
}
} // namespace coincide::repository_lease
