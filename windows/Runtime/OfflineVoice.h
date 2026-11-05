#pragma once
#include "WindowsProcess.h"
#include "LocalFileRead.h"
#include "VoiceAudio.h"
#include <sddl.h>
#include <atomic>
#include <span>
#pragma comment(lib,"advapi32.lib")

namespace coincide {
struct OfflineVoiceOptions {
    std::filesystem::path executable,models_root,model,working_root;
    std::string language="auto";
    unsigned threads=4;
    std::chrono::milliseconds timeout=std::chrono::minutes(10);
};

// Worker-only adapter for an explicitly configured, locally installed native whisper.cpp CLI.
// It never downloads an engine/model, reads account settings, uses a shell or uploads audio.
class OfflineVoice {
public:
    static constexpr std::size_t maximum_transcript_bytes=256*1024;
    static void validate(const OfflineVoiceOptions& options){
        if(options.threads<1||options.threads>16||options.timeout<std::chrono::milliseconds(10)||options.timeout>std::chrono::minutes(30))throw std::invalid_argument("Invalid offline transcription resource limits");
        if(options.language.empty()||options.language.size()>16||!std::all_of(options.language.begin(),options.language.end(),[](unsigned char ch){return(ch>='a'&&ch<='z')||ch=='-';}))throw std::invalid_argument("Choose an offline transcription language code");
        DWORD binary{};if(!regular(options.executable)||local_file::lower(options.executable.extension().wstring())!=L".exe"||!GetBinaryTypeW(options.executable.c_str(),&binary)||(binary!=SCS_32BIT_BINARY&&binary!=SCS_64BIT_BINARY))throw std::runtime_error("Choose an available native whisper.cpp CLI executable");
        if(!local_file::local_path(options.models_root)||local_file::has_reparse(options.models_root)||!std::filesystem::is_directory(options.models_root)
                ||!regular(options.model)||!local_file::within(options.models_root,options.model)||local_file::lower(options.model.extension().wstring())!=L".bin")throw std::runtime_error("Choose a local Whisper model inside the app's model folder");
        const auto bytes=std::filesystem::file_size(options.model);if(bytes<16||bytes>4ULL*1024*1024*1024)throw std::runtime_error("The offline model has an unsupported file size");
        if(!local_file::local_path(options.working_root)||local_file::has_reparse(options.working_root))throw std::runtime_error("Offline voice requires an available local app working folder");
    }
    static std::string transcribe(const OfflineVoiceOptions& options,std::span<const std::int16_t> samples,const std::atomic_bool* cancelled=nullptr){
        validate(options);if(samples.size()>VoiceAudio::maximum_samples)throw std::invalid_argument("Voice audio exceeds its ten minute limit");
        if(cancelled&&cancelled->load())throw std::runtime_error("Offline transcription was cancelled");
        // A slip of the key is not speech. Do not launch a model for a quarter second or less.
        if(samples.size()<=VoiceAudio::sample_rate/4)return{};
        Temporary temporary(options.working_root);const auto input=temporary.path/L"input.wav",output=temporary.path/L"transcript";
        write_new(input,VoiceAudio::wav(samples));
        const std::vector<std::wstring> arguments{L"--model",options.model.wstring(),L"--file",input.wstring(),L"--language",winrt::to_hstring(options.language).c_str(),
            L"--threads",std::to_wstring(options.threads),L"--no-gpu",L"--no-prints",L"--no-timestamps",L"--output-txt",L"--output-file",output.wstring()};
        // CLI flags verified against ggml-org/whisper.cpp 4da27c41cebadb3cbbcd2563e9c7cbc8d84bdcad.
        auto process=WindowsProcess::start_bytes(options.executable,arguments,temporary.path,[](std::string_view){},1024*1024);
        process->close_input();const auto deadline=std::chrono::steady_clock::now()+options.timeout;std::optional<WindowsProcess::Exit> exit;
        while(!(exit=process->wait(std::chrono::milliseconds(25)))){
            if(cancelled&&cancelled->load()){process->stop();throw std::runtime_error("Offline transcription was cancelled");}
            if(std::chrono::steady_clock::now()>=deadline){process->stop();throw std::runtime_error("Offline transcription exceeded its time limit");}
        }
        if(cancelled&&cancelled->load())throw std::runtime_error("Offline transcription was cancelled");
        if(exit->status||exit->stdout_truncated||!exit->channel_error.empty())throw std::runtime_error("The offline speech engine failed; no transcript was inserted");
        auto text=local_file::read(std::filesystem::path(output.wstring()+L".txt"),maximum_transcript_bytes).bytes;
        if(text.starts_with("\xef\xbb\xbf"))text.erase(0,3);
        if(!local_file::utf8(text)||text.find('\0')!=std::string::npos)throw std::runtime_error("The offline engine returned unsupported transcript text");
        const auto whitespace=[](unsigned char ch){return ch==' '||ch=='\t'||ch=='\r'||ch=='\n';};
        const auto first=std::find_if_not(text.begin(),text.end(),whitespace),last=std::find_if_not(text.rbegin(),text.rend(),whitespace).base();
        return first<last?std::string(first,last):std::string{};
    }
private:
    static bool regular(const std::filesystem::path& path){return local_file::local_path(path)&&!local_file::has_reparse(path)&&std::filesystem::is_regular_file(path);}
    static void write_new(const std::filesystem::path& path,std::string_view bytes){
        local_file::Handle file(CreateFileW(path.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_TEMPORARY,nullptr));
        if(file.value==INVALID_HANDLE_VALUE)throw std::runtime_error("Could not create the private voice recording");DWORD written{};
        if(bytes.size()>MAXDWORD||!WriteFile(file.value,bytes.data(),static_cast<DWORD>(bytes.size()),&written,nullptr)||written!=bytes.size())throw std::runtime_error("Could not write the complete private voice recording");
    }
    struct Temporary {
        std::filesystem::path path;local_file::Handle root_pin{INVALID_HANDLE_VALUE},pin{INVALID_HANDLE_VALUE};
        explicit Temporary(const std::filesystem::path& root){
            std::filesystem::create_directories(root);if(local_file::has_reparse(root))throw std::runtime_error("The app voice working folder changed before recording");
            root_pin.value=CreateFileW(root.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,nullptr);
            if(root_pin.value==INVALID_HANDLE_VALUE)throw std::runtime_error("Could not pin the app voice working folder");
            std::array<wchar_t,32768> resolved{};const auto length=GetFinalPathNameByHandleW(root_pin.value,resolved.data(),static_cast<DWORD>(resolved.size()),FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
            if(!length||length>=resolved.size())throw std::runtime_error("Could not resolve the app voice working folder");std::wstring physical(resolved.data(),length);if(physical.starts_with(L"\\\\?\\"))physical.erase(0,4);
            if(!local_file::local_path(physical)||!local_file::equal_path(std::filesystem::canonical(root).wstring(),physical))throw std::runtime_error("The app voice working folder changed before recording");
            winrt::guid id;winrt::check_hresult(CoCreateGuid(reinterpret_cast<GUID*>(&id)));path=std::filesystem::path(physical)/(L"voice-"+std::wstring(winrt::to_hstring(id)));
            PSECURITY_DESCRIPTOR descriptor{};if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:P(A;;FA;;;OW)",SDDL_REVISION_1,&descriptor,nullptr))throw std::runtime_error("Could not protect the private voice working folder");
            struct Security{PSECURITY_DESCRIPTOR value;~Security(){LocalFree(value);}} release{descriptor};SECURITY_ATTRIBUTES attributes{sizeof(attributes),descriptor,FALSE};
            if(!CreateDirectoryW(path.c_str(),&attributes))throw std::runtime_error("Could not create the private voice working folder");
            pin.value=CreateFileW(path.c_str(),FILE_READ_ATTRIBUTES|DELETE,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,nullptr);
            if(pin.value==INVALID_HANDLE_VALUE){RemoveDirectoryW(path.c_str());throw std::runtime_error("Could not pin the private voice working folder");}
        }
        ~Temporary(){if(pin.value!=INVALID_HANDLE_VALUE){for(const auto name:{L"input.wav",L"transcript.txt"})DeleteFileW((path/name).c_str());FILE_DISPOSITION_INFO remove{TRUE};SetFileInformationByHandle(pin.value,FileDispositionInfo,&remove,sizeof(remove));}}
    };
};
} // namespace coincide
