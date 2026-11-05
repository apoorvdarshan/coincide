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
