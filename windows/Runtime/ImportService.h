#pragma once
#include "LocalFileRead.h"
#include "../Core/Workspace.h"
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <map>
#include <cmath>
#include <cctype>
#include <optional>
#include <set>
#include <unordered_map>

namespace coincide {
namespace import_json=winrt::Windows::Data::Json;
struct ImportOrigin{
    std::string external_id,kind,timestamp,model,title,detail,status;
};
struct ImportPreview{
    std::filesystem::path source_path;
    std::string source_fingerprint,provider,session_id,directory,title,model,branch,created_at,updated_at;
    std::uint64_t source_size{};
    std::vector<Message> messages;
    std::vector<ImportOrigin> origins;
    std::vector<std::string> unknown_types;
    std::size_t omitted_records{},redacted_texts{};
    bool shortened_text{};
};
struct ImportRoot{std::string provider;std::filesystem::path path;};
struct ImportCandidate{std::filesystem::path path;std::string provider,title,directory;std::uint64_t modified{};};
struct ImportScan{std::vector<ImportCandidate> candidates;bool incomplete{};};

class ImportService{
    using Object=import_json::JsonObject;using Array=import_json::JsonArray;using Value=import_json::JsonValue;
public:
    static constexpr std::size_t maximum_bytes=32*1024*1024,maximum_record=4*1024*1024,maximum_records=100000,maximum_text=100000;
    static std::vector<ImportRoot> default_roots(std::filesystem::path user_home=local_file::home()){
        const auto claude=local_file::environment_path(L"CLAUDE_CONFIG_DIR",user_home/L".claude"),codex=local_file::environment_path(L"CODEX_HOME",user_home/L".codex");
        return{{"claude",claude/L"projects"},{"codex",codex/L"sessions"},{"codex",codex/L"archived_sessions"}};
    }
    static ImportScan scan(const std::vector<ImportRoot>& roots,std::size_t limit=2000){
        if(limit>2000||roots.size()>16)throw std::invalid_argument("Session discovery exceeds its bounded roots or session limit");
        ImportScan result;std::vector<ImportCandidate> found;std::size_t visited{};std::set<std::wstring> seen;
        for(const auto& root:roots){
            if(root.provider!="claude"&&root.provider!="codex")throw std::invalid_argument("Unsupported session history provider");
            if(!local_file::local_path(root.path)||local_file::has_reparse(root.path)){result.incomplete=true;continue;}
            std::error_code error;if(!std::filesystem::exists(root.path,error))continue;
            for(std::filesystem::recursive_directory_iterator it(root.path,std::filesystem::directory_options::skip_permission_denied,error),end;!error&&it!=end;it.increment(error)){
                if(++visited>20000){result.incomplete=true;break;}
                const auto name=it->path().filename().wstring();if(local_file::reparse(it->path())||local_file::lower(name)==L"subagents"||it.depth()>12){it.disable_recursion_pending();continue;}
                if(!it->is_regular_file(error)||local_file::lower(it->path().extension().wstring())!=L".jsonl")continue;
                const auto key=local_file::lower(it->path().wstring());if(!seen.insert(key).second)continue;
                const auto stamp=it->last_write_time(error);if(error){result.incomplete=true;error.clear();continue;}
                found.push_back({it->path(),root.provider,winrt::to_string(it->path().stem().wstring()),{},static_cast<std::uint64_t>(stamp.time_since_epoch().count())});
            }
            if(error)result.incomplete=true;if(visited>20000)break;
        }
        std::sort(found.begin(),found.end(),[](const auto& a,const auto& b){return a.modified>b.modified;});if(found.size()>limit)result.incomplete=true;
        for(std::size_t index=0;index<std::min(limit,found.size());++index){
            auto candidate=std::move(found[index]);
            try{
                const auto prefix=local_file::read(candidate.path,128*1024,false,true);auto records=parse_lines(prefix.bytes,100,true);bool title{};std::size_t ignored{};
                for(const auto& record:records){
                    if(candidate.provider=="claude"){
                        if(const auto cwd=text(record,L"cwd");!cwd.empty())candidate.directory=cwd;
                        if(const auto value=text(record,L"aiTitle");!value.empty()){candidate.title=redact(short_text(value,100),ignored);title=true;}
                        if(!title&&text(record,L"type")=="user"&&!boolean(record,L"isMeta")){const auto message=object(record,L"message");const auto value=render(message.GetNamedValue(L"content",Value::CreateNullValue()));if(!value.empty()){candidate.title=redact(short_text(value,100),ignored);title=true;}}
                    }else{const auto payload=object(record,L"payload");if(text(record,L"type")=="session_meta")candidate.directory=text(payload,L"cwd");if(!title&&text(record,L"type")=="response_item"&&text(payload,L"role")=="user"){const auto value=render(payload.GetNamedValue(L"content",Value::CreateNullValue()));if(!value.empty()){candidate.title=redact(short_text(value,100),ignored);title=true;}}}
                }
                result.candidates.push_back(std::move(candidate));
            }catch(...){result.incomplete=true;}
        }return result;
    }
    static ImportPreview preview(const std::filesystem::path& path){
        if(local_file::lower(path.extension().wstring())!=L".jsonl")throw std::invalid_argument("Choose a Claude Code session or Codex rollout JSONL file");
        const auto source=local_file::read(path,maximum_bytes);auto result=parse(source.bytes,path);result.source_fingerprint=source.digest;result.source_size=source.size;return result;
    }
    static void verify_unchanged(const ImportPreview& preview){
        const auto current=local_file::read(preview.source_path,maximum_bytes);
        if(current.digest!=preview.source_fingerprint||current.size!=preview.source_size)throw std::runtime_error("The session changed after its preview; refresh before importing");
    }
    static std::optional<std::string> duplicate_thread(const ImportPreview& preview,const Workspace& workspace){
        for(const auto& thread:workspace.threads)for(const auto& session:thread.sessions)if(session.provider==preview.provider){try{if(uuid(session.id)==preview.session_id)return thread.id;}catch(const std::invalid_argument&){}}
        return std::nullopt;
    }
    // Explicitly allowlisted provenance, never the original JSON object, auth records or source bytes.
    static Object provenance(const ImportPreview& preview){
        Object value;const auto put=[&](const wchar_t* key,const std::string& text){value.SetNamedValue(key,Value::CreateStringValue(winrt::to_hstring(text)));};
        value.SetNamedValue(L"version",Value::CreateNumberValue(1));put(L"provider",preview.provider);put(L"sessionID",preview.session_id);put(L"sourcePath",winrt::to_string(preview.source_path.wstring()));put(L"sourceSHA256",preview.source_fingerprint);put(L"directory",preview.directory);put(L"createdAt",preview.created_at);put(L"updatedAt",preview.updated_at);put(L"branch",preview.branch);
        value.SetNamedValue(L"sourceBytes",Value::CreateNumberValue(static_cast<double>(preview.source_size)));value.SetNamedValue(L"omittedRecords",Value::CreateNumberValue(static_cast<double>(preview.omitted_records)));value.SetNamedValue(L"redactedTexts",Value::CreateNumberValue(static_cast<double>(preview.redacted_texts)));value.SetNamedValue(L"shortenedText",Value::CreateBooleanValue(preview.shortened_text));
        Array origins;for(const auto& origin:preview.origins){Object item;for(const auto& [key,text]:std::vector<std::pair<const wchar_t*,std::string>>{{L"externalID",origin.external_id},{L"kind",origin.kind},{L"timestamp",origin.timestamp},{L"model",origin.model},{L"title",origin.title},{L"detail",origin.detail},{L"status",origin.status}})item.SetNamedValue(key,Value::CreateStringValue(winrt::to_hstring(text)));origins.Append(item);}value.SetNamedValue(L"origins",origins);
        Array unknown;for(const auto& name:preview.unknown_types)unknown.Append(Value::CreateStringValue(winrt::to_hstring(name)));value.SetNamedValue(L"omittedTypes",unknown);return value;
    }
    static ImportPreview parse(std::string_view bytes,const std::filesystem::path& source_path){
        if(bytes.size()>maximum_bytes||!local_file::utf8(bytes))throw std::invalid_argument("The session must be bounded UTF-8 JSONL");
        ImportPreview result;result.source_path=source_path;result.source_size=bytes.size();result.source_fingerprint=local_file::sha256(bytes);
        const auto records=parse_lines(bytes,maximum_records,false,&result.omitted_records);bool codex{},claude{};
        for(const auto& record:records){codex=codex||text(record,L"type")=="session_meta";claude=claude||(!text(record,L"sessionId").empty()&&!text(record,L"cwd").empty());}
        if(codex==claude)throw std::invalid_argument("The source is not one supported Claude Code or Codex conversation");
        result.provider=codex?"codex":"claude";Parser parser{result};if(codex)parser.codex(records);else parser.claude(records);
        if(parser.sessions.size()!=1||!absolute_origin(result.directory))throw std::invalid_argument("A session must have one UUID identity and an absolute working directory");result.session_id=*parser.sessions.begin();
        if(std::none_of(result.messages.begin(),result.messages.end(),[](const auto& message){return message.role=="user"||message.role=="assistant";}))throw std::invalid_argument("The session has no supported user or assistant messages");
        if(result.title.empty()){const auto first=std::find_if(result.messages.begin(),result.messages.end(),[](const auto& message){return message.role=="user";});result.title=first==result.messages.end()?result.provider:first->text;}
        result.title=single_line(short_text(result.title,100));if(result.title.empty())result.title=result.provider;
        if(result.model.find_first_of(" \t\r\n")!=std::string::npos||result.model.find('\0')!=std::string::npos)result.model.clear();
        result.title=redact(result.title,result.redacted_texts);result.model=redact(result.model,result.redacted_texts);result.branch=redact(result.branch,result.redacted_texts);
        for(std::size_t i=0;i<result.messages.size();++i)result.messages[i].id="import/"+result.provider+"/"+result.session_id+"/"+std::to_string(i+1);return result;
    }
private:
    static std::string text(const Object& value,const wchar_t* key){const auto entry=value.GetNamedValue(key,Value::CreateNullValue());return entry.ValueType()==import_json::JsonValueType::String?winrt::to_string(entry.GetString()):"";}
    static bool boolean(const Object& value,const wchar_t* key){const auto entry=value.GetNamedValue(key,Value::CreateNullValue());return entry.ValueType()==import_json::JsonValueType::Boolean&&entry.GetBoolean();}
    static Object object(const Object& value,const wchar_t* key){const auto entry=value.GetNamedValue(key,Value::CreateNullValue());return entry.ValueType()==import_json::JsonValueType::Object?entry.GetObject():Object{};}
    static bool absolute_origin(const std::string& path){if(path.empty()||path.find('\0')!=std::string::npos||path.size()>32768)return false;return path.starts_with('/')||path.starts_with("\\\\")||(path.size()>2&&std::isalpha(static_cast<unsigned char>(path[0]))&&path[1]==':'&&(path[2]=='\\'||path[2]=='/'));}
    static std::string uuid(const std::string& value){
        try{if(value.size()!=36&&value.size()!=38)throw std::invalid_argument("Invalid native session UUID");auto result=winrt::to_string(winrt::to_hstring(winrt::guid(winrt::to_hstring(value))));if(result.starts_with('{'))result=result.substr(1,result.size()-2);for(auto& ch:result)ch=static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));return result;}catch(const winrt::hresult_error&){throw std::invalid_argument("Invalid native session UUID");}
    }
    static std::string short_text(std::string_view value,std::size_t maximum=maximum_text){std::size_t offset{},count{};while(offset<value.size()&&count<maximum){(void)workspace_text::next(value,offset);++count;}return std::string(value.substr(0,offset));}
    static std::string single_line(std::string_view text){std::string result;for(std::size_t at=0;at<text.size();){const auto first=at;const auto code=workspace_text::next(text,at);if(workspace_text::whitespace(code)||code<32||(code>=127&&code<=159)){if(!result.empty()&&result.back()!=' ')result+=' ';}else result.append(text.substr(first,at-first));}if(result.ends_with(' '))result.pop_back();return result;}
    static std::string redact(std::string value,std::size_t& count){
        const auto original=value;std::string result;result.reserve(value.size());
        const auto word=[](unsigned char ch){return std::isalnum(ch)||ch=='_'||ch=='-';};
        const auto secret=[](unsigned char ch){return std::isalnum(ch)||ch=='_'||ch=='-'||ch=='.'||ch=='~'||ch=='+'||ch=='/'||ch=='=';};
        for(std::size_t i=0;i<value.size();){
            const auto rest=std::string_view(value).substr(i);
            if(rest.starts_with("-----BEGIN ")){
                const auto header_end=value.find('\n',i);const auto marker=value.find("PRIVATE KEY-----",i);
                if(marker!=std::string::npos&&(header_end==std::string::npos||marker<header_end)){
                    const auto finish=value.find("-----END ",marker);const auto end=finish==std::string::npos?std::string::npos:value.find("-----",finish+9);
                    result+="[REDACTED PRIVATE KEY]";i=end==std::string::npos?value.size():end+5;continue;
                }
            }
            bool token{};for(const auto prefix:{"sk-","ghp_","gho_","ghu_","ghs_","ghr_","github_pat_","xoxb-","xoxp-","xoxa-","xoxr-","xoxs-","AKIA"})if(rest.starts_with(prefix)){const auto first=i+std::char_traits<char>::length(prefix);auto end=first;while(end<value.size()&&word(static_cast<unsigned char>(value[end])))++end;if(end-first>=16){result+="[REDACTED]";i=end;token=true;}break;}if(token)continue;
            if(word(static_cast<unsigned char>(value[i]))){
                auto end=i+1;while(end<value.size()&&word(static_cast<unsigned char>(value[end])))++end;auto key=value.substr(i,end-i);for(auto& ch:key)ch=static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
                auto at=end;if(at<value.size()&&(value[at]=='"'||value[at]=='\''))++at;while(at<value.size()&&std::isspace(static_cast<unsigned char>(value[at])))++at;
                if(key=="bearer"&&at>end){auto finish=at;while(finish<value.size()&&secret(static_cast<unsigned char>(value[finish])))++finish;if(finish-at>=8){result.append(value,i,at-i);result+="[REDACTED]";i=finish;continue;}}
                const bool assigned=key=="api_key"||key=="api-key"||key=="apikey"||key=="access_token"||key=="access-token"||key=="refresh_token"||key=="refresh-token"||key=="client_secret"||key=="password"||key=="authorization"||key=="secret_key"||key=="token"||key=="cookie"||key=="set-cookie";
                if(assigned&&at<value.size()&&(value[at]==':'||value[at]=='=')){
                    ++at;while(at<value.size()&&std::isspace(static_cast<unsigned char>(value[at])))++at;auto finish=at;
                    if(at<value.size()&&(value[at]=='"'||value[at]=='\'')){const auto quote=value[at++];finish=at;while(finish<value.size()&&value[finish]!=quote)++finish;result.append(value,i,at-i);result+="[REDACTED]";i=finish;continue;}
                    if(key=="authorization"||key=="cookie"||key=="set-cookie"){while(finish<value.size()&&value[finish]!='\r'&&value[finish]!='\n')++finish;}
                    else while(finish<value.size()&&!std::isspace(static_cast<unsigned char>(value[finish]))&&std::string_view(",;}&").find(value[finish])==std::string_view::npos)++finish;
                    if(finish>at){result.append(value,i,at-i);result+="[REDACTED]";i=finish;continue;}
                }
                result.append(value,i,end-i);i=end;continue;
            }
            if(value[i]=='\0')result+="�";else result+=value[i];++i;
        }
        if(result!=original)++count;return result;
    }
    static bool sensitive_key(std::string key){for(auto& ch:key)ch=static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));return key.find("token")!=std::string::npos||key.find("password")!=std::string::npos||key.find("secret")!=std::string::npos||key=="authorization"||key=="api_key"||key=="apikey"||key=="private_key"||key=="credential"||key=="cookie"||key=="cookies";}
    static import_json::IJsonValue sanitized_json(const import_json::IJsonValue& value,unsigned depth=0,std::size_t* redacted=nullptr){
        if(depth>12)return Value::CreateStringValue(L"[omitted nested data]");
        if(value.ValueType()==import_json::JsonValueType::Object){Object result;std::size_t count{};for(const auto& field:value.GetObject()){if(++count>1000)break;if(sensitive_key(winrt::to_string(field.Key()))){result.SetNamedValue(field.Key(),Value::CreateStringValue(L"[REDACTED]"));if(redacted)++*redacted;}else result.SetNamedValue(field.Key(),sanitized_json(field.Value(),depth+1,redacted));}return result;}
        if(value.ValueType()==import_json::JsonValueType::Array){Array result;std::size_t count{};for(const auto& item:value.GetArray()){if(++count>1000)break;result.Append(sanitized_json(item,depth+1,redacted));}return result;}return value;
    }
    static std::string render(const import_json::IJsonValue& value,std::size_t* redacted=nullptr){
        if(value.ValueType()==import_json::JsonValueType::String)return winrt::to_string(value.GetString());
        if(value.ValueType()==import_json::JsonValueType::Array){std::string result;for(const auto& block:value.GetArray()){if(block.ValueType()!=import_json::JsonValueType::Object)continue;const auto content=text(block.GetObject(),L"text");if(!content.empty()){if(!result.empty())result+='\n';result+=content;}}return result;}
        if(value.ValueType()==import_json::JsonValueType::Object)return winrt::to_string(sanitized_json(value,0,redacted).Stringify());return{};
    }
    static std::vector<Object> parse_lines(std::string_view bytes,std::size_t limit,bool prefix,std::size_t* omitted=nullptr){
        std::vector<Object> result;std::size_t records{},start{};if(bytes.starts_with("\xef\xbb\xbf"))bytes.remove_prefix(3);
        while(start<bytes.size()){
            const auto end=bytes.find('\n',start);if(prefix&&end==std::string_view::npos)break;if(++records>limit){if(prefix)break;throw std::invalid_argument("The session exceeds 100,000 records");}
            auto line=bytes.substr(start,end==std::string_view::npos?bytes.size()-start:end-start);start=end==std::string_view::npos?bytes.size():end+1;
            if(line.size()>maximum_record)throw std::invalid_argument("A session record exceeds 4 MB");if(line.find_first_not_of(" \r\t")==std::string_view::npos)continue;
            Object value{nullptr};if(Object::TryParse(winrt::to_hstring(line),value))result.push_back(value);else if(omitted)++*omitted;
        }return result;
    }
    struct Parser{
        ImportPreview& result;std::set<std::string> sessions;std::unordered_map<std::string,std::size_t> tools;std::size_t next{};
        std::string clean(std::string value){const auto shortened=short_text(value);if(shortened.size()<value.size()){result.shortened_text=true;value=shortened+"\n…";}return redact(std::move(value),result.redacted_texts);}
        static std::string timestamp(const Object& record){const auto value=text(record,L"timestamp");if(value.size()<20||value.size()>64||value[4]!='-'||value[7]!='-'||value[10]!='T'||!std::all_of(value.begin(),value.end(),[](unsigned char ch){return std::isdigit(ch)||std::string_view("-TtZz:+.").find(static_cast<char>(ch))!=std::string_view::npos;}))return{};return value;}
        void time(const Object& record){const auto value=timestamp(record);if(value.empty())return;if(result.created_at.empty()||value<result.created_at)result.created_at=value;if(result.updated_at.empty()||value>result.updated_at)result.updated_at=value;}
        void unknown(std::string type){++result.omitted_records;type=short_text(type,128);if(!type.empty()&&result.unknown_types.size()<64&&std::find(result.unknown_types.begin(),result.unknown_types.end(),type)==result.unknown_types.end())result.unknown_types.push_back(std::move(type));}
        void append(std::string role,std::string content,const Object& record,std::string external={},std::string kind={}){
            if(content.empty())return;if(result.messages.size()>=100000)throw std::invalid_argument("The session contains too many imported messages");
            result.messages.push_back({"import/"+result.provider+"/"+std::to_string(++next),std::move(role),clean(std::move(content)),result.provider});
            result.origins.push_back({clean(short_text(external,512)),kind.empty()?result.messages.back().role:std::move(kind),timestamp(record),clean(short_text(result.model,256)),{},{},"completed"});
        }
        void call(const std::string& id,const std::string& name,const Value& input,const Object& record){
            if(id.empty()||tools.contains(id))return;const auto detail=clean(render(input,&result.redacted_texts));tools[id]=result.messages.size();append("tool","No result was recorded in this session.",record,id,"tool");auto& origin=result.origins.back();origin.title=clean(name.empty()?"tool":name);origin.detail=detail;origin.status="failed";
        }
        void answer(const std::string& id,const Value& output,bool failed,const Object& record){
            const auto content=clean(render(output,&result.redacted_texts));const auto found=tools.find(id);if(found!=tools.end()&&found->second<result.messages.size()){result.messages[found->second].text=content;result.origins[found->second].status=failed?"failed":"completed";}
            else append("tool",content,record,id,"notice");
        }
        void claude(const std::vector<Object>& records){
            std::map<std::string,std::size_t> positions;std::map<std::string,std::string> parents;std::string leaf;
            for(std::size_t i=0;i<records.size();++i){const auto record=records[i];if(boolean(record,L"isSidechain"))continue;
                if(const auto id=text(record,L"sessionId");!id.empty())sessions.insert(uuid(id));if(const auto cwd=text(record,L"cwd");!cwd.empty())result.directory=cwd;
                if(const auto branch=text(record,L"gitBranch");!branch.empty())result.branch=short_text(branch,1024);if(const auto title=text(record,L"aiTitle");!title.empty())result.title=title;
                if(const auto id=text(record,L"uuid");!id.empty()){positions[id]=i;if(record.HasKey(L"message"))leaf=id;if(const auto parent=text(record,L"parentUuid");!parent.empty())parents[id]=parent;}
            }
            std::set<std::string> ancestry;if(!leaf.empty()&&!parents.empty()){auto cursor=leaf;while(positions.contains(cursor)){if(!ancestry.insert(cursor).second)throw std::invalid_argument("The Claude conversation ancestry contains a cycle");const auto parent=parents.find(cursor);if(parent==parents.end())break;cursor=parent->second;}}
            for(std::size_t i=0;i<records.size();++i){const auto record=records[i];if(boolean(record,L"isSidechain"))continue;time(record);if(!record.HasKey(L"message"))continue;
                const auto id=text(record,L"uuid");if(!id.empty()&&(positions[id]!=i||(!ancestry.empty()&&!ancestry.contains(id)))){++result.omitted_records;continue;}
                if(boolean(record,L"isMeta")){++result.omitted_records;continue;}const auto message=object(record,L"message");auto role=text(message,L"role");if(role.empty())role=text(record,L"type");if(role!="user"&&role!="assistant"){unknown("claude/role");continue;}
                if(const auto model=text(message,L"model");!model.empty()&&model!="<synthetic>")result.model=short_text(model,256);
                const auto content=message.GetNamedValue(L"content",Value::CreateNullValue());if(content.ValueType()==import_json::JsonValueType::String){append(role,render(content),record,id);continue;}
                if(content.ValueType()!=import_json::JsonValueType::Array){unknown("claude/content");continue;}std::string prose;std::size_t block_index{};
                const auto flush=[&]{append(role,prose,record,id+"/text/"+std::to_string(block_index++));prose.clear();};
                for(const auto& value:content.GetArray()){
                    if(value.ValueType()!=import_json::JsonValueType::Object){unknown("claude/block");continue;}const auto block=value.GetObject();const auto type=text(block,L"type");
                    if(type=="text"){if(!prose.empty())prose+='\n';prose+=text(block,L"text");}
                    else if(type=="thinking"){flush();append("tool",text(block,L"thinking"),record,id+"/reasoning/"+std::to_string(block_index++),"reasoning");}
                    else if(type=="tool_use"){flush();call(text(block,L"id"),text(block,L"name"),block.GetNamedValue(L"input",Value::CreateNullValue()),record);}
                    else if(type=="tool_result"){flush();answer(text(block,L"tool_use_id"),block.GetNamedValue(L"content",Value::CreateNullValue()),boolean(block,L"is_error"),record);}
                    else unknown("claude/"+type);
                }flush();
            }
        }
        void codex(const std::vector<Object>& records){
            const bool canonical=std::any_of(records.begin(),records.end(),[](const auto& record){const auto payload=object(record,L"payload");return text(record,L"type")=="response_item"&&text(payload,L"type")=="message"&&(text(payload,L"role")=="user"||text(payload,L"role")=="assistant");});std::set<std::string> seen;
            for(const auto& record:records){time(record);const auto type=text(record,L"type");const auto payload=object(record,L"payload");
                if(type=="session_meta"){auto id=text(payload,L"id");if(id.empty())id=text(payload,L"session_id");if(!id.empty())sessions.insert(uuid(id));if(const auto cwd=text(payload,L"cwd");!cwd.empty())result.directory=cwd;result.branch=short_text(text(object(payload,L"git"),L"branch"),1024);}
                else if(type=="turn_context"){if(const auto cwd=text(payload,L"cwd");!cwd.empty())result.directory=cwd;if(const auto model=text(payload,L"model");!model.empty())result.model=short_text(model,256);}
                else if(type=="response_item"){
                    const auto id=text(payload,L"id");if(!id.empty()&&!seen.insert(id).second)continue;const auto kind=text(payload,L"type");
                    if(kind=="message"){const auto role=text(payload,L"role");if(role=="user"||role=="assistant")append(role,render(payload.GetNamedValue(L"content",Value::CreateNullValue())),record,id);}
                    else if(kind=="reasoning")append("tool",render(payload.GetNamedValue(L"summary",Value::CreateNullValue())),record,id,"reasoning");
                    else if(kind=="function_call"||kind=="custom_tool_call")call(text(payload,L"call_id"),text(payload,L"name"),payload.GetNamedValue(kind=="function_call"?L"arguments":L"input",Value::CreateNullValue()),record);
                    else if(kind=="function_call_output"||kind=="custom_tool_call_output")answer(text(payload,L"call_id"),payload.GetNamedValue(L"output",Value::CreateNullValue()),false,record);
                    else unknown("codex/"+kind);
                }else if(type=="event_msg"){
                    const auto kind=text(payload,L"type");if(!canonical&&(kind=="user_message"||kind=="agent_message"))append(kind=="user_message"?"user":"assistant",render(payload.GetNamedValue(L"message",Value::CreateNullValue())),record);
                    else if(kind=="thread_rolled_back"){const auto count=payload.GetNamedNumber(L"num_turns",0);if(count>0&&count==std::floor(count)){std::vector<std::size_t> starts;for(std::size_t i=0;i<result.messages.size();++i)if(result.messages[i].role=="user")starts.push_back(i);if(!starts.empty()){const auto remove=count>=static_cast<double>(starts.size())?0:starts.size()-static_cast<std::size_t>(count);const auto first=starts[remove];result.messages.resize(first);result.origins.resize(first);tools.clear();for(std::size_t i=0;i<result.origins.size();++i)if(result.origins[i].kind=="tool")tools[result.origins[i].external_id]=i;}}}
                }else unknown(type);
            }
        }
    };
};
} // namespace coincide
