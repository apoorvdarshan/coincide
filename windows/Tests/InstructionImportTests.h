#pragma once
#include "../Runtime/InstructionService.h"
#include "../Runtime/ImportService.h"
#include <fstream>

namespace coincide {
namespace instruction_import_fixture {
struct Directory{
    std::filesystem::path path;
    Directory():path(std::filesystem::temp_directory_path()/(L"Coincide instruction import fixture "+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()))){if(!std::filesystem::create_directory(path))throw std::runtime_error("The unique instruction/import fixture directory exists");}
    ~Directory(){std::error_code ignored;std::filesystem::remove_all(path,ignored);}
    std::filesystem::path write(const std::filesystem::path& relative,std::string_view bytes){const auto file=path/relative;std::filesystem::create_directories(file.parent_path());std::ofstream stream(file,std::ios::binary);stream.write(bytes.data(),static_cast<std::streamsize>(bytes.size()));if(!stream)throw std::runtime_error("Could not write the owned fixture source");return file;}
};
inline std::string records(std::initializer_list<std::string> values){std::string result;for(const auto& value:values)result+=value+'\n';return result;}
inline const std::string session="a0000000-0000-0000-0000-000000000001";
inline std::string codex(std::string type,std::string payload){return "{\"timestamp\":\"2026-11-04T10:00:00Z\",\"type\":\""+type+"\",\"payload\":"+payload+"}";}
inline std::string meta(std::string id=session){return codex("session_meta","{\"id\":\""+id+"\",\"cwd\":\"C:\\\\fixture\\\\project\",\"git\":{\"branch\":\"feature\"},\"auth\":{\"token\":\"fixture-auth-metadata-must-not-import\"}}");}
inline std::string claude(std::string id,std::string parent,std::string role,std::string content,std::string extra={}){
    return "{\"uuid\":\""+id+"\",\"parentUuid\":\""+parent+"\",\"sessionId\":\""+session+"\",\"cwd\":\"C:\\\\fixture\\\\project\",\"timestamp\":\"2026-11-04T10:00:00.123Z\",\"type\":\""+role+"\",\"message\":{\"role\":\""+role+"\",\"content\":"+content+"}"+(extra.empty()?"":","+extra)+"}";
}
inline std::string canonical(){return records({meta(),codex("turn_context",R"({"model":"gpt-fixture","approval_policy":"never"})"),codex("event_msg",R"({"type":"user_message","message":"duplicate event"})"),
    codex("response_item",R"({"id":"u","type":"message","role":"user","content":[{"type":"input_text","text":"Fix the fixture"}]})"),
    codex("response_item",R"({"type":"function_call","call_id":"call-1","name":"read_file","arguments":{"path":"example.txt","api_key":"fixture-credential-must-not-import"}})"),
    codex("response_item",R"({"type":"function_call_output","call_id":"call-1","output":"file contents"})"),
    codex("response_item",R"({"id":"a","type":"message","role":"assistant","content":[{"type":"output_text","text":"Fixed it"}]})"),
    codex("response_item",R"({"id":"a","type":"message","role":"assistant","content":[{"type":"output_text","text":"Fixed it"}]})"),codex("future_event",R"({"token":"fixture-unknown-metadata-must-not-import"})")});}
}

inline int instruction_tests(const std::filesystem::path& report){
    std::size_t checks{},skipped{};const auto check=[&](bool value,const char* message){++checks;if(!value)throw std::runtime_error(message);};
    const auto rejects=[&](auto action,const char* message){bool rejected{};try{action();}catch(...){rejected=true;}check(rejected,message);};
    try{
        using namespace instruction_import_fixture;Directory fixture;const auto project=fixture.path/L"project";std::filesystem::create_directory(project);
        fixture.write(L"project/AGENTS.md","agents\n");fixture.write(L"project/CLAUDE.md","claude\n");fixture.write(L"project/GEMINI.md","gemini\n");fixture.write(L"project/AGENTS.override.md","override\n");fixture.write(L"project/CLAUDE.local.md","local\n");fixture.write(L"project/.claude/CLAUDE.md","claude directory\n");fixture.write(L"project/.cursor/rules/style.mdc","cursor\n");fixture.write(L"project/src/nested/AGENTS.md","nested\n");fixture.write(L"project/node_modules/dependency/AGENTS.md","must not enumerate\n");fixture.write(L"project/build/AGENTS.md","must not enumerate\n");
        const auto scan=InstructionService::project_files(project);
        check(scan.files.size()==8&&!scan.incomplete,"discovery must include known top-level/nested rules and exclude dependencies/build output");
        check(scan.files[0].path.filename()==L"AGENTS.md"&&scan.files[1].path.filename()==L"CLAUDE.md"&&scan.files[2].path.filename()==L"GEMINI.md","top-level instruction ordering must match the Mac discovery order");
        check(InstructionService::readers(L"AGENTS.override.md")==std::vector<std::string>{"codex"}&&InstructionService::readers(L"CLAUDE.md",true)==std::vector<std::string>{"claude","grok"},"instruction readers must retain provider-specific names and compatibility");
        const auto original=local_file::read(project/L"AGENTS.md",1024);const auto reading=InstructionService::read(scan.files[0]);
        check(reading.text=="agents\n"&&reading.fingerprint==original.digest&&local_file::read(project/L"AGENTS.md",1024).bytes==original.bytes,"instruction previews must preserve exact source bytes and never write the file");
        check(InstructionService::project_files(project,0).files.size()==7,"depth zero must exclude nested project folders while retaining root provider rules");
        check(InstructionService::project_files(project,6,1).incomplete,"instruction folder bounds must be reported as incomplete");
        const auto empty=fixture.path/L"empty";std::filesystem::create_directory(empty);const auto missing=InstructionService::project_files(empty);
        check(missing.files.size()==3&&std::none_of(missing.files.begin(),missing.files.end(),[](const auto& file){return file.exists;}),"missing top-level instructions should be shown as paths without creating them");
        const auto home=fixture.path/L"home";InstructionLocations locations{home,home/L".claude",home/L".codex",home/L".grok",home/L".config/opencode",home/L".gemini",home/L".config/coincide"};
        const auto master=fixture.write(L"home/.config/coincide/AGENTS.md","fixture global master remains unchanged\n");fixture.write(L"home/.codex/AGENTS.md","codex\n");
        const auto global=InstructionService::global_files(locations);
        check(global.files.front().protected_master&&InstructionService::read(global.files.front()).text=="fixture global master remains unchanged\n","global master discovery is read-only and explicit");
        check(local_file::sha256("abc")=="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","source fingerprints must use exact SHA-256 bytes");
        const auto unicode=fixture.write(L"ПРОЕКТ/AGENTS.md","unicode case\n");check(local_file::read(unicode.parent_path().parent_path()/L"проект"/L"AGENTS.md",1024).bytes=="unicode case\n","resolved source identity must use Windows ordinal Unicode case comparison");
        auto shared_locations=locations;shared_locations.codex=locations.coincide;const auto shared=InstructionService::global_files(shared_locations);
        check(shared.files.front().protected_master&&std::find(shared.files.front().readers.begin(),shared.files.front().readers.end(),"codex")!=shared.files.front().readers.end(),"overlapping global provider homes must merge readers without hiding the protected master");
        fixture.write(L"empty/AGENTS.md",std::string_view("a\0b",3));const auto binary=InstructionService::project_files(empty);rejects([&]{InstructionService::read(binary.files[0]);},"instruction previews must reject NUL-bearing content");
        fixture.write(L"empty/AGENTS.md",std::string(1024*1024+1,'x'));const auto large=InstructionService::project_files(empty);rejects([&]{InstructionService::read(large.files[0]);},"instruction reads must enforce the one MB bound");
        // Discovery returns paths beneath its canonical selected root. Windows runners may
        // provide TEMP through an 8.3 alias (RUNNER~1), so retain the link name under that root.
        const auto linked=std::filesystem::canonical(project)/L"linked";std::filesystem::create_directory(linked);
        if(CreateSymbolicLinkW((linked/L"CLAUDE.md").c_str(),(project/L"AGENTS.md").c_str(),SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)){
            const auto links=InstructionService::project_files(project);const auto at=std::find_if(links.files.begin(),links.files.end(),[&](const auto& file){return file.path==linked/L"CLAUDE.md";});
            check(at!=links.files.end()&&at->linked&&InstructionService::read(*at).text=="agents\n","read-only in-project instruction links must retain their identity and resolve safely");
            check(local_file::reparse(linked/L"CLAUDE.md"),"previewing a link must never replace it");
            std::array<wchar_t,32768> short_name{};const auto short_length=GetShortPathNameW(project.c_str(),short_name.data(),static_cast<DWORD>(short_name.size()));
            if(short_length&&short_length<short_name.size()){
                const auto alias=InstructionService::project_files(std::filesystem::path(short_name.data()));const auto preserved=std::find_if(alias.files.begin(),alias.files.end(),[&](const auto& file){return file.path==linked/L"CLAUDE.md";});
                check(preserved!=alias.files.end()&&preserved->linked&&InstructionService::read(*preserved).text=="agents\n","canonical discovery through a Windows short-path alias must preserve the actual instruction link identity");
            }
            if(CreateSymbolicLinkW((linked/L"AGENTS.md").c_str(),master.c_str(),SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE)){
                const auto external=InstructionService::project_files(project);const auto out=std::find_if(external.files.begin(),external.files.end(),[&](const auto& file){return file.path==linked/L"AGENTS.md";});check(out!=external.files.end()&&!out->readable,"project instruction links outside the selected scope must not be read automatically");
            }else ++skipped;
        }else skipped+=3;
        std::ofstream output(report);output<<"PASS: "<<checks<<" Windows instruction checks; "<<skipped<<" link checks skipped if Windows does not permit fixture symlinks\n";return output?0:2;
    }catch(const std::exception& error){std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';return 1;}catch(const winrt::hresult_error&){std::ofstream(report)<<"FAIL: Windows instruction fixture API error\n";return 1;}
}

inline int import_tests(const std::filesystem::path& report){
    std::size_t checks{};const auto check=[&](bool value,const char* message){++checks;if(!value)throw std::runtime_error(message);};const auto rejects=[&](auto action,const char* message){bool rejected{};try{action();}catch(...){rejected=true;}check(rejected,message);};
    try{
        using namespace instruction_import_fixture;Directory fixture;const auto path=fixture.write(L"codex/sessions/2026/fixture.jsonl",canonical());const auto original=local_file::read(path,ImportService::maximum_bytes);
        const auto preview=ImportService::preview(path);
        check(preview.provider=="codex"&&preview.session_id==session&&preview.model=="gpt-fixture"&&preview.branch=="feature","native session UUID, provider and safe model/branch metadata must survive import preview");
        check(preview.messages.size()==3&&preview.messages[0].role=="user"&&preview.messages[1].role=="tool"&&preview.messages[2].role=="assistant","Codex canonical messages must supersede duplicate event messages and repeated native IDs");
        check(preview.messages[0].text=="Fix the fixture"&&preview.messages[1].text=="file contents"&&preview.messages[2].text=="Fixed it"&&preview.origins[1].status=="completed","tool results must pair with their original call without duplicating transcript rows");
        check(preview.origins.size()==preview.messages.size()&&preview.origins[1].external_id=="call-1"&&preview.origins[1].title=="read_file"&&!preview.created_at.empty(),"supported transcript origins and timestamps must be retained in allowlisted provenance");
        const auto provenance=winrt::to_string(ImportService::provenance(preview).Stringify());
        check(provenance.find("fixture-auth-metadata-must-not-import")==std::string::npos&&provenance.find("fixture-credential-must-not-import")==std::string::npos&&provenance.find("fixture-unknown-metadata-must-not-import")==std::string::npos,"auth/config metadata, sensitive tool keys and unknown payload values must never be copied into import provenance");
        check(preview.redacted_texts>0&&preview.omitted_records==1&&preview.unknown_types==std::vector<std::string>{"future_event"},"unsupported records and redacted fields must be explicitly counted");
        ImportService::verify_unchanged(preview);check(local_file::read(path,ImportService::maximum_bytes).bytes==original.bytes,"preview and unchanged verification must leave the original source bytes intact");
        Workspace workspace;Thread existing;existing.id="existing-thread";existing.sessions.push_back({"codex","A0000000-0000-0000-0000-000000000001",3});workspace.threads.push_back(existing);
        check(ImportService::duplicate_thread(preview,workspace)==std::optional<std::string>{"existing-thread"},"duplicate detection must use provider plus case-normalized native session identity");
        workspace.threads.front().sessions.front().provider="claude";check(!ImportService::duplicate_thread(preview,workspace),"equal native UUIDs from distinct providers must not collide");
        fixture.write(L"codex/sessions/2026/fixture.jsonl",canonical()+"{partial");rejects([&]{ImportService::verify_unchanged(preview);},"a changed source must be rejected after preview before the explicit import transaction");
        const auto partial=ImportService::preview(path);check(partial.omitted_records==2&&partial.messages.size()==3,"an interrupted final JSONL record must be counted without duplicating supported content");
        const auto branch=records({claude("u","","user","\"root\""),claude("old","u","assistant","\"old branch\""),claude("side","u","assistant","\"sidechain\"","\"isSidechain\":true"),
            claude("new","u","assistant",R"([{"type":"thinking","thinking":"reason"},{"type":"text","text":"new branch"},{"type":"tool_use","id":"read","name":"Read","input":{"path":"file.txt"}}])"),
            claude("result","new","user",R"([{"type":"tool_result","tool_use_id":"read","content":"tool failed","is_error":true}])"),claude("end","result","assistant",R"([{"type":"text","text":"done"},{"type":"future","token":"not imported"}])")});
        const auto claude_preview=ImportService::parse(branch,path);
        check(claude_preview.provider=="claude"&&claude_preview.messages.size()==5&&claude_preview.messages[1].text=="reason"&&claude_preview.origins[1].kind=="reasoning","Claude preview must follow the latest main ancestry and retain supported reasoning");
        check(claude_preview.messages[2].text=="new branch"&&claude_preview.messages[3].text=="tool failed"&&claude_preview.origins[3].status=="failed"&&claude_preview.omitted_records==2,"Claude old forks/sidechains must not leak into the selected main branch and tool failure must remain explicit");
        rejects([&]{ImportService::parse(records({claude("u","a","user","\"root\""),claude("a","u","assistant","\"cycle\"")}),path);},"Claude ancestry cycles must fail without guessing a branch");
        const auto rollback=ImportService::parse(records({meta(),codex("event_msg",R"({"type":"user_message","message":"keep"})"),codex("event_msg",R"({"type":"agent_message","message":"kept answer"})"),codex("event_msg",R"({"type":"user_message","message":"remove"})"),codex("event_msg",R"({"type":"agent_message","message":"removed answer"})"),codex("event_msg",R"({"type":"thread_rolled_back","num_turns":1})")}),path);
        check(rollback.messages.size()==2&&rollback.messages[0].text=="keep"&&rollback.messages[1].text=="kept answer","older Codex event-only histories must honor exact rolled-back user turn boundaries");
        rejects([&]{ImportService::parse(records({meta("invalid"),codex("event_msg",R"({"type":"user_message","message":"x"})")}),path);},"invalid native session UUIDs must be rejected");
        rejects([&]{ImportService::parse(canonical()+meta("b0000000-0000-0000-0000-000000000002")+'\n',path);},"mixed native session identities must not be merged");
        rejects([&]{ImportService::parse(canonical()+claude("mixed","","user","\"x\"")+'\n',path);},"mixed provider formats must fail closed");
        rejects([&]{ImportService::parse("{\"access_token\":\"fixture-config-only\"}\n",path);},"auth-only JSONL must not be recognized as a conversation");
        rejects([&]{ImportService::preview(fixture.write(L"codex/auth.json","{\"token\":\"fixture-only\"}"));},"manual file selection must not accept provider auth/config JSON files");
        rejects([&]{ImportService::parse(std::string(ImportService::maximum_bytes+1,' '),path);},"native imports must enforce the 32 MB source cap");
        rejects([&]{ImportService::parse(std::string(ImportService::maximum_record+1,' '),path);},"native imports must enforce the 4 MB record cap");
        std::string many;for(unsigned i=0;i<100001;++i)many+="{}\n";rejects([&]{ImportService::parse(many,path);},"native imports must enforce the 100,000 record cap");
        std::string long_text;for(unsigned i=0;i<100001;++i)long_text+="अ";import_json::JsonObject message;message.SetNamedValue(L"type",import_json::JsonValue::CreateStringValue(L"user_message"));message.SetNamedValue(L"message",import_json::JsonValue::CreateStringValue(winrt::to_hstring(long_text)));
        const auto shortened=ImportService::parse(records({meta(),codex("event_msg",winrt::to_string(message.Stringify()))}),path);
        check(shortened.shortened_text&&local_file::utf8(shortened.messages[0].text)&&shortened.messages[0].text.size()<long_text.size()+4,"long native text must shorten at Unicode code-point boundaries");
        const auto secret=ImportService::parse(records({meta(),codex("event_msg",R"({"type":"user_message","message":"Authorization: Bearer fixture-plain-credential-value\npassword=fixture-password\n{\"api_key\":\"fixture-json-key\"}"})")}),path);
        check(secret.messages[0].text.find("fixture-plain-credential-value")==std::string::npos&&secret.messages[0].text.find("fixture-password")==std::string::npos&&secret.messages[0].text.find("fixture-json-key")==std::string::npos,"recognized authorization headers, assignments and JSON key values must be redacted from supported text");
        const auto title=ImportService::parse(records({meta(),codex("event_msg",R"({"type":"user_message","message":"\tIndented\nquestion\u2028next"})")}),path);
        check(title.title=="Indented question next"&&workspace_text::label(title.title,4096)==title.title,"imported titles must normalize whitespace/control characters into valid native thread metadata");
        const auto control=ImportService::parse(records({meta(),codex("turn_context",R"({"model":"invalid model"})"),codex("event_msg",R"({"type":"user_message","message":"prompt"})")}),path);
        check(control.model.empty(),"unsafe model metadata must not enter provider runtime settings");
        fixture.write(L"codex/sessions/subagents/skip.jsonl",canonical());fixture.write(L"codex/sessions/auth.json","must not enumerate");
        const auto scan=ImportService::scan({{"codex",fixture.path/L"codex/sessions"}});
        check(scan.candidates.size()==1&&scan.candidates[0].provider=="codex"&&scan.candidates[0].title=="Fix the fixture","session scanning must stay in configured history roots, skip subagents/auth JSON and inspect only bounded prefixes");
        check(ImportService::scan({{"codex",fixture.path/L"codex/sessions"}},0).incomplete,"session discovery limits must be explicit without importing any source");
        std::ofstream output(report);output<<"PASS: "<<checks<<" Windows native session import checks\n";return output?0:2;
    }catch(const std::exception& error){std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';return 1;}catch(const winrt::hresult_error&){std::ofstream(report)<<"FAIL: Windows import fixture API error\n";return 1;}
}
} // namespace coincide
