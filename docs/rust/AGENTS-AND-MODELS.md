# Coding agents and model services

Coincide's model picker has an **Agents** tab. It reads the public ACP Registry
when opened and shows which commands are installed. Choose an installed agent
to add it; use that agent's normal sign-in and configuration first. Coincide
does not download or install a registry entry on its own. You can also add a
local ACP command with its executable name or absolute path and literal
arguments. For DeepSeek Harness, use `dsh` with `--profile acp`.
On Windows, automatic discovery finds native `.exe` and `.com` commands;
package-manager `.cmd` launchers are not automatically discovered.

Agents and their model services are separate: an ACP agent supplies its own
models, tools, permissions and credentials. Coincide uses ACP v1 and displays
the agent's advertised commands and models when available. Unsupported
active-turn steering is queued. Capability and session-resume support differ
by agent; ACP v2-only agents and agent-specific extensions are not supported by
the generic adapter. Client-managed ACP filesystem and terminal operations,
interactive ACP sign-in and ACP elicitation forms are not yet connected; agents
that require them need their own integration. Selecting an already added agent after an executable update
reapproves its installed command. An agent's own sign-in and downloads remain
under its control.

OpenCode shows models configured for the selected project and account, including
the OpenCode-supported OpenRouter and DeepSeek providers. Its own Ollama,
LM Studio and vLLM discovery is also used; see OpenCode's provider documentation
for endpoints and authentication. These are models for OpenCode, not separate
agents. A configured provider must be accessible to the selected OpenCode account.

**Lithos AI** has its own provider entry in Coincide. For hosted models, add a
Lithos API-key account in its provider settings, save the key, and select that
account in a conversation using Lithos. Coincide reads the models available to
that account and shows them in the Lithos picker. Keys remain in the native
secret store and are sent to Lithos in an authorization header, never in a URL.
The installed OpenCode executable provides the coding-agent runtime; an
OpenCode account is not required. Existing OpenCode Lithos key accounts remain
available in OpenCode. Tool support depends on the model offered by Lithos.

If an unauthenticated Lithos Metal server is running on `127.0.0.1:8000`,
Coincide discovers the `lithos-metal` models it reports and exposes them in the
Lithos picker without a key. A server on a different address or requiring
authentication can be configured as an OpenCode-compatible provider. Local
model/tool support depends on the running server and model; no model is
downloaded automatically.
