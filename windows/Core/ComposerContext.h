#pragma once
#include "Workspace.h"

namespace coincide::composer_context {
inline constexpr std::size_t maximum_selection_bytes=32768,maximum_draft_bytes=4*1024*1024;
// Preserve the existing draft and quote explicit terminal selection as inert message
// context. A longer fence prevents selected backticks from ending the code block.
inline std::string terminal_selection(std::string draft,std::string_view selection,std::string_view heading="Terminal selection"){
    if(selection.empty()||selection.size()>maximum_selection_bytes||selection.find('\0')!=std::string_view::npos)
        throw std::invalid_argument("Select up to 32 KiB of terminal text first.");
    if(draft.size()>maximum_draft_bytes||heading.empty()||heading.size()>256||heading.find_first_of("\r\n\0",0,3)!=std::string_view::npos)
        throw std::invalid_argument("The message context is too large or invalid.");
    for(std::size_t at=0;at<selection.size();)static_cast<void>(workspace_text::next(selection,at));
    std::size_t longest{},run{};for(const auto ch:selection){run=ch=='`'?run+1:0;longest=std::max(longest,run);}
    const std::string fence(std::max<std::size_t>(3,longest+1),'`');
    std::string addition=(draft.empty()?"":"\n\n")+std::string(heading)+":\n\n"+fence+"text\n"+std::string(selection);
    if(selection.back()!='\n')addition+='\n';addition+=fence;
    if(addition.size()>maximum_draft_bytes-draft.size())throw std::invalid_argument("The draft has no room for this terminal selection.");
    draft+=addition;return draft;
}
} // namespace coincide::composer_context
