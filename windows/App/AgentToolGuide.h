#pragma once
#include "BrowserToolPolicy.h"

namespace coincide {
inline std::string app_tool_descriptions(){
    return "Use only the current per-thread connection blocks in this message. The following argument descriptions do not grant access. Never read, copy, print or upload a private curl configuration. A timed-out action may already have happened; observe its result before another action.\n"
        "Browser request schema: "+browser_tool::Request::schema()+"\n"
        "Browser page/frame identifiers are opaque and expire on navigation. Read again before interacting with a replaced document. Password values, cookies and site storage are unavailable. fill-login requires the owner's native Allow once decision and returns only status/username. ask-user is for a required owner action, never simulated approval.\n"
        "Schedule requests use action list; create with name, prompt and schedule; update with id and changed fields; pause/resume/delete/run-now with id. A schedule is {kind:once,at:ISO-date-time} or {kind:once,inMinutes:number}, {kind:daily|weekdays,time:HH:mm}, {kind:weekly,day:monday,time:HH:mm}, {kind:days,days:[mon,thu],time:HH:mm}, {kind:interval,minutes:number} or hours:number, or {kind:cron,expression:five-fields}. Quote all JSON keys and strings. Optional timeZone is an IANA zone. Repeats must be at least five minutes. Create/edits await native approval. Use scheduling only when the user asks for later or recurring work.\n"
        "Terminal requests use action status/read/show/hide/interrupt. Read accepts limit (1-2000 lines, default 200) and page (default 1). Output belongs to this conversation's existing panes. Show never starts a shell. Interrupt sends Ctrl+C to those panes. This connection cannot type or execute commands.\n"
        "Computer Use requests begin with status/tools, then only advertised tools and fresh observation tokens. Do not pass scripts, browser commands, permission overrides or another session. Explicitly revoked connections provide no continuing permission.\n";
}
} // namespace coincide
