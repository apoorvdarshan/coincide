#pragma once
#include "../Runtime/ProjectFileIndex.h"
#include "GitRepositoryIdentityTests.h"

namespace coincide {
inline int project_file_index_tests(const std::filesystem::path& report){
    unsigned checks{};const auto check=[&](bool value,const char* why){++checks;if(!value)throw std::runtime_error(why);};const auto rejects=[&](auto action,const char* why){bool rejected{};try{action();}catch(...){rejected=true;}check(rejected,why);};
    try{
        git_identity_fixture::Directory owned;const auto root=owned.folder(L"project"),outside=owned.folder(L"outside");
        owned.write(L"project/README.md","Owned source bytes are never read by the index");owned.write(L"project/src/main.cpp","int main(){}");owned.write(L"project/App File.swift","Owned source");owned.write(L"project/src/你好.txt","Owned Unicode source");
        owned.write(L"project/.env","Owned fake data");owned.write(L"project/.git/config","Owned fake data");owned.write(L"project/node_modules/dependency.js","Owned fake data");owned.write(L"project/build/output.bin","Owned fake data");const auto secret=owned.write(L"outside/private.txt","Owned outside fixture");
        if(!CreateHardLinkW((root/L"hardlink.txt").c_str(),secret.c_str(),nullptr))throw std::runtime_error("Could not prepare the owned hard-link fixture");
        git_identity_fixture::Junction escape(root/L"escape",outside);
        auto index=ProjectFileIndex::scan(root);check(index.files.size()==4&&!index.limited&&index.skipped>=5,"A scan must include regular project files and exclude hidden data, dependencies, hard links and junctions");
        const auto entry=[&](std::string_view path){const auto found=std::find_if(index.files.begin(),index.files.end(),[&](const auto& value){return value.path==path;});if(found==index.files.end())throw std::runtime_error("Owned project file missing from index");return *found;};
        check(entry("src/你好.txt").path=="src/你好.txt"&&entry("App File.swift").path=="App File.swift","File names must preserve Unicode and spaces without reading contents");
        auto pin=ProjectFileIndex::verify(index.scope,entry("src/main.cpp"));check(pin&&pin->file.get()!=INVALID_HANDLE_VALUE,"The selected nested file must retain its exact metadata identity");
        check(!MoveFileExW((root/L"src/main.cpp").c_str(),(root/L"src/moved.cpp").c_str(),0),"A verified file must stay pinned through insertion");pin.reset();
        const auto original=entry("README.md");std::filesystem::rename(root/L"README.md",root/L"README-old.md");owned.write(L"project/README.md","Replacement identity");rejects([&]{ProjectFileIndex::verify(index.scope,original);},"A replaced path must not reuse a previously selected file identity");
        rejects([&]{ProjectFileIndex::verify(index.scope,{"../outside/private.txt",{}});},"A forged relative entry must not escape the selected project");
        rejects([&]{ProjectFileIndex::scan(std::filesystem::path(L"C:relative"));},"Drive-relative roots must be rejected");
        bool cancelled{};try{ProjectFileIndex::scan(root,[]{return true;});}catch(const ProjectFileIndex::Cancelled&){cancelled=true;}check(cancelled,"A canceled request must stop before filesystem discovery");
        {git_identity_fixture::Junction linked(owned.path/L"linked-root",root);rejects([&]{ProjectFileIndex::scan(linked.path);},"A linked project root must not be followed");}
        const auto nested=entry("src/main.cpp");std::filesystem::rename(root/L"src",root/L"src-original");
        {git_identity_fixture::Junction replaced(root/L"src",outside);rejects([&]{ProjectFileIndex::verify(index.scope,nested);},"Replacing a parent with a junction must be rejected before inspecting its target");}
        check(!MoveFileExW(root.c_str(),(owned.path/L"moved-project").c_str(),0),"The selected project root must remain pinned while suggestions exist");
        index={};std::ofstream output(report);output<<"PASS: "<<checks<<" project file index checks; owned metadata only\n";return output?0:2;
    }catch(const std::exception& error){std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';}catch(...){std::ofstream(report)<<"FAIL after "<<checks<<" checks: native project-file API failure\n";}return 1;
}
} // namespace coincide
