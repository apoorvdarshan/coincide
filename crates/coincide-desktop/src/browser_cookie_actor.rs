//! Native cookie batch ownership. No hidden WebView, automatic navigation,
//! selection, mutation retries, or atomic/durable whole-import claims.
use super::*;
use crate::browser_settings::cookie_flow::{
    ImportRevision, ImportStatus, PreparedImport, Reservation, ReserveRequest,
};
#[cfg(target_os = "macos")]
use cookie_import::{PreparedCookie, ReadbackReceipt, Receipt, Status, Target};
#[cfg(any(target_os = "macos", test))]
#[derive(Clone)]
struct ProfileFence {
    thread: String,
    revision: u64,
    selected: ProfileChoice,
}
#[cfg(any(target_os = "macos", test))]
impl ProfileFence {
    fn allows(&self, current: &ProfileSnapshot) -> bool {
        self.thread == current.thread
            && self.revision == current.revision
            && self.selected == current.selected
    }
}
#[cfg(any(target_os = "macos", test))]
#[derive(PartialEq, Eq, Debug)]
enum ReadbackDisposition {
    Waiting,
    DrainedIncomplete,
    Promote,
}
#[cfg(any(target_os = "macos", test))]
fn finish_readback(
    status: &mut ImportStatus,
    stopped: bool,
    counts: cookie_import::ReadbackCounts,
    released: bool,
) -> ReadbackDisposition {
    if !released {
        status.pending = true;
        return ReadbackDisposition::Waiting;
    }
    status.pending = false;
    status.verified = counts.matched;
    if stopped {
        status.message="Readback arrived after import revocation. Counts are retained; the unselected profile stays incomplete/uncertain.".into();
        ReadbackDisposition::DrainedIncomplete
    } else if counts.exact() {
        status.message="Exact cookie readback matched. The new profile remains unselected; disk persistence has not been proven.".into();
        ReadbackDisposition::Promote
    } else {
        status.message="Cookie readback did not exactly match. The profile remains incomplete/uncertain and unselected.".into();
        ReadbackDisposition::DrainedIncomplete
    }
}
#[cfg(target_os = "macos")]
pub(super) struct Actor {
    context: crate::browser_settings::cookie_flow::ImportContext,
    binding: coincide_core::firefox_cookie_import::Binding,
    fence: ProfileFence,
    target: Option<Target>,
    waiting: Option<Receipt>,
    readback: Option<ReadbackReceipt>,
    remaining: VecDeque<PreparedCookie>,
    applied: Vec<PreparedCookie>,
    status: ImportStatus,
    published: Option<ImportStatus>,
    stopped: bool,
    marker_attempted: bool,
}
#[cfg(target_os = "macos")]
impl Actor {
    pub(super) fn stop(&mut self) {
        if self.marker_attempted
            && self.target.is_none()
            && self.waiting.is_none()
            && self.readback.is_none()
        {
            return;
        }
        self.status.transition = ImportRevision::Progress;
        self.stopped = true;
        self.status.message="Import stopped. The new unselected profile may contain a partial import; undispatched cookies are not retried.".into();
    }
    fn poll(&mut self, closed: bool, current: &ProfileSnapshot) -> bool {
        if self.target.is_none() && self.waiting.is_none() && self.readback.is_none() {
            return false;
        }
        self.status.transition = ImportRevision::Progress;
        if closed || !self.context.valid() || !self.fence.allows(current) {
            self.stop();
        }
        if let Some(waiting) = &self.waiting {
            match waiting.status() {
                Status::DispatchedUnknown => {
                    self.status.pending = true;
                    return false;
                }
                Status::StoredBlockRetained => {
                    self.status.pending = true;
                    return false;
                }
                Status::StoredBlockReleased => {
                    self.waiting = None;
                    if let Some(cookie) = self.remaining.pop_front() {
                        self.applied.push(cookie);
                        self.status.applied += 1;
                        self.status.undispatched = self.remaining.len();
                    }
                }
            }
        }
        if let Some(readback) = &self.readback {
            let Some((counts, released)) = readback.result() else {
                self.status.pending = true;
                return false;
            };
            let disposition = finish_readback(&mut self.status, self.stopped, counts, released);
            if disposition == ReadbackDisposition::Waiting {
                return false;
            }
            self.readback = None;
            self.target = None;
            return disposition == ReadbackDisposition::Promote;
        }
        if self.stopped {
            self.target = None;
            self.status.pending = false;
            return false;
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|value| value.as_secs())
            .unwrap_or(0);
        if self
            .remaining
            .front()
            .is_some_and(|cookie| cookie.expired(now))
        {
            self.status.expired += 1;
            self.remaining.pop_front();
            self.status.undispatched = self.remaining.len();
            self.stop();
            self.target = None;
            self.status.pending = false;
            return false;
        }
        let Some(target) = self.target.as_ref() else {
            self.status.pending = false;
            return false;
        };
        if let Some(cookie) = self.remaining.front() {
            match target.dispatch_prepared(cookie, &self.binding) {
                Ok(receipt) => {
                    self.waiting = Some(receipt);
                    self.status.pending = true;
                    self.status.message =
                        "Waiting for actual native cookie completion and block release.".into();
                }
                Err(_) => {
                    self.status.refused += 1;
                    self.remaining.pop_front();
                    self.status.undispatched = self.remaining.len();
                    self.stop();
                    self.target = None;
                    self.status.pending = false;
                }
            }
        } else {
            let expected = std::mem::take(&mut self.applied);
            match target.readback(expected, &self.binding) {
                Ok(receipt) => {
                    self.readback = Some(receipt);
                    self.status.pending = true;
                    self.status.message =
                        "Checking exact private cookie readback; no page has opened.".into();
                }
                Err(_) => {
                    self.stop();
                    self.target = None;
                    self.status.pending = false;
                }
            }
        }
        false
    }
}
impl BrowserController {
    pub(crate) fn reserve_cookie_import(
        &self,
        current_thread: &str,
        request: ReserveRequest,
    ) -> std::result::Result<Reservation, String> {
        if !cfg!(target_os = "macos")
            || self.shutdown.callbacks.closed()
            || !persistent_profiles_available()
            || !request.context.valid()
            || current_thread != request.context.snapshot.thread
        {
            return Err("Cookie import is unavailable or its settings context changed.".into());
        }
        let current = self.profile_snapshot(current_thread);
        if current.revision != request.context.snapshot.revision
            || current.selected != request.context.snapshot.selected
        {
            return Err("Browser profile changed. Review the cookie source again.".into());
        }
        #[cfg(target_os = "macos")]
        if self
            .cookie_actor
            .as_ref()
            .is_some_and(|actor| actor.status.pending)
        {
            return Err("Another cookie import is still owned.".into());
        }
        let fresh = self
            .profiles
            .reserve_cookie_profile(current_thread, current.revision, &request.name)
            .map_err(|_| {
                "Choose a unique new profile name (profile count must remain below32).".to_owned()
            })?;
        Ok(Reservation {
            context: request.context,
            fresh,
            hosts: request.hosts,
        })
    }
    pub(crate) fn admit_cookie_import(
        &mut self,
        current_thread: &str,
        mut prepared: PreparedImport,
    ) -> std::result::Result<ImportStatus, String> {
        if self.shutdown.callbacks.closed()
            || !prepared.reservation.context.valid()
            || current_thread != prepared.reservation.context.snapshot.thread
        {
            return Err("Cookie import context changed before native admission.".into());
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = &mut prepared;
            Err("Cookie import requires the supported macOS named-store backend.".into())
        }
        #[cfg(target_os = "macos")]
        {
            if !persistent_profiles_available()
                || self
                    .cookie_actor
                    .as_ref()
                    .is_some_and(|actor| actor.status.pending)
            {
                return Err(
                    "Cookie destination is unavailable or another import is pending.".into(),
                );
            }
            self.cookie_actor = None;
            let current = self.profile_snapshot(current_thread);
            if current.revision != prepared.reservation.context.snapshot.revision
                || current.selected != prepared.reservation.context.snapshot.selected
            {
                return Err("Browser profile changed before import admission.".into());
            }
            let id = prepared.reservation.fresh.id();
            let name = prepared.reservation.fresh.name().to_owned();
            let binding = prepared
                .reservation
                .context
                .binding(id)
                .ok_or_else(|| "Invalid import conversation.".to_owned())?;
            // Prevalidate every native representation before creating a profile
            // or data store. This Foundation-only step does not dispatch work.
            let mut expired = 0;
            let mut remaining = VecDeque::new();
            while prepared.cookies.remaining() != 0 {
                let before = prepared.cookies.remaining();
                let cookie = prepared
                    .cookies
                    .next(&binding, chrono_now())
                    .map_err(|_| "Cookie context changed during preparation.".to_owned())?;
                expired += before - prepared.cookies.remaining() - usize::from(cookie.is_some());
                let Some(cookie) = cookie else { break };
                match PreparedCookie::prepare(cookie) {
                    Ok(cookie) => remaining.push_back(cookie),
                    Err(_)=>return Err("Native cookie representation is unsupported (including SameSite=None). No profile was created and no cookie was dispatched.".into()),
                }
            }
            if remaining.is_empty() {
                return Err("All reviewed cookies expired; no profile was created.".into());
            }
            if self.shutdown.callbacks.closed() || !prepared.reservation.context.valid() {
                return Err("Cookie context closed before destination creation.".into());
            }
            self.profiles.commit_cookie_profile(current_thread,&prepared.reservation.fresh).map_err(|_|"New empty profile creation could not be confirmed. No cookies were dispatched; inspect profile metadata before trying again.".to_owned())?;
            let mut status = ImportStatus {
                profile: Some(id),
                name,
                revision: self.profiles.revision,
                transition: ImportRevision::Created {
                    previous: current.revision,
                },
                thread: current_thread.into(),
                generation: prepared.reservation.context.generation,
                expired,
                undispatched: remaining.len(),
                ..Default::default()
            };
            // Named native contexts count even when no WKWebView ever exists.
            self.shutdown.ever_native = true;
            let target = match Target::for_named_profile(
                binding.clone(),
                self.shutdown.callbacks.clone(),
            ) {
                Ok(target) => target,
                Err(_) => {
                    status.message="The new empty profile remains unselected; native cookie store is unavailable.".into();
                    return Ok(status);
                }
            };
            status.undispatched = remaining.len();
            status.pending = true;
            status.message =
                "New unselected profile marked incomplete/uncertain. No cookies dispatched yet."
                    .into();
            self.cookie_actor = Some(Actor {
                context: prepared.reservation.context,
                fence: ProfileFence {
                    thread: current_thread.into(),
                    revision: self.profiles.revision,
                    selected: current.selected,
                },
                binding,
                target: Some(target),
                waiting: None,
                readback: None,
                remaining,
                applied: Vec::new(),
                status: status.clone(),
                published: Some(status.clone()),
                stopped: false,
                marker_attempted: false,
            });
            Ok(status)
        }
    }
    pub(crate) fn cookie_import_drained(&self) -> bool {
        #[cfg(not(target_os = "macos"))]
        {
            true
        }
        #[cfg(target_os = "macos")]
        {
            self.cookie_actor.as_ref().is_none_or(|actor| {
                !actor.status.pending
                    && actor.target.is_none()
                    && actor.waiting.is_none()
                    && actor.readback.is_none()
            })
        }
    }
    pub(crate) fn poll_cookie_import(&mut self) -> Option<ImportStatus> {
        #[cfg(not(target_os = "macos"))]
        {
            None
        }
        #[cfg(target_os = "macos")]
        {
            let thread = self.cookie_actor.as_ref()?.context.snapshot.thread.clone();
            let current = self.profile_snapshot(&thread);
            let actor = self.cookie_actor.as_mut()?;
            if actor.poll(self.shutdown.callbacks.closed(), &current) && !actor.marker_attempted {
                if self.shutdown.callbacks.closed()
                    || !actor.context.valid()
                    || self.profiles.revision != actor.fence.revision
                    || self.profiles.selected(&thread) != actor.fence.selected
                {
                    actor.stop();
                } else {
                    // poll fenced current exact revision/selection before accepting
                    // readback; only this own single marker transition may advance.
                    actor.marker_attempted = true;
                    let previous = actor.fence.revision;
                    let result = self
                        .profiles
                        .mark_cookie_readback_verified(actor.binding.profile);
                    if result.is_err() {
                        actor.status.message="Cookie readback matched, but profile marker update could not be confirmed. No automatic retry or selection.".into();
                    }
                    if previous.checked_add(1) == Some(self.profiles.revision) {
                        actor.fence.revision = self.profiles.revision;
                        actor.status.revision = self.profiles.revision;
                        actor.status.transition = ImportRevision::MarkerAttempt { previous };
                    } else if self.profiles.revision != previous {
                        actor.stop();
                    }
                }
            }
            if actor.published.as_ref() == Some(&actor.status) {
                None
            } else {
                actor.published = Some(actor.status.clone());
                Some(actor.status.clone())
            }
        }
    }
}
#[cfg(target_os = "macos")]
fn chrono_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_secs().min(i64::MAX as u64) as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn snapshot() -> ProfileSnapshot {
        ProfileSnapshot {
            thread: Uuid::new_v4().to_string(),
            revision: 1,
            profiles: Vec::new(),
            selected: ProfileChoice::Private,
            open_tabs: 0,
            persistent_profiles_available: true,
            private_by_default: false,
        }
    }
    #[::core::prelude::v1::test]
    fn exact_profile_fence_rejects_foreign_revision_or_selection_before_progress() {
        let current = snapshot();
        let fence = ProfileFence {
            thread: current.thread.clone(),
            revision: current.revision,
            selected: current.selected.clone(),
        };
        assert!(fence.allows(&current));
        let mut external = current.clone();
        external.revision += 1;
        assert!(!fence.allows(&external));
        external = current.clone();
        external.selected = ProfileChoice::Persistent(Uuid::new_v4());
        assert!(!fence.allows(&external));
        external = current;
        external.thread = Uuid::new_v4().to_string();
        assert!(!fence.allows(&external));
    }
    #[::core::prelude::v1::test]
    fn late_exact_readback_after_close_or_foreign_revision_drains_without_promotion() {
        struct Release(Arc<AtomicBool>);
        impl Drop for Release {
            fn drop(&mut self) {
                self.0.store(true, Ordering::Release);
            }
        }
        for closed in [true, false] {
            let current = snapshot();
            let fence = ProfileFence {
                thread: current.thread.clone(),
                revision: current.revision,
                selected: current.selected.clone(),
            };
            let mut external = current;
            if !closed {
                external.revision += 1;
            }
            let stopped = closed || !fence.allows(&external);
            let mut owner = shutdown::Shutdown::default();
            let target = owner.callbacks.lifetimes().target();
            let block_lease = owner.callbacks.lifetimes().block();
            let ack = owner.callbacks.begin();
            let released = Arc::new(AtomicBool::new(false));
            let block = (block_lease, Release(released.clone()));
            // Semantic readback arrived, but native callback still retains its
            // captured block owner. Closing is not a release/completion ACK.
            ack.ack();
            let counts = cookie_import::ReadbackCounts {
                expected: 2,
                observed: 2,
                matched: 2,
            };
            let mut status = ImportStatus {
                pending: true,
                ..Default::default()
            };
            assert_eq!(
                finish_readback(
                    &mut status,
                    stopped,
                    counts,
                    released.load(Ordering::Acquire)
                ),
                ReadbackDisposition::Waiting
            );
            assert!(status.pending);
            assert_eq!(owner.status(0, 0, 0).callback_blocks_pending, 1);
            drop(block);
            assert_eq!(
                finish_readback(
                    &mut status,
                    stopped,
                    counts,
                    released.load(Ordering::Acquire)
                ),
                ReadbackDisposition::DrainedIncomplete
            );
            assert!(!status.pending);
            assert_eq!(status.verified, 2);
            assert!(status.message.contains("incomplete/uncertain"));
            assert!(matches!(status.transition, ImportRevision::Progress));
            drop(target);
            assert_eq!(owner.status(0, 0, 0).native_targets_pending, 0);
            assert_eq!(owner.status(0, 0, 0).callback_blocks_pending, 0);
        }
    }
}
