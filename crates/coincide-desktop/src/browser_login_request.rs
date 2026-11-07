//! A browser request can ask for native login approval; it can never approve,
//! fetch secrets, or turn a queued private fill into a successful reply.
use coincide_core::{
    browser_protocol::{BrowserReply, BrowserRequest},
    credentials::{Login, PageBinding},
};
use serde_json::json;
use std::{
    collections::VecDeque,
    time::{Duration, Instant},
};

pub(super) const WAIT: Duration =
    Duration::from_secs(coincide_core::browser_protocol::LOGIN_REQUEST_TIMEOUT);
struct Pending {
    operation: String,
    thread: String,
    page: PageBinding,
    item: Option<String>,
    deadline: Instant,
}
#[derive(Default)]
pub(super) struct Requests {
    pending: Option<Pending>,
    replies: VecDeque<BrowserReply>,
}
impl Requests {
    pub fn pending(&self) -> bool {
        self.pending.is_some()
    }
    pub fn begin(
        &mut self,
        request: &BrowserRequest,
        page: PageBinding,
        item: Option<String>,
        now: Instant,
    ) -> bool {
        if self.pending.is_some() {
            return false;
        }
        self.pending = Some(Pending {
            operation: request.id.clone(),
            thread: request.thread_id.clone(),
            page,
            item,
            deadline: now + WAIT,
        });
        true
    }
    pub fn context(&mut self, thread: Option<&str>, page: Option<&PageBinding>, available: bool) {
        if self.pending.as_ref().is_some_and(|p| {
            !available || thread != Some(p.thread.as_str()) || page != Some(&p.page)
        }) {
            self.finish(Err("The login page or native approval context changed"));
        }
    }
    pub fn matches(&self, login: &Login) -> bool {
        self.pending
            .as_ref()
            .and_then(|p| p.item.as_deref())
            .is_none_or(|item| login.id == item || login.title.eq_ignore_ascii_case(item))
    }
    pub fn item(&self) -> Option<&str> {
        self.pending.as_ref()?.item.as_deref()
    }
    /// Called only by the native workflow after its real private acknowledgement,
    /// or a fixed native refusal. Neither page nor agent JSON supplies `result`.
    pub fn finish(&mut self, result: Result<(), &'static str>) {
        if let Some(p) = self.pending.take() {
            self.replies.push_back(BrowserReply {
                id: p.operation,
                thread_id: p.thread,
                result: match result {
                    Ok(()) => json!({"filled":true}),
                    Err(error) => json!({"error":error}),
                },
            });
        }
    }
    pub fn expire(&mut self, now: Instant) -> bool {
        if self.pending.as_ref().is_some_and(|p| now >= p.deadline) {
            self.finish(Err(
                "Login approval timed out; check the page before retrying",
            ));
            return true;
        }
        false
    }
    pub fn drain(&mut self) -> impl Iterator<Item = BrowserReply> {
        self.replies.drain(..)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn page(epoch: u64) -> PageBinding {
        PageBinding::new("tab".into(), epoch, "https://owned.invalid/").unwrap()
    }
    fn request() -> BrowserRequest {
        serde_json::from_value(
            json!({"id":"op","threadId":uuid::Uuid::new_v4(),"action":"fill-login"}),
        )
        .unwrap()
    }
    #[test]
    fn request_is_metadata_only_and_requires_an_actual_native_outcome() {
        let mut owner = Requests::default();
        let r = request();
        let now = Instant::now();
        assert!(owner.begin(&r, page(1), Some("chosen".into()), now));
        assert!(owner.drain().next().is_none());
        assert!(!owner.begin(&r, page(1), None, now));
        assert!(!owner.matches(&Login {
            id: "other".into(),
            title: "Other".into(),
            username: "private".into()
        }));
        assert!(owner.matches(&Login {
            id: "chosen".into(),
            title: "Any".into(),
            username: "private".into()
        }));
        owner.finish(Ok(()));
        let reply = owner.drain().next().unwrap();
        assert_eq!(reply.result, json!({"filled":true}));
        assert!(!serde_json::to_string(&reply).unwrap().contains("private"));
        assert_eq!(reply.id, r.id);
    }
    #[test]
    fn same_origin_replacement_other_thread_and_deadline_revoke_the_request() {
        for mismatch in 0..3 {
            let mut owner = Requests::default();
            let r = request();
            let now = Instant::now();
            owner.begin(&r, page(1), None, now);
            match mismatch {
                0 => owner.context(Some(&r.thread_id), Some(&page(2)), true),
                1 => owner.context(Some("another"), Some(&page(1)), true),
                _ => {
                    assert!(!owner.expire(now + WAIT - Duration::from_millis(1)));
                    assert!(owner.expire(now + WAIT));
                }
            }
            owner.finish(Ok(()));
            let replies = owner.drain().collect::<Vec<_>>();
            assert_eq!(replies.len(), 1);
            assert!(replies[0].result.get("error").is_some());
        }
    }
}
