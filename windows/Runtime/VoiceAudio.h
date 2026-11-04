#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>

namespace coincide {
struct VoiceAudio {
    static constexpr std::size_t sample_rate=16000,maximum_samples=sample_rate*600;
    // Exact PCM16 mono WAV accepted by the offline adapter. No codec, resampler or device access.
    static std::string wav(std::span<const std::int16_t> samples){
        if(samples.size()>maximum_samples)throw std::invalid_argument("Voice audio exceeds its ten minute limit");
        std::string result;result.reserve(44+samples.size()*2);
        const auto word=[&](std::uint32_t value,unsigned bytes){for(unsigned i=0;i<bytes;++i)result+=static_cast<char>((value>>(8*i))&255);};
        result+="RIFF";word(static_cast<std::uint32_t>(36+samples.size()*2),4);result+="WAVEfmt ";word(16,4);word(1,2);word(1,2);word(sample_rate,4);word(sample_rate*2,4);word(2,2);word(16,2);result+="data";word(static_cast<std::uint32_t>(samples.size()*2),4);
        for(const auto sample:samples)word(static_cast<std::uint16_t>(sample),2);return result;
    }
    static float level(std::span<const std::int16_t> samples){
        if(samples.empty())return 0;double energy{};for(const auto sample:samples){const auto value=static_cast<double>(sample)/32768;energy+=value*value;}return static_cast<float>(std::min(1.0,std::sqrt(energy/samples.size())));
    }
};
} // namespace coincide
