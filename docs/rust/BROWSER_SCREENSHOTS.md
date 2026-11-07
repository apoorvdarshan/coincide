# Browser screenshot redaction scope

Screenshots mask password, credential/autocomplete and payment inputs in the
document and its accessible open shadow roots. They mask iframe/frame and
object/embed surfaces as whole rectangles, including same-origin frames: opaque
frame contents are never assumed safe because the parent cannot inspect them.
The native image is redacted again at these measured rectangles before writing.
The transaction refuses moved, removed, restyled or newly detected sensitive
fields or opaque surfaces. FINISH invokes the exact classifier retained by
PREPARE in its private transaction, including username/email association with
password forms; it does not use a narrower independent regex. Existing saved-login capture suppression remains in
force independently of the screenshot transaction.

The API reports `redactionScope` and `uninspectedContent`. Closed shadow roots
and secrets rendered as ordinary page text, canvas, images or other content are
not inspected; screenshots are not a universal secret-removal boundary. Closed
roots on ordinary div/span/body hosts cannot be distinguished portably from no
root using public WKWebView/WebKitGTK DOM APIs. Do not claim otherwise.

Swift's `PreviewPasswords.maskScript` iterates document inputs registered in
`__coincideSecretFields` and applies text-security to non-password fields during
`PreviewSession` snapshot capture. It does not enumerate frame documents or
closed shadow roots. The Rust transaction masks additional discoverable input
classes and open roots; the opaque-surface masking is a conservative extension.

The runner-only native screenshot fixture now includes a sandboxed opaque-origin
iframe and checks exact dark pixels over its surface on all three hosts, while
an ordinary search field stays visible. Its existing viewport/full-page,
scroll/style restoration, geometry and callback-owner assertions remain active.
The new exact-head native runs must pass before claiming this extension verified.

The inert Node regression executes the actual PREPARE/FINISH script bodies. It
covers newly added username fields, ordinary fields reclassified by autocomplete
or login identity, newly added opaque frames, benign ordinary inputs, and style
restoration. It runs in every Core matrix job. Existing Rust/native fixture test
counts and all prior assertions remain unchanged.
