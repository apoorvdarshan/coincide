// Test-only stand-in for whisper-cli. It never uses an audio device or an actual model.
#include <windows.h>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>
#include <map>

int wmain(int argc,wchar_t** argv){
    std::map<std::wstring,std::wstring> values;std::vector<std::wstring> flags;
    for(int i=1;i<argc;++i){const std::wstring key=argv[i];if(key==L"--no-gpu"||key==L"--no-prints"||key==L"--no-timestamps"||key==L"--output-txt")flags.push_back(key);else{if(++i>=argc)return 71;values[key]=argv[i];}}
    if(values.size()!=5||flags.size()!=4||!values.contains(L"--model")||!values.contains(L"--file")||!values.contains(L"--language")||!values.contains(L"--threads")||!values.contains(L"--output-file"))return 72;
    const auto input=std::filesystem::path(values[L"--file"]),model=std::filesystem::path(values[L"--model"]),output=std::filesystem::path(values[L"--output-file"]+L".txt");
    if(!input.is_absolute()||!output.is_absolute()||input.parent_path()!=output.parent_path()||input.parent_path()!=std::filesystem::current_path())return 73;
    std::ifstream recording(input,std::ios::binary);const std::string wav((std::istreambuf_iterator<char>(recording)),std::istreambuf_iterator<char>());
    const auto word=[&](std::size_t at,unsigned bytes){unsigned result{};for(unsigned i=0;i<bytes;++i)result|=static_cast<unsigned>(static_cast<unsigned char>(wav[at+i]))<<(i*8);return result;};
    if(wav.size()<44||wav.substr(0,4)!="RIFF"||word(4,4)!=wav.size()-8||wav.substr(8,8)!="WAVEfmt "||word(16,4)!=16||word(20,2)!=1||word(22,2)!=1||word(24,4)!=16000||word(34,2)!=16||wav.substr(36,4)!="data"||word(40,4)!=wav.size()-44)return 74;
    const auto name=model.stem().wstring();if(name==L"failure")return 7;if(name==L"slow")Sleep(2000);
    if(name==L"flood"){DWORD written{};const std::string bytes(65536,'x');for(unsigned i=0;i<40;++i)if(!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),bytes.data(),static_cast<DWORD>(bytes.size()),&written,nullptr))break;return 0;}
    if(name==L"missing")return 0;
    std::ofstream transcript(output,std::ios::binary);if(!transcript)return 75;
    if(name==L"invalid")transcript<<std::string("\xff\0",2);
    else if(name==L"oversized")transcript<<std::string(256*1024+1,'x');
    else {std::string language;for(const auto ch:values[L"--language"]){if(ch>127)return 77;language+=static_cast<char>(ch);}transcript<<"\xef\xbb\xbf"<<"  Owned offline fixture — 你好\nLanguage: "<<language<<"\r\n";}
    return transcript?0:76;
}
