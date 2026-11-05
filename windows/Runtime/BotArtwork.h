#pragma once
#include "BotArtworkData.h"
#include <algorithm>
#include <charconv>
#include <cmath>
#include <set>
#include <stdexcept>
#include <string>

namespace coincide {
// Self-contained data only: the caller cannot supply tags, paths, references or script.
// Geometry is an attributed port of the existing MIT-licensed shared native artwork.
class BotArtwork {
public:
    static constexpr std::size_t maximum_svg_bytes=128*1024;
    static constexpr std::string_view tint_ids[]={"sunflower","tangerine","coral","cherry","rose","lilac","sky","mint","leaf","sage","caramel"};
    static std::string svg(std::string_view character,std::string_view tint,double side=100){
        if(!std::isfinite(side)||side<8||side>512)throw std::invalid_argument("Invalid bounded bot artwork size");
        const auto found=std::find(std::begin(tint_ids),std::end(tint_ids),tint);if(found==std::end(tint_ids))throw std::invalid_argument("Unknown bot artwork tint");const auto color=static_cast<std::size_t>(found-std::begin(tint_ids));
        const unsigned detail=side<20?16:side<34?28:100;const bot_art_data::Set* variant{};for(const auto& item:bot_art_data::sets)if(item.character==character&&item.detail==detail){variant=&item;break;}if(!variant)throw std::invalid_argument("Unknown bot artwork character");
        std::string result="<svg xmlns=\"http://www.w3.org/2000/svg\" width=\""+number(side)+"\" height=\""+number(side)+"\" viewBox=\"0 0 100 100\">";std::set<int> clips;
        for(std::size_t i=0;i<variant->count;++i)if(variant->draws[i].clip>=0)clips.insert(variant->draws[i].clip);
        if(!clips.empty()){result+="<defs>";for(const auto clip:clips)result+="<clipPath id=\"c"+std::to_string(clip)+"\"><path d=\""+std::string(bot_art_data::paths[clip])+"\"/></clipPath>";result+="</defs>";}
        for(std::size_t i=0;i<variant->count;++i){const auto& op=variant->draws[i];const auto rgba=op.colors[color];result+="<path d=\""+std::string(bot_art_data::paths[op.path])+"\"";if(op.clip>=0)result+=" clip-path=\"url(#c"+std::to_string(op.clip)+")\"";
            const auto rgb=hex(rgba>>8);const auto alpha=number(static_cast<double>(rgba&255)/255);if(op.fill)result+=" fill=\"#"+rgb+"\" fill-opacity=\""+alpha+"\"";else result+=" fill=\"none\" stroke=\"#"+rgb+"\" stroke-opacity=\""+alpha+"\" stroke-width=\""+number(std::max(op.width,op.minimum*100/side))+"\" stroke-linecap=\"round\" stroke-linejoin=\"round\"";result+="/>";
        }result+="</svg>";if(result.size()>maximum_svg_bytes)throw std::runtime_error("Bot artwork exceeds its output bound");return result;
    }
    static bool valid_catalog(){
        if constexpr(std::size(bot_art_data::sets)!=21||std::size(tint_ids)!=11)return false;
        for(const auto path:bot_art_data::paths){if(path.empty()||path.size()>8192||path.find_first_not_of("MLCQZ0123456789 .-")!=std::string_view::npos)return false;std::size_t i{};while(i<path.size()){const auto c=path[i];if(c=='M'||c=='L'||c=='C'||c=='Q'||c=='Z'||c==' '){++i;continue;}double value{};const auto parsed=std::from_chars(path.data()+i,path.data()+path.size(),value);if(parsed.ec!=std::errc{}||parsed.ptr==path.data()+i||!std::isfinite(value)||std::abs(value)>1000)return false;i=static_cast<std::size_t>(parsed.ptr-path.data());}}
        for(const auto& variant:bot_art_data::sets){if(variant.count>256||!variant.count)return false;for(std::size_t i=0;i<variant.count;++i){const auto& op=variant.draws[i];if(op.path>=std::size(bot_art_data::paths)||op.clip< -1||(op.clip>=0&&static_cast<std::size_t>(op.clip)>=std::size(bot_art_data::paths))||!std::isfinite(op.width)||!std::isfinite(op.minimum)||op.width<0||op.width>100||op.minimum<0||op.minimum>10)return false;}}return true;
    }
private:
    static std::string number(double value){char data[64]{};const auto converted=std::to_chars(data,data+sizeof(data),value,std::chars_format::fixed,5);if(converted.ec!=std::errc{})throw std::runtime_error("Invalid bot artwork geometry");std::string result(data,converted.ptr);while(result.ends_with('0'))result.pop_back();if(result.ends_with('.'))result.pop_back();return result.empty()?"0":result;}
    static std::string hex(std::uint32_t value){constexpr char digits[]="0123456789abcdef";std::string out(6,'0');for(int i=5;i>=0;--i){out[static_cast<std::size_t>(i)]=digits[value&15];value>>=4;}return out;}
};
} // namespace coincide
