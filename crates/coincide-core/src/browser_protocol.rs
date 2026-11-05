//! Bounded browser commands shared by the CLI/API and the desktop webview.
//! Deliberately no arbitrary-script, cookie, storage, or password-read command.
use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use url::Url;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserRequest {
    pub id: String,
    pub thread_id: String,
    #[serde(default)]
    pub tab: Option<String>,
    #[serde(default)]
    pub frame: Option<String>,
    #[serde(flatten)]
    pub action: BrowserAction,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "action", rename_all = "kebab-case")]
pub enum BrowserAction {
    Read {
        #[serde(default)]
        selector: Option<String>,
        #[serde(default = "first_page")]
        page: usize,
    },
    Navigate {
        url: String,
    },
    Click {
        selector: String,
    },
    Input {
        selector: String,
        text: String,
    },
    Type {
        selector: String,
        text: String,
        #[serde(default)]
        clear: bool,
    },
    Scroll {
        #[serde(default)]
        selector: Option<String>,
        #[serde(default)]
        to: Option<ScrollEdge>,
        #[serde(default)]
        by: Option<i32>,
    },
    Frames,
    Back,
    Forward,
    Reload,
    Tabs,
    Downloads,
    NewTab {
        #[serde(default)]
        url: Option<String>,
    },
    SelectTab,
    CloseTab,
    Show,
    Hide,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ScrollEdge {
    Top,
    Bottom,
}
fn first_page() -> usize {
    1
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserReply {
    pub id: String,
    pub thread_id: String,
    pub result: Value,
}

impl BrowserRequest {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            !self.id.is_empty() && self.id.len() <= 128,
            "Invalid browser operation ID"
        );
        uuid::Uuid::parse_str(&self.thread_id)?;
        if let Some(tab) = &self.tab {
            ensure!(!tab.is_empty() && tab.len() <= 128, "Invalid tab ID");
        }
        if let Some(frame) = &self.frame {
            ensure!(!frame.is_empty() && frame.len() <= 128, "Invalid frame ID");
            ensure!(
                matches!(
                    self.action,
                    BrowserAction::Read { .. }
                        | BrowserAction::Click { .. }
                        | BrowserAction::Input { .. }
                        | BrowserAction::Type { .. }
                        | BrowserAction::Scroll { .. }
                ),
                "This action cannot target a frame"
            );
        }
        match &self.action {
            BrowserAction::Navigate { url } | BrowserAction::NewTab { url: Some(url) } => {
                validate_url(url)?;
            }
            BrowserAction::Read { selector, page } => {
                ensure!((1..=1000).contains(page), "Page must be between 1 and 1000");
                if let Some(selector) = selector {
                    validate_selector(selector)?;
                }
            }
            BrowserAction::Click { selector } => validate_selector(selector)?,
            BrowserAction::Input { selector, text }
            | BrowserAction::Type { selector, text, .. } => {
                validate_selector(selector)?;
                ensure!(text.len() <= 65536, "Input exceeds 64 KiB");
            }
            BrowserAction::Scroll { selector, to, by } => {
                ensure!(
                    usize::from(selector.is_some())
                        + usize::from(to.is_some())
                        + usize::from(by.is_some())
                        <= 1,
                    "Use only one of selector, to, or by for scrolling"
                );
                if let Some(selector) = selector {
                    validate_selector(selector)?;
                }
                if let Some(by) = by {
                    ensure!(
                        (-1_000_000..=1_000_000).contains(by),
                        "Scroll distance exceeds one million pixels"
                    );
                }
            }
            BrowserAction::SelectTab | BrowserAction::CloseTab => {
                ensure!(self.tab.is_some(), "A tab ID is required");
            }
            _ => {}
        }
        Ok(())
    }
}

pub fn validate_url(address: &str) -> Result<Url> {
    ensure!(address.len() <= 16384, "URL exceeds 16 KiB");
    let url = Url::parse(address)?;
    ensure!(
        matches!(url.scheme(), "http" | "https")
            && url.host_str().is_some()
            && url.username().is_empty()
            && url.password().is_none(),
        "Use an HTTP or HTTPS address without a username or password"
    );
    Ok(url)
}

/// Browser-created empty/srcdoc frames are internal documents, not arbitrary
/// user navigation targets. Keep the public navigate/new-tab API HTTP(S)-only.
pub fn allow_native_navigation(address: &str) -> bool {
    matches!(address, "about:blank" | "about:srcdoc") || validate_url(address).is_ok()
}
fn validate_selector(selector: &str) -> Result<()> {
    ensure!(
        !selector.trim().is_empty() && selector.len() <= 4096,
        "Selector must contain 1–4096 bytes"
    );
    Ok(())
}

/// Native download callbacks do not provide an ID on macOS. Permit only one
/// accepted transfer per (thread, tab, URL), and account for callbacks from
/// rejected starts before accepting that URL again. Never expose request URLs.
pub struct DownloadRegistry {
    directory: std::path::PathBuf,
    records: Vec<DownloadRecord>,
    rejected: std::collections::HashMap<(String, String, String), u32>,
    last_errors: std::collections::VecDeque<(String, String)>,
    correlation_exhausted: bool,
}
struct DownloadRecord {
    id: String,
    thread: String,
    tab: String,
    url: String,
    destination: std::path::PathBuf,
    state: &'static str,
    error: Option<String>,
}
impl DownloadRegistry {
    pub fn new(directory: std::path::PathBuf) -> Result<Self> {
        ensure!(
            directory.is_absolute(),
            "Download directory must be absolute"
        );
        std::fs::create_dir_all(&directory)?;
        require_download_directory(&directory)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700))?;
        }
        Ok(Self {
            directory: directory.canonicalize()?,
            records: Vec::new(),
            rejected: Default::default(),
            last_errors: Default::default(),
            correlation_exhausted: false,
        })
    }

    pub fn start(
        &mut self,
        thread: &str,
        tab: &str,
        url: &str,
        suggested: &std::path::Path,
    ) -> Result<std::path::PathBuf> {
        let result = self.start_inner(thread, tab, url, suggested);
        if let Err(error) = &result {
            self.refuse(thread, &error.to_string());
        }
        result
    }

    /// Record only bounded, application-generated explanations, never a request
    /// URL or a native backend error that could contain page/private content.
    pub fn refuse(&mut self, thread: &str, reason: &str) {
        self.last_errors.retain(|(owner, _)| owner != thread);
        if self.last_errors.len() >= 128 {
            self.last_errors.pop_front();
        }
        self.last_errors
            .push_back((thread.to_owned(), reason.chars().take(512).collect()));
    }

    fn start_inner(
        &mut self,
        thread: &str,
        tab: &str,
        url: &str,
        suggested: &std::path::Path,
    ) -> Result<std::path::PathBuf> {
        validate_url(url)?;
        uuid::Uuid::parse_str(thread)?;
        uuid::Uuid::parse_str(tab)?;
        let key = (thread.to_owned(), tab.to_owned(), url.to_owned());
        let result = (|| -> Result<std::path::PathBuf> {
            ensure!(
                !self.correlation_exhausted,
                "Download callback tracking is full; restart the browser before downloading more files"
            );
            ensure!(
                !self.rejected.contains_key(&key),
                "Waiting for a refused download's cancellation callback; use a new tab to retry"
            );
            ensure!(
                !self.records.iter().any(|r| r.thread == thread
                    && r.tab == tab
                    && r.url == url
                    && matches!(r.state, "downloading" | "unconfirmed")),
                "This URL already has an active download in this tab"
            );
            ensure!(
                self.records
                    .iter()
                    .filter(|r| matches!(r.state, "downloading" | "unconfirmed"))
                    .count()
                    < 8,
                "At most 8 native downloads may be active"
            );
            if self.records.len() >= 50 {
                let removable = self
                    .records
                    .iter()
                    .position(|r| !matches!(r.state, "downloading" | "unconfirmed"));
                ensure!(removable.is_some(), "Download history is full");
                self.records.remove(removable.expect("checked record"));
            }
            require_download_directory(&self.directory)?;
            let id = uuid::Uuid::new_v4().to_string();
            let folder = self.directory.join(&id);
            let mut builder = std::fs::DirBuilder::new();
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                builder.mode(0o700);
            }
            builder.create(&folder)?;
            let destination = folder.join(download_filename(&suggested.to_string_lossy()));
            self.records.push(DownloadRecord {
                id,
                thread: thread.into(),
                tab: tab.into(),
                url: url.into(),
                destination: destination.clone(),
                state: "downloading",
                error: None,
            });
            Ok(destination)
        })();
        if result.is_err() {
            // A denied start may still trigger a failure callback. Without this
            // ledger it could incorrectly fail a later accepted same-URL retry.
            if self.rejected.len() >= 128 && !self.rejected.contains_key(&key) {
                self.correlation_exhausted = true;
            } else {
                let count = self.rejected.entry(key).or_default();
                if *count >= 1024 {
                    self.correlation_exhausted = true;
                } else {
                    *count += 1;
                }
            }
        }
        result
    }

    pub fn complete(
        &mut self,
        thread: &str,
        tab: &str,
        url: &str,
        path: Option<&std::path::Path>,
        success: bool,
    ) {
        let key = (thread.to_owned(), tab.to_owned(), url.to_owned());
        let index = self.records.iter().position(|record| {
            record.thread == thread
                && record.tab == tab
                && record.url == url
                && matches!(record.state, "downloading" | "unconfirmed")
                && path.is_none_or(|path| {
                    path == record.destination
                        // WebView2 removes the Windows verbatim prefix when
                        // saving; our root was canonicalized with that prefix.
                        || (cfg!(windows)
                            && path.canonicalize().ok().as_ref() == Some(&record.destination))
                })
        });
        // A backend-provided destination exactly identifies an accepted record.
        // macOS sends no path: consume expected rejection failures first.
        if !success
            && (path.is_none() || index.is_none())
            && let Some(count) = self.rejected.get_mut(&key)
        {
            *count = count.saturating_sub(1);
            if *count == 0 {
                self.rejected.remove(&key);
            }
            return;
        }
        let Some(index) = index else {
            return;
        };
        let record = &mut self.records[index];
        if !success {
            record.state = "failed";
            record.error =
                Some("Native browser reported that the download failed or was cancelled.".into());
            return;
        }
        match finish_download(&self.directory, &record.destination) {
            Ok(()) => {
                record.state = "finished";
                record.error = None;
            }
            Err(error) => {
                record.state = "failed";
                record.error = Some(format!("Downloaded file could not be verified: {error}"));
            }
        }
    }

    pub fn tab_closed(&mut self, thread: &str, tab: &str) {
        for record in &mut self.records {
            if record.thread == thread && record.tab == tab && record.state == "downloading" {
                record.state = "unconfirmed";
                record.error = Some(
                    "Tab closed before a completion callback; partial files are retained.".into(),
                );
            }
        }
    }

    pub fn list(&self, thread: &str, tab: Option<&str>) -> Value {
        let downloads=self.records.iter().filter(|r|r.thread==thread && tab.is_none_or(|tab|r.tab==tab)).map(|r| {
            let mut value=serde_json::json!({"id":r.id,"tab":r.tab,"state":r.state,"name":r.destination.file_name().map(|name|name.to_string_lossy())});
            if r.state=="finished" {value["path"]=serde_json::json!(r.destination);}
            if let Some(error)=&r.error {value["error"]=serde_json::json!(error.chars().take(2000).collect::<String>());}
            value
        }).collect::<Vec<_>>();
        serde_json::json!({"downloads":downloads,"acceptingDownloads":!self.correlation_exhausted,
            "lastError":self.last_errors.iter().find(|(owner,_)|owner==thread).map(|(_,error)|error),
            "pendingCancellationCallbacks":self.rejected.iter().filter(|((owner,owner_tab,_),_)|owner==thread && tab.is_none_or(|tab|owner_tab==tab)).map(|(_,count)|u64::from(*count)).sum::<u64>(),
            "limitations":["No progress bytes, cancellation or resume API","Files and partial downloads remain on disk; history is session-only","Only HTTP(S) downloads; at most 8 active and 50 retained records","Missing cancellation callbacks can block same-URL retries in a tab"]})
    }
}

/// Server-supplied suggestions are filenames, never trusted paths. Match both
/// separator styles on every host and keep names valid on Windows as well.
pub fn download_filename(suggestion: &str) -> String {
    let leaf = suggestion.rsplit(['/', '\\']).next().unwrap_or("");
    let mut name = String::new();
    for ch in leaf.chars().filter(|ch|!ch.is_control() && !matches!(ch,'<'|'>'|':'|'"'|'|'|'?'|'*'|'\u{202a}'..='\u{202e}'|'\u{2066}'..='\u{2069}')) {
        if name.len()+ch.len_utf8()>180 {break;}
        name.push(ch);
    }
    name = name.trim_end_matches([' ', '.']).to_owned();
    if name.is_empty() {
        return "download".into();
    }
    let stem = name.split('.').next().unwrap_or("").to_ascii_uppercase();
    if matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || (stem.len() == 4
            && (stem.starts_with("COM") || stem.starts_with("LPT"))
            && matches!(stem.as_bytes()[3], b'1'..=b'9'))
    {
        name.insert(0, '_');
    }
    name
}
fn require_download_directory(path: &std::path::Path) -> Result<()> {
    let metadata = std::fs::symlink_metadata(path)?;
    ensure!(
        metadata.is_dir() && !metadata.file_type().is_symlink(),
        "Download directory must be a real directory"
    );
    Ok(())
}
fn finish_download(root: &std::path::Path, destination: &std::path::Path) -> Result<()> {
    require_download_directory(root)?;
    let parent = destination
        .parent()
        .ok_or_else(|| anyhow::anyhow!("Download has no parent"))?;
    ensure!(
        parent.parent() == Some(root),
        "Download escaped its UUID directory"
    );
    require_download_directory(parent)?;
    let metadata = std::fs::symlink_metadata(destination)?;
    ensure!(
        metadata.is_file() && !metadata.file_type().is_symlink(),
        "Download must be a regular file"
    );
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options.open(destination)?;
    ensure!(
        file.metadata()?.is_file(),
        "Download must be a regular file"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}

/// Build one of the fixed browser operations. Caller input is JSON encoded,
/// never concatenated into executable source. Cross-origin frames require a
/// separate native implementation; page scripts cannot bypass origin boundaries.
pub fn script(action: &BrowserAction) -> Result<Option<String>> {
    script_in_frame(action, None)
}

pub fn script_for_request(request: &BrowserRequest) -> Result<Option<String>> {
    request.validate()?;
    script_in_frame(&request.action, request.frame.as_deref())
}

fn script_in_frame(action: &BrowserAction, frame: Option<&str>) -> Result<Option<String>> {
    let payload = match action {
        BrowserAction::Read { selector, page } => {
            serde_json::json!({"kind":"read","selector":selector,"page":page})
        }
        BrowserAction::Click { selector } => {
            serde_json::json!({"kind":"click","selector":selector})
        }
        BrowserAction::Input { selector, text } => {
            serde_json::json!({"kind":"input","selector":selector,"text":text})
        }
        BrowserAction::Type {
            selector,
            text,
            clear,
        } => {
            serde_json::json!({"kind":"type","selector":selector,"text":text,"clear":clear})
        }
        BrowserAction::Scroll { selector, to, by } => {
            serde_json::json!({"kind":"scroll","selector":selector,"to":to,"by":by})
        }
        BrowserAction::Frames => serde_json::json!({"kind":"frames"}),
        BrowserAction::Back => return Ok(Some("history.back(); ({dispatched:true})".into())),
        BrowserAction::Forward => return Ok(Some("history.forward(); ({dispatched:true})".into())),
        BrowserAction::Reload => return Ok(Some("location.reload(); ({dispatched:true})".into())),
        _ => return Ok(None),
    };
    Ok(Some(format!(
        "(() => {{ const request = {}; const frameId = {}; {} }})()",
        serde_json::to_string(&payload)?,
        serde_json::to_string(&frame)?,
        SCRIPT
    )))
}

const SCRIPT: &str = r#"
try {
  const safeUrl = value => {
    try {
      const url=new URL(value);
      url.username=''; url.password='';
      return ['http:','https:','about:'].includes(url.protocol) ? url.href.slice(0,8192) : url.protocol+'[omitted]';
    } catch (_) {return '';}
  };
  // Registry lifetime is the top document. Each enumeration expires previous
  // handles; child navigation is detected by checking document identity through
  // every ancestor. These are page data, never authority for native operations.
  const registryKey = '__coincideSameOriginFramesV1';
  if (request.kind === 'frames') {
    const entries = new Map(), frames = [];
    let truncated = false;
    const visit = (doc, chain, depth) => {
      if (depth >= 8) {truncated=true; return;}
      for (const element of doc.querySelectorAll('iframe,frame')) {
        if (frames.length >= 64) {truncated=true; return;}
        let child = null;
        try {child=element.contentDocument;} catch (_) {}
        const id = 'frame-'+crypto.randomUUID();
        const next = chain.concat([{element,doc:child}]);
        entries.set(id,{chain:next,doc:child});
        frames.push({id,title:(child?.title || element.title || '').slice(0,300),
          url:safeUrl(child?.location.href || element.src || ''),accessible:!!child,
          ...(!child ? {reason:'Cross-origin or sandboxed frame requires native frame support'} : {})});
        if (child) visit(child,next,depth+1);
      }
    };
    visit(document,[],0);
    window[registryKey]=entries;
    return {frames,truncated,handlesExpire:'On the next frames listing or navigation',crossOriginActionsSupported:false};
  }
  let doc = document;
  if (frameId) {
    const entry = window[registryKey]?.get(frameId);
    if (!entry) throw new Error('Frame handle expired or belongs to another tab; list frames again');
    if (!entry.doc) throw new Error('Cross-origin or sandboxed frame actions are not supported');
    let parent = document;
    for (const item of entry.chain) {
      if (!item.element.isConnected || item.element.ownerDocument!==parent || item.element.contentDocument!==item.doc)
        throw new Error('Frame navigated or was detached; list frames again');
      parent=item.doc;
    }
    doc=entry.doc;
  }
  const win=doc.defaultView;
  const visible = e => !!e.getClientRects().length && win.getComputedStyle(e).visibility !== 'hidden';
  const sensitive = e => e.matches('input[type=password],input[autocomplete=one-time-code]');
  const choose = selector => {
    const all = doc.querySelectorAll(selector);
    if (all.length !== 1) throw new Error(all.length ? 'Selector matches multiple elements' : 'Element not found');
    return all[0];
  };
  if (request.kind === 'read') {
    const scope = request.selector ? choose(request.selector) : doc.body;
    if (!scope) return {url:safeUrl(doc.location.href),title:doc.title,loading:doc.readyState !== 'complete',text:'',elements:[]};
    const pageSize=20000;
    // innerText does not expose input values. Never read .value, cookies or storage.
    const full=(scope.innerText || '').slice(0,2000000);
    const selectorFor = element => {
      if (element.id && doc.querySelectorAll('#'+CSS.escape(element.id)).length === 1) return '#'+CSS.escape(element.id);
      const parts=[];
      for (let node=element;node && node.nodeType===1;node=node.parentElement) {
        const siblings=node.parentElement ? Array.from(node.parentElement.children).filter(e=>e.tagName===node.tagName) : [node];
        parts.unshift(node.tagName.toLowerCase()+':nth-of-type('+(siblings.indexOf(node)+1)+')');
        if (node===doc.documentElement) break;
      }
      return parts.join(' > ');
    };
    const elements=Array.from(scope.querySelectorAll('a,button,input,textarea,select,[contenteditable=true],[role=button]'))
      .filter(visible).slice(0,200).map(e=>({selector:selectorFor(e),tag:e.tagName.toLowerCase(),
        label:(e.getAttribute('aria-label') || e.getAttribute('placeholder') || (e.tagName==='INPUT' ? '' : e.innerText) || '').slice(0,300),
        type:e.getAttribute('type') || '',disabled:!!e.disabled,sensitive:sensitive(e)}));
    return {url:safeUrl(doc.location.href),title:doc.title,loading:doc.readyState!=='complete',frame:frameId,
      page:request.page,pages:Math.max(1,Math.ceil(full.length/pageSize)),
      text:full.slice((request.page-1)*pageSize,request.page*pageSize),elements};
  }
  if (request.kind==='scroll') {
    const root=doc.scrollingElement || doc.documentElement;
    if (request.selector) choose(request.selector).scrollIntoView({block:'center',behavior:'instant'});
    else if (request.to==='top') win.scrollTo({top:0,behavior:'instant'});
    else if (request.to==='bottom') win.scrollTo({top:root.scrollHeight,behavior:'instant'});
    else win.scrollBy({top:request.by ?? Math.round(win.innerHeight*0.9),behavior:'instant'});
    return {scrollY:Math.round(win.scrollY),scrollHeight:root.scrollHeight,viewportHeight:win.innerHeight,
      atBottom:win.scrollY+win.innerHeight>=root.scrollHeight-2,frame:frameId};
  }
  const target=choose(request.selector);
  if (!visible(target)) throw new Error('Element is not visible');
  if (target.disabled || target.getAttribute('aria-disabled')==='true') throw new Error('Element is disabled');
  if (sensitive(target)) throw new Error('Password and one-time-code fields require the password manager or user handoff');
  target.scrollIntoView({block:'nearest'});
  if (request.kind==='click') {
    target.click();
    return {dispatched:true};
  }
  target.focus();
  if (target.readOnly) throw new Error('Element is read-only');
  if (request.kind==='type') {
    const textField=target instanceof win.HTMLTextAreaElement ||
      (target instanceof win.HTMLInputElement && ['text','search','url','tel','email'].includes(target.type));
    if (!textField && !target.isContentEditable) throw new Error('Element is not an editable text field or editor');
    if (target.isContentEditable) {
      const range=doc.createRange();
      range.selectNodeContents(target);
      if (!request.clear) range.collapse(false);
      const selection=win.getSelection();
      selection.removeAllRanges(); selection.addRange(range);
    } else if (request.clear) {target.select();}
    else {try {target.setSelectionRange(target.value.length,target.value.length);} catch (_) {}}
    // Preserve rich editor undo/input behavior. Do not replace the editor DOM if
    // the engine refuses insertion; report the actual failure instead.
    if (target.isContentEditable) {
      const inserted=request.text ? doc.execCommand('insertText',false,request.text) : (!request.clear || doc.execCommand('delete'));
      if (!inserted) throw new Error('Browser refused text insertion into this editor');
    } else {
      const next=(request.clear ? '' : target.value)+request.text;
      const proto=target instanceof win.HTMLTextAreaElement ? win.HTMLTextAreaElement.prototype : win.HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto,'value').set.call(target,next);
      target.dispatchEvent(new win.Event('input',{bubbles:true}));
      target.dispatchEvent(new win.Event('change',{bubbles:true}));
    }
    return {typed:true,method:'text-insertion',nativeKeys:false};
  }
  if (target instanceof win.HTMLInputElement || target instanceof win.HTMLTextAreaElement || target instanceof win.HTMLSelectElement) {
    if (target.type==='file') throw new Error('File upload requires the native upload API');
    const proto=target instanceof win.HTMLTextAreaElement ? win.HTMLTextAreaElement.prototype : target instanceof win.HTMLSelectElement ? win.HTMLSelectElement.prototype : win.HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto,'value').set.call(target,request.text);
  } else if (target.isContentEditable) {target.textContent=request.text;}
  else {throw new Error('Element is not an editable text field');}
  target.dispatchEvent(new win.Event('input',{bubbles:true}));
  target.dispatchEvent(new win.Event('change',{bubbles:true}));
  return {dispatched:true};
} catch(error) {return {error:String(error.message || error).slice(0,1000)};}
"#;

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_srcdoc_frames_are_allowed_without_opening_arbitrary_url_schemes() {
        for address in ["about:blank", "about:srcdoc", "https://example.test/frame"] {
            assert!(allow_native_navigation(address));
        }
        for address in [
            "about:config",
            "about:srcdoc?file=secret",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,<h1>test</h1>",
            "https://user:password@example.test",
        ] {
            assert!(!allow_native_navigation(address));
        }
        assert!(validate_url("about:srcdoc").is_err());
        assert!(validate_url("about:blank").is_err());
    }
    #[test]
    fn validates_urls_and_rejects_local_or_credential_urls() {
        for value in [
            "javascript:alert(1)",
            "file:///etc/passwd",
            "https://user:secret@example.com",
            "data:text/html,x",
        ] {
            assert!(validate_url(value).is_err());
        }
        assert!(validate_url("https://example.com/path?q=value").is_ok());
    }
    #[test]
    fn command_roundtrip_and_unknown_actions_fail_closed() {
        let request:BrowserRequest=serde_json::from_value(serde_json::json!({"id":"one","threadId":"52F19AE7-6B00-45C6-B4C7-13F03E3A3EF2","action":"read"})).unwrap();
        request.validate().unwrap();
        assert!(matches!(
            request.action,
            BrowserAction::Read { page: 1, .. }
        ));
        assert!(serde_json::from_value::<BrowserRequest>(serde_json::json!({"id":"one","threadId":request.thread_id,"action":"evaluate","script":"bad"})).is_err());
    }
    #[test]
    fn scripts_json_encode_selector_and_text() {
        let value = "\";globalThis.injected=true;//\n";
        let script = script(&BrowserAction::Input {
            selector: value.into(),
            text: value.into(),
        })
        .unwrap()
        .unwrap();
        assert!(script.contains(&serde_json::to_string(value).unwrap()));
        assert!(!script.contains("const request = \";globalThis"));
    }
    #[test]
    fn rejects_oversized_inputs_and_missing_tab() {
        let mut r = BrowserRequest {
            id: "one".into(),
            thread_id: uuid::Uuid::new_v4().to_string(),
            tab: None,
            frame: None,
            action: BrowserAction::Input {
                selector: "#input".into(),
                text: "x".repeat(65537),
            },
        };
        assert!(r.validate().is_err());
        r.action = BrowserAction::CloseTab;
        assert!(r.validate().is_err());
    }

    #[test]
    fn frame_commands_reject_unsupported_actions_and_unbounded_handles() {
        let thread = uuid::Uuid::new_v4().to_string();
        for action in [
            "navigate",
            "new-tab",
            "downloads",
            "frames",
            "close-tab",
            "hide",
        ] {
            let value = serde_json::json!({"id":"frame-test","threadId":thread,"frame":"frame-one","tab":"tab-one","action":action,"url":"https://example.test"});
            let request: BrowserRequest = serde_json::from_value(value).unwrap();
            assert!(
                request.validate().is_err(),
                "{action} must not silently target the top frame"
            );
        }
        let mut value = serde_json::json!({"id":"frame-test","threadId":thread,"frame":"frame-one","action":"read"});
        let request: BrowserRequest = serde_json::from_value(value.clone()).unwrap();
        assert!(request.validate().is_ok());
        value["frame"] = serde_json::json!("x".repeat(129));
        assert!(
            serde_json::from_value::<BrowserRequest>(value)
                .unwrap()
                .validate()
                .is_err()
        );
    }

    #[test]
    fn scroll_commands_validate_exclusive_targets_edges_and_distances() {
        let thread = uuid::Uuid::new_v4().to_string();
        for arguments in [
            serde_json::json!({}),
            serde_json::json!({"by":-400}),
            serde_json::json!({"to":"bottom"}),
            serde_json::json!({"selector":"#pane"}),
        ] {
            let mut value =
                serde_json::json!({"id":"scroll-test","threadId":thread,"action":"scroll"});
            value
                .as_object_mut()
                .unwrap()
                .extend(arguments.as_object().unwrap().clone());
            assert!(
                serde_json::from_value::<BrowserRequest>(value)
                    .unwrap()
                    .validate()
                    .is_ok()
            );
        }
        for arguments in [
            serde_json::json!({"by":1000001}),
            serde_json::json!({"by":-1000001}),
            serde_json::json!({"to":"top","selector":"#pane"}),
            serde_json::json!({"to":"bottom","by":50}),
            serde_json::json!({"selector":""}),
        ] {
            let mut value =
                serde_json::json!({"id":"scroll-test","threadId":thread,"action":"scroll"});
            value
                .as_object_mut()
                .unwrap()
                .extend(arguments.as_object().unwrap().clone());
            assert!(
                serde_json::from_value::<BrowserRequest>(value)
                    .unwrap()
                    .validate()
                    .is_err()
            );
        }
        assert!(
            serde_json::from_value::<BrowserRequest>(
                serde_json::json!({"id":"x","threadId":thread,"action":"scroll","to":"anywhere"})
            )
            .is_err()
        );
    }

    #[test]
    fn frame_and_type_arguments_are_encoded_and_text_is_bounded() {
        let payload = "\";globalThis.injected=true;//\n";
        let mut request: BrowserRequest = serde_json::from_value(serde_json::json!({
            "id":"type-test","threadId":uuid::Uuid::new_v4().to_string(),"action":"type",
            "frame":payload,"selector":"#editor","text":payload,"clear":true,
        }))
        .unwrap();
        let source = script_for_request(&request).unwrap().unwrap();
        assert!(source.contains(&format!(
            "const frameId = {};",
            serde_json::to_string(payload).unwrap()
        )));
        assert!(source.contains(&serde_json::to_string(payload).unwrap()));
        if let BrowserAction::Type { text, .. } = &mut request.action {
            *text = "x".repeat(65537);
        }
        assert!(script_for_request(&request).is_err());
    }
}
