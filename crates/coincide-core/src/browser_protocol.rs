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
            BrowserAction::Input { selector, text } => {
                validate_selector(selector)?;
                ensure!(text.len() <= 65536, "Input exceeds 64 KiB");
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
/// never concatenated into executable source. These operations target the main
/// frame only; cross-origin frame support needs a separate native implementation.
pub fn script(action: &BrowserAction) -> Result<Option<String>> {
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
        BrowserAction::Back => return Ok(Some("history.back(); ({dispatched:true})".into())),
        BrowserAction::Forward => return Ok(Some("history.forward(); ({dispatched:true})".into())),
        BrowserAction::Reload => return Ok(Some("location.reload(); ({dispatched:true})".into())),
        _ => return Ok(None),
    };
    Ok(Some(format!(
        "(() => {{ const request = {}; {} }})()",
        serde_json::to_string(&payload)?,
        SCRIPT
    )))
}

const SCRIPT: &str = r#"
try {
  const visible = e => !!e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden';
  const sensitive = e => e.matches('input[type=password],input[autocomplete=one-time-code]');
  const choose = selector => {
    const all = document.querySelectorAll(selector);
    if (all.length !== 1) throw new Error(all.length ? 'Selector matches multiple elements' : 'Element not found');
    return all[0];
  };
  if (request.kind === 'read') {
    const scope = request.selector ? choose(request.selector) : document.body;
    if (!scope) return {url:location.href,title:document.title,loading:document.readyState !== 'complete',text:'',elements:[]};
    const pageSize=20000;
    // innerText does not expose input values. Never read .value, cookies or storage.
    const full=(scope.innerText || '').slice(0,2000000);
    const selectorFor = element => {
      if (element.id && document.querySelectorAll('#'+CSS.escape(element.id)).length === 1) return '#'+CSS.escape(element.id);
      const parts=[];
      for (let node=element;node && node.nodeType===1;node=node.parentElement) {
        const siblings=node.parentElement ? Array.from(node.parentElement.children).filter(e=>e.tagName===node.tagName) : [node];
        parts.unshift(node.tagName.toLowerCase()+':nth-of-type('+(siblings.indexOf(node)+1)+')');
        if (node===document.documentElement) break;
      }
      return parts.join(' > ');
    };
    const elements=Array.from(scope.querySelectorAll('a,button,input,textarea,select,[contenteditable=true],[role=button]'))
      .filter(visible).slice(0,200).map(e=>({selector:selectorFor(e),tag:e.tagName.toLowerCase(),
        label:(e.getAttribute('aria-label') || e.getAttribute('placeholder') || (e.tagName==='INPUT' ? '' : e.innerText) || '').slice(0,300),
        type:e.getAttribute('type') || '',disabled:!!e.disabled,sensitive:sensitive(e)}));
    return {url:location.href,title:document.title,loading:document.readyState!=='complete',
      page:request.page,pages:Math.max(1,Math.ceil(full.length/pageSize)),
      text:full.slice((request.page-1)*pageSize,request.page*pageSize),elements};
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
  if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) {
    if (target.type==='file') throw new Error('File upload requires the native upload API');
    const proto=target instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto,'value').set.call(target,request.text);
  } else if (target.isContentEditable) {target.textContent=request.text;}
  else {throw new Error('Element is not an editable text field');}
  target.dispatchEvent(new Event('input',{bubbles:true}));
  target.dispatchEvent(new Event('change',{bubbles:true}));
  return {dispatched:true};
} catch(error) {return {error:String(error.message || error).slice(0,1000)};}
"#;

#[cfg(test)]
mod tests {
    use super::*;
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
            action: BrowserAction::Input {
                selector: "#input".into(),
                text: "x".repeat(65537),
            },
        };
        assert!(r.validate().is_err());
        r.action = BrowserAction::CloseTab;
        assert!(r.validate().is_err());
    }
}
