#pragma once
#include "LocalFileRead.h"
#include <deque>
#include <set>

namespace coincide {
struct InstructionLocations{
    std::filesystem::path home,claude,codex,grok,opencode,gemini,coincide;
    static InstructionLocations standard(std::filesystem::path user_home=local_file::home()){
        return {user_home,local_file::environment_path(L"CLAUDE_CONFIG_DIR",user_home/L".claude"),local_file::environment_path(L"CODEX_HOME",user_home/L".codex"),
            local_file::environment_path(L"GROK_HOME",user_home/L".grok"),local_file::environment_path(L"XDG_CONFIG_HOME",user_home/L".config")/L"opencode",user_home/L".gemini",user_home/L".config"/L"coincide"};
    }
};
struct InstructionFile{
    std::filesystem::path path,resolved,scope_root,global_master;
    std::string display_name,note;
    std::vector<std::string> readers;
    bool exists{},linked{},readable{},protected_master{};
};
struct InstructionScan{std::vector<InstructionFile> files;bool incomplete{};};
struct InstructionPreview{InstructionFile file;std::string text,fingerprint;};
class InstructionService{
public:
    static std::vector<std::string> readers(std::wstring_view name,bool claude_folder=false){
        if(claude_folder)return name==L"CLAUDE.md"?std::vector<std::string>{"claude","grok"}:std::vector<std::string>{};
        if(name==L"AGENTS.md")return{"codex","cursor","grok","opencode","antigravity"};if(name==L"AGENTS.override.md")return{"codex"};
        if(name==L"CLAUDE.md"||name==L"CLAUDE.local.md")return{"claude","grok"};if(name==L"GEMINI.md")return{"antigravity"};if(name==L".cursorrules"||name.ends_with(L".mdc"))return{"cursor"};return{};
    }
    static InstructionScan project_files(const std::filesystem::path& project,unsigned maximum_depth=6,std::size_t folder_limit=4000){
        if(!local_file::local_path(project)||!std::filesystem::is_directory(project)||maximum_depth>12||folder_limit>10000)throw std::invalid_argument("Choose an available local project folder with bounded discovery limits");
        const auto root=std::filesystem::canonical(project);InstructionScan result;
        for(const auto name:{L"AGENTS.md",L"CLAUDE.md",L"GEMINI.md"})add(result,root/name,root,{});
        std::deque<std::pair<std::filesystem::path,unsigned>> pending{{root,0}};std::size_t visited{},entries{};
        const std::set<std::wstring> skipped{L".git",L".hg",L".svn",L"node_modules",L".build",L"build",L"deriveddata",L"pods",L"carthage",L"vendor",L"dist",L".venv",L"venv",L"target",L".next",L".nuxt",L".turbo",L".cache",L"__pycache__",L".gradle",L".idea"};
        while(!pending.empty()&&visited<folder_limit&&entries<20000&&result.files.size()<1000){
            auto [folder,depth]=std::move(pending.front());pending.pop_front();++visited;std::error_code error;
            std::vector<std::filesystem::directory_entry> children;
            for(std::filesystem::directory_iterator it(folder,std::filesystem::directory_options::skip_permission_denied,error),end;!error&&it!=end;it.increment(error)){if(++entries>20000)break;children.push_back(*it);}
            if(error)result.incomplete=true;std::sort(children.begin(),children.end(),[](const auto& a,const auto& b){return a.path().filename()<b.path().filename();});
            for(const auto& child:children){const auto name=child.path().filename().wstring();
                if((name==L"AGENTS.md"||name==L"CLAUDE.md"||name==L"GEMINI.md")&&child.path().parent_path()!=root)add(result,child.path(),root,{});
                else if(name==L"AGENTS.override.md"||name==L"CLAUDE.local.md"||name==L".cursorrules")add(result,child.path(),root,{});
                if(name==L".claude"&&!local_file::reparse(child.path())){const auto path=child.path()/L"CLAUDE.md";if(std::filesystem::exists(path,error))add(result,path,root,{},true);}
                if(name==L".cursor"&&!local_file::reparse(child.path()))cursor_rules(result,child.path()/L"rules",root);
                if(depth<maximum_depth&&!name.starts_with(L".")&&!skipped.contains(local_file::lower(name))&&!local_file::reparse(child.path())&&child.is_directory(error))pending.emplace_back(child.path(),depth+1);
            }
        }
        result.incomplete=result.incomplete||!pending.empty()||entries>=20000||result.files.size()>=1000;merge_readers(result);return result;
    }
    static InstructionScan global_files(const InstructionLocations& locations){
        InstructionScan result;const auto master=locations.coincide/L"AGENTS.md";
        for(const auto& [path,provider]:std::vector<std::pair<std::filesystem::path,std::string>>{{master,""},{locations.claude/L"CLAUDE.md","claude"},{locations.codex/L"AGENTS.md","codex"},{locations.codex/L"AGENTS.override.md","codex"},
                {locations.grok/L"AGENTS.md","grok"},{locations.opencode/L"AGENTS.md","opencode"},{locations.gemini/L"GEMINI.md","antigravity"},{locations.gemini/L"AGENTS.md","antigravity"}}){
            const auto before=result.files.size();add(result,path,path.parent_path(),master);auto& file=*std::find_if(result.files.begin(),result.files.end(),[&](const auto& entry){return same(entry.path,path);});
            if(result.files.size()!=before)file.readers=provider.empty()?std::vector<std::string>{}:std::vector<std::string>{provider};else if(!provider.empty())file.readers.push_back(provider);
            if(path==master)file.note="Global master (read only)";
        }
        if(locations.claude.lexically_normal()!= (locations.home/L".claude").lexically_normal()){
            std::error_code error;const auto standard=locations.home/L".claude"/L"CLAUDE.md";if(std::filesystem::exists(standard,error)){add(result,standard,standard.parent_path(),master);result.files.back().readers={"grok"};}
        }else result.files[1].readers.push_back("grok");
        merge_readers(result);return result;
    }
    static InstructionPreview read(const InstructionFile& file){
        if(!file.readable||!file.exists||!instruction_target(file.path))throw std::runtime_error("This instruction path is missing or outside its readable scope");
        const auto expected=std::filesystem::weakly_canonical(file.path);
        const bool scoped=local_file::within(file.scope_root,expected);
        const bool master=!file.global_master.empty()&&same(expected,std::filesystem::weakly_canonical(file.global_master));
        if((!scoped&&!master)||!text_extension(expected))throw std::runtime_error("The instruction link resolves outside the selected scope");
        const auto snapshot=local_file::read(file.path,1024*1024,true,false,expected);
        auto text=snapshot.bytes;if(text.starts_with("\xef\xbb\xbf"))text.erase(0,3);
        if(!local_file::utf8(text)||text.find('\0')!=std::string::npos)throw std::runtime_error("Instruction preview requires UTF-8 text without NUL bytes");
        return{file,std::move(text),snapshot.digest};
    }
private:
    static bool same(const std::filesystem::path& a,const std::filesystem::path& b){return local_file::equal_path(a.wstring(),b.wstring());}
    static bool instruction_target(const std::filesystem::path& path){const auto name=path.filename().wstring();return !readers(name).empty()||name==L"AGENTS.md";}
    static bool text_extension(const std::filesystem::path& path){const auto extension=local_file::lower(path.extension().wstring());return extension==L".md"||extension==L".mdc"||path.filename()==L".cursorrules";}
    static void add(InstructionScan& result,const std::filesystem::path& path,const std::filesystem::path& scope,const std::filesystem::path& master,bool claude_folder=false){
        if(result.files.size()>=1000){result.incomplete=true;return;}
        if(std::any_of(result.files.begin(),result.files.end(),[&](const auto& file){return same(file.path,path);}))return;
        InstructionFile file;file.path=path;file.scope_root=scope;file.global_master=master;file.readers=readers(path.filename().wstring(),claude_folder);file.linked=local_file::reparse(path);
        std::error_code error;file.resolved=std::filesystem::weakly_canonical(path,error);if(error)file.resolved=path.lexically_normal();file.exists=std::filesystem::is_regular_file(path,error);
        file.protected_master=!master.empty()&&(same(path,master)||same(file.resolved,std::filesystem::weakly_canonical(master,error)));
        file.readable=file.exists&&local_file::local_path(file.resolved)&&text_extension(file.resolved)&&(local_file::within(scope,file.resolved)||file.protected_master);
        const auto relative=path.lexically_relative(scope);file.display_name=winrt::to_string((relative.empty()?path:relative).wstring());result.files.push_back(std::move(file));
    }
    static void merge_readers(InstructionScan& scan){for(auto& file:scan.files){std::set<std::string> all(file.readers.begin(),file.readers.end());for(const auto& other:scan.files)if(same(other.resolved,file.resolved))all.insert(other.readers.begin(),other.readers.end());file.readers.assign(all.begin(),all.end());}}
    static void cursor_rules(InstructionScan& scan,const std::filesystem::path& rules,const std::filesystem::path& project){
        if(local_file::has_reparse(rules))return;std::error_code error;if(!std::filesystem::is_directory(rules,error))return;std::size_t visited{};
        for(std::filesystem::recursive_directory_iterator it(rules,std::filesystem::directory_options::skip_permission_denied,error),end;!error&&it!=end;it.increment(error)){
            if(++visited>4000||scan.files.size()>=1000){scan.incomplete=true;break;}
            if(local_file::reparse(it->path())||it.depth()>=6){it.disable_recursion_pending();continue;}
            if(it->path().extension()==L".mdc"&&it->is_regular_file(error))add(scan,it->path(),project,{});
        }if(error)scan.incomplete=true;
    }
};
} // namespace coincide
