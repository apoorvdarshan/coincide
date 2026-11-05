//! Native cookie batch ownership. No hidden WebView, automatic navigation,
//! selection, mutation retries, or atomic/durable whole-import claims.
use super::*;
use crate::browser_settings::cookie_flow::{
    ImportStatus, PreparedImport, Reservation, ReserveRequest,
};
#[cfg(target_os = "macos")]
use cookie_import::{PreparedCookie, ReadbackReceipt, Receipt, Status, Target};
#[cfg(target_os = "macos")]
pub(super) struct Actor {
    context: crate::browser_settings::cookie_flow::ImportContext,
    binding: coincide_core::firefox_cookie_import::Binding,
    target: Option<Target>,
    waiting: Option<Receipt>,
    readback: Option<ReadbackReceipt>,
    remaining: VecDeque<PreparedCookie>,
    applied: Vec<PreparedCookie>,
    status: ImportStatus,
    stopped: bool,
    marker_attempted: bool,
}
#[cfg(target_os = "macos")]
impl Actor {
    pub(super) fn stop(&mut self) {
        self.stopped = true;
        self.status.message="Import stopped. The new unselected profile may contain a partial import; undispatched cookies are not retried.".into();
    }
    fn poll(&mut self, closed: bool) -> bool {
        if self.target.is_none() && self.waiting.is_none() && self.readback.is_none() {
            return false;
        }
        if closed || !self.context.valid() {
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
            if !released {
                self.status.pending = true;
                return false;
            }
            self.status.pending = false;
            self.status.verified = counts.matched;
            self.status.message = if counts.expected == counts.observed
                && counts.expected == counts.matched
            {
                "Exact cookie readback matched. The new profile remains unselected; disk persistence has not been proven.".into()
            } else {
                "Cookie readback did not exactly match. The profile remains incomplete/uncertain and unselected.".into()
            };
            self.readback = None;
            self.target = None;
            return counts.exact();
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
            self.profiles.commit_cookie_profile(current_thread,&prepared.reservation.fresh).map_err(|_|"New empty profile creation could not be confirmed. No cookies were dispatched; inspect profile metadata before trying again.".to_owned())?;
            let mut status = ImportStatus {
                profile: Some(id),
                name,
                revision: self.profiles.revision,
                thread: current_thread.into(),
                generation: prepared.reservation.context.generation,
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
            let mut remaining = VecDeque::new();
            while prepared.cookies.remaining() != 0 {
                let before = prepared.cookies.remaining();
                let cookie = prepared
                    .cookies
                    .next(&binding, chrono_now())
                    .map_err(|_| "Cookie context changed during preparation.".to_owned())?;
                status.expired +=
                    before - prepared.cookies.remaining() - usize::from(cookie.is_some());
                let Some(cookie) = cookie else { break };
                match target.prepare(cookie, &binding) {
                    Ok(cookie) => remaining.push_back(cookie),
                    Err(_) => {
                        status.refused += 1;
                        status.undispatched = remaining.len() + prepared.cookies.remaining();
                        status.message="Native cookie representation was refused before first dispatch (including unsupported SameSite=None). New empty profile remains unselected.".into();
                        return Ok(status);
                    }
                }
            }
            status.undispatched = remaining.len();
            status.pending = true;
            status.message =
                "New unselected profile marked incomplete/uncertain. No cookies dispatched yet."
                    .into();
            self.cookie_actor = Some(Actor {
                context: prepared.reservation.context,
                binding,
                target: Some(target),
                waiting: None,
                readback: None,
                remaining,
                applied: Vec::new(),
                status: status.clone(),
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
            let actor = self.cookie_actor.as_mut()?;
            if actor.poll(self.shutdown.callbacks.closed()) && !actor.marker_attempted {
                actor.marker_attempted = true;
                if self
                    .profiles
                    .mark_cookie_readback_verified(actor.binding.profile)
                    .is_err()
                {
                    actor.status.message="Cookie readback matched, but profile marker update could not be confirmed. No automatic retry or selection.".into();
                }
                actor.status.revision = self.profiles.revision;
            }
            Some(actor.status.clone())
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
