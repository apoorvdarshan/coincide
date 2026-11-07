# Native browser screenshot scope

The closed `browser.request` action `screenshot` accepts `threadId`, optional
`tab`, and optional boolean `fullPage`. It accepts no path, script, SDK method,
clip, frame target, source receipt or budget override. A screenshot returns a
private local PNG path, MIME type, tab, pixel dimensions and truncation metadata.
It does not attach an image, send a message or invoke an OS desktop-capture API.

The active tab must finish navigation and pending page operations first. The
native browser owner binds its actual tab/thread, native URL, navigation epoch,
view geometry and scale through preparation, SDK return and artifact admission.
A saved-login suppression flag denies screenshot capture; pending capture also
denies native credential delivery. Changed, closed or cancelled sources never
publish an artifact. A 20-second budget revokes delivery; it does not acknowledge
a native callback or an unjoined worker. Quit retains real callback/event/block
and worker ownership until actual return. An unresponsive SDK remains unknown.

## Privacy and bounds

A fixed isolated-world mask transaction never reads field values, HTML or text.
It conservatively hides editable controls, canvases, custom/open-shadow hosts
and whole embedded documents, including cross-origin frames. The observer starts
before masking and distinguishes exact own style changes from reentrant page
changes. Any other DOM mutation invalidates output. Cleanup respects newer page
styles, and remains observed itself. Native pixels stay private until the mask
and native source validate; a separate worker redacts rectangles again before
resampling and encoding. This is not detection of every possible secret drawn
as ordinary page content or hidden inside an arbitrary inaccessible shadow root.

Requests/decoders allow at most 8 million native pixels and 20000 CSS/native edge
pixels; output is at most 1600 pixels wide. PNG input/output is capped at 16 MiB,
with a bounded encoder writer. Runtime storage admits at most 64 artifacts and
128 MiB, refusing unknown entries rather than deleting them. UUID files are
private, never overwritten, and pinned to actual directory/file identities.
Stale cleanup removes only the exact generated artifact. Cleanup failure is
reported as retained; no recursive cleanup or force deletion is used.

## Platform adapters

- macOS uses `WKWebView.takeSnapshot`, a native rectangle and snapshot width,
  `afterScreenUpdates`, and a named `WKContentWorld` for masking. It never
  resizes the real view or changes its scroll position.
- Linux uses WebKitGTK's visible-region native snapshot and a named world.
  FullDocument has no preallocation clip; it is not used. Native Cairo pixels
  are converted and redacted on the owned encoder worker.
- Windows uses fixed WebView2 SDK calls, a system-unique isolated context proved
  by both creation and native context event, and a fixed
  `Page.captureScreenshot` viewport clip. Native controller raster/zoom/bounds
  and frame/loader identity are rechecked. There is no public CDP/JS endpoint,
  numeric-context fallback or credential-permit reuse. Cancellation removes the
  actual context listener and waits for call/event closure return. Requested
  geometry, received PNG and our allocations are bounded; this does not impose
  a process-wide hard quota on undocumented native SDK compositor allocations.

`fullPage` currently succeeds only if the entire document already fits its
native viewport. Taller/wider documents are explicitly refused, never silently
returned as complete or captured by scrolling/resizing the user's page. Native
SDK full-page parity beyond this bound remains incomplete.

## Evidence

The 3c8d0388 scoped checkpoint passed Core redaction/artifact 6, protocol 1 and
Desktop fake lifecycle 3 tests, strict Core checks, formatting and macOS native
compilation. That is not native screenshot acceptance. Later observer/lifecycle
and Windows code require their focused gates. The fresh hosted CI fixture uses
only private loopback pages and fake secrets to check actual PNG pixels,
protected fields, cross-origin frames, closed custom hosts, oversized refusal,
reentrant page mutation/style preservation, navigation and CloseTab during a
real owned renderer barrier. Windows and Linux smoke retain every prior check.
No native screenshot, personal browser, password manager, credential, provider
or OS desktop capture was used while developing this source.

Primary API/source references:

- [WebKitGTK snapshot](https://webkitgtk.org/reference/webkit2gtk/2.40.0/method.WebView.get_snapshot.html)
- [WebKitGTK2.40 snapshot paint flushes style/layout](https://github.com/WebKit/WebKit/blob/webkitgtk-2.40.0/Source/WebCore/page/FrameView.cpp#L4418)
- [WKSnapshotConfiguration](https://developer.apple.com/documentation/webkit/wksnapshotconfiguration)
- [WebView2 SDK](https://learn.microsoft.com/en-us/microsoft-edge/webview2/reference/win32/icorewebview2)
- [Official DevTools fixed page snapshot/viewport schema](https://github.com/ChromeDevTools/devtools-protocol/blob/master/json/browser_protocol.json)
