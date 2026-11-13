# Provider branding

The Codex, Cursor, Grok and OpenCode PDFs are the Swift app's original
monochrome template assets at commit `8596e9a`. Their SVG counterparts are
vector conversions of those PDFs for GPUI rendering. Claude's colored mark is
rasterized from the Swift app's `AgentClaude.pdf`, and Antigravity's colored
mark comes from its `AgentAntigravity@3x.png` asset in the same commit. Native
builds embed these local assets and perform no network requests. Monochrome
marks follow the surrounding text color; the colored marks retain their
original artwork.

They identify Codex, Claude, Cursor, Grok, OpenCode and Antigravity. The marks
remain the property of their respective owners. This change does not create
or change a license for those marks. The Swift app also carries its provider
branding in the retired Swift desktop source in Git history.
