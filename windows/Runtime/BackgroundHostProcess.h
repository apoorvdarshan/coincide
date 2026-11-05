#pragma once
#include "HostIPC.h"

namespace coincide::background_host {
// On-demand detached process only: no service, login task, registry/startup setting or global
// install. The caller must explicitly enable this host. Closing this handle never kills it.
class DetachedProcess {
    Handle process_;DWORD pid_{};
    static std::wstring quote(std::wstring_view value){std::wstring out=L"\"";std::size_t slashes{};for(const auto ch:value){if(ch==L'\\'){++slashes;continue;}if(ch==L'\"')out.append(slashes*2+1,L'\\');else out.append(slashes,L'\\');slashes=0;out+=ch;}out.append(slashes*2,L'\\');out+=L'\"';return out;}
public:
    DetachedProcess()=default;DetachedProcess(DetachedProcess&&)=default;DetachedProcess& operator=(DetachedProcess&&)=default;
    static DetachedProcess start(const std::filesystem::path& executable,const std::vector<std::wstring>& arguments,const std::filesystem::path& cwd){if(!local_file::local_path(executable)||!std::filesystem::is_regular_file(executable)||!local_file::local_path(cwd)||!std::filesystem::is_directory(cwd)||arguments.size()>16)throw std::invalid_argument("Background host requires an explicit local packaged executable and app folder");DWORD flags=CREATE_NO_WINDOW;BOOL in_job{};if(!IsProcessInJob(GetCurrentProcess(),nullptr,&in_job))winrt::throw_last_error();if(in_job){JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};if(!QueryInformationJobObject(nullptr,JobObjectExtendedLimitInformation,&limits,sizeof(limits),nullptr)||!(limits.BasicLimitInformation.LimitFlags&(JOB_OBJECT_LIMIT_BREAKAWAY_OK|JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK)))throw std::runtime_error("The current app job cannot detach a background host; sessions must remain in the app");if(limits.BasicLimitInformation.LimitFlags&JOB_OBJECT_LIMIT_BREAKAWAY_OK)flags|=CREATE_BREAKAWAY_FROM_JOB;}
        std::wstring command=quote(executable.wstring());for(const auto& value:arguments){if(value.size()>32768||value.find(L'\0')!=std::wstring::npos)throw std::invalid_argument("Invalid detached host argument");command+=L" "+quote(value);}if(command.size()>32760)throw std::invalid_argument("Detached host command exceeds Windows bounds");STARTUPINFOW startup{sizeof(startup)};PROCESS_INFORMATION info{};if(!CreateProcessW(executable.c_str(),command.data(),nullptr,nullptr,FALSE,flags,nullptr,cwd.c_str(),&startup,&info))throw std::runtime_error("The background host could not be detached; no runtime ownership was transferred");Handle thread(info.hThread);DetachedProcess result;result.process_.reset(info.hProcess);result.pid_=info.dwProcessId;return result;}
    DWORD pid()const{return pid_;}bool alive()const{return process_&&WaitForSingleObject(process_.value,0)==WAIT_TIMEOUT;}HANDLE handle()const{return process_.value;}
    // Only fixture coordinators call this on the exact process handle they created. Production
    // uses authenticated interrupt/shutdown/retire commands, never image-name process kills.
    bool terminate_owned_fixture()noexcept{if(!process_)return true;return TerminateProcess(process_.value,ERROR_CANCELLED)&&WaitForSingleObject(process_.value,3000)==WAIT_OBJECT_0;}
};
} // namespace coincide::background_host
