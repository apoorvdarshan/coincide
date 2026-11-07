//! Opt-in desktop notifications. Register/wire only after coordinator validation.
//! No constructor requests permission or delivers. Native calls belong on a worker
//! (callbacks may wait up to two seconds), never on GPUI's rendering thread.
use anyhow::{Result, bail};
use coincide_core::platform_host::notifications::{
    Alert, AlertDelivery, AlertKind, Delivery, EventKey, Route,
};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Permission {
    Unknown,
    NotDetermined,
    Denied,
    Authorized,
    Unsupported,
}
#[derive(Debug, Default, Clone, Copy)]
pub struct Settings {
    pub enabled: bool,
    /// Explicit opt-in: default payloads contain no transcript, thread title or error.
    pub include_preview: bool,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Payload {
    pub id: String,
    pub thread: Uuid,
    pub title: String,
    pub body: Option<String>,
}
pub fn event_id(key: EventKey) -> String {
    let kind = match key.kind {
        AlertKind::Completed => "completed",
        AlertKind::Failed => "failed",
        AlertKind::Approval => "approval",
        AlertKind::Question => "question",
        AlertKind::SlowStart => "slow-start",
    };
    format!("coincide-rust.{}.{}.{kind}", key.thread, key.item)
}
pub fn thread_prefix(thread: Uuid) -> String {
    format!("coincide-rust.{thread}.")
}
/// Parent click delegate can validate the namespaced identifier before opening
/// an existing thread. Never treat a notification identifier as an executable action.
pub fn thread_from_event_id(id: &str) -> Option<Uuid> {
    let mut parts = id.split('.');
    if parts.next()? != "coincide-rust" {
        return None;
    }
    let thread = Uuid::parse_str(parts.next()?).ok()?;
    Uuid::parse_str(parts.next()?).ok()?;
    if !matches!(
        parts.next()?,
        "completed" | "failed" | "approval" | "question" | "slow-start"
    ) || parts.next().is_some()
    {
        return None;
    }
    Some(thread)
}
fn payload(alert: &Alert, previews: bool) -> Payload {
    let generic = match alert.key.kind {
        AlertKind::Completed => "Agent finished",
        AlertKind::Failed => "Agent stopped with an error",
        AlertKind::Approval => "Agent needs approval",
        AlertKind::Question => "Agent has a question",
        AlertKind::SlowStart => "Agent is waiting to start",
    };
    Payload {
        id: event_id(alert.key),
        thread: alert.key.thread,
        title: if previews {
            alert.title.chars().take(120).collect()
        } else {
            generic.into()
        },
        body: if previews {
            alert.body.as_ref().map(|b| b.chars().take(240).collect())
        } else {
            None
        },
    }
}
/// Acceptance means OS API acknowledgement, not proof of banner presentation.
/// Never classify a callback timeout as definitely unsent.
pub trait Backend {
    /// Conservative default for callback-based/native adapters. Only an adapter
    /// whose methods synchronously return all app-owned native work may opt out.
    /// This does not assert that an OS notification was displayed or unsent.
    const MAY_RETAIN_NATIVE_CALLBACKS: bool = true;
    /// Only the configured, enabled native worker overrides this. Fake backends
    /// preserve the supplied UI observation without consulting the host.
    fn observe_desktop(
        &mut self,
        desktop: coincide_core::platform_host::notifications::DesktopActivity,
    ) -> coincide_core::platform_host::notifications::DesktopActivity {
        desktop
    }
    fn permission(&mut self) -> Result<Permission>;
    /// Called solely by the explicit native UI permission button hook below.
    fn request_permission(&mut self) -> Result<Permission>;
    fn post(&mut self, payload: &Payload) -> Delivery;
    /// Clear only this app namespace/thread, including pending requests.
    fn clear_thread(&mut self, thread: Uuid) -> Result<()>;
}
pub struct DesktopNotifications<B> {
    backend: B,
    settings: Settings,
    permission: Permission,
    error: Option<String>,
}
impl<B: Backend> DesktopNotifications<B> {
    pub fn new(backend: B) -> Self {
        Self {
            backend,
            settings: Settings::default(),
            permission: Permission::Unknown,
            error: None,
        }
    }
    pub fn set_settings(&mut self, settings: Settings) {
        self.settings = settings;
    }
    pub fn observe_desktop(
        &mut self,
        desktop: coincide_core::platform_host::notifications::DesktopActivity,
    ) -> coincide_core::platform_host::notifications::DesktopActivity {
        self.backend.observe_desktop(desktop)
    }
    pub fn permission_status(&self) -> Permission {
        self.permission
    }
    pub fn last_error(&self) -> Option<&str> {
        self.error.as_deref()
    }
    pub fn refresh_permission(&mut self) -> Permission {
        match self.backend.permission() {
            Ok(status) => {
                self.permission = status;
                self.error = None;
            }
            Err(error) => {
                self.permission = Permission::Unknown;
                self.error = Some(error.to_string().chars().take(512).collect());
            }
        }
        self.permission
    }
    /// Parent calls this only from a deliberate "Allow notifications" button.
    /// Delivery never calls this hook, even when status is NotDetermined.
    pub fn request_permission_from_user_action(&mut self) -> Result<Permission> {
        match self.backend.request_permission() {
            Ok(status) => {
                self.permission = status;
                self.error = None;
                Ok(status)
            }
            Err(error) => {
                self.permission = Permission::Unknown;
                self.error = Some(error.to_string().chars().take(512).collect());
                Err(error)
            }
        }
    }
}
impl<B: Backend> AlertDelivery for DesktopNotifications<B> {
    fn deliver(&mut self, route: &Route, alert: &Alert) -> Delivery {
        if !self.settings.enabled || *route != Route::Desktop {
            return Delivery::Unavailable;
        }
        if self.refresh_permission() != Permission::Authorized {
            return Delivery::Unavailable;
        }
        let result = self
            .backend
            .post(&payload(alert, self.settings.include_preview));
        self.error = match result {
            Delivery::Accepted => None,
            Delivery::Unavailable => {
                Some("Notification was not accepted by the desktop adapter".into())
            }
            Delivery::Uncertain => Some("Notification acknowledgement is uncertain".into()),
        };
        result
    }
    fn clear_thread(&mut self, thread: Uuid) {
        // Clear still works after setting is disabled or permission is revoked.
        self.error = self
            .backend
            .clear_thread(thread)
            .err()
            .map(|e| e.to_string().chars().take(512).collect());
    }
}
/// Unsupported platforms/builds explicitly refuse delivery; no shell fallback.
pub struct UnsupportedBackend;
impl Backend for UnsupportedBackend {
    fn permission(&mut self) -> Result<Permission> {
        Ok(Permission::Unsupported)
    }
    fn request_permission(&mut self) -> Result<Permission> {
        bail!("native notification support is not enabled in this build")
    }
    fn post(&mut self, _: &Payload) -> Delivery {
        Delivery::Unavailable
    }
    fn clear_thread(&mut self, _: Uuid) -> Result<()> {
        bail!("native notification clearing is not supported in this build")
    }
}

#[cfg(all(target_os = "macos", feature = "native-notifications"))]
pub mod macos {
    use super::*;
    use anyhow::Context;
    use block2::RcBlock;
    use objc2::runtime::Bool;
    use objc2_foundation::{NSArray, NSBundle, NSError, NSString};
    use objc2_user_notifications::{
        UNAuthorizationOptions, UNAuthorizationStatus, UNMutableNotificationContent,
        UNNotificationRequest, UNUserNotificationCenter,
    };
    use std::sync::mpsc::sync_channel;
    use std::time::Duration;

    /// Stateless adapter. Call only in the packaged app; no permission or delivery
    /// is performed during construction. Foreground/click delegates remain parent hooks.
    pub struct NativeBackend;
    fn center() -> Result<objc2::rc::Retained<UNUserNotificationCenter>> {
        let bundle = NSBundle::mainBundle();
        if bundle.bundleIdentifier().is_none_or(|id| id.is_empty()) {
            bail!("notifications require a packaged app with a bundle identifier");
        }
        Ok(UNUserNotificationCenter::currentNotificationCenter())
    }
    impl Backend for NativeBackend {
        fn permission(&mut self) -> Result<Permission> {
            let center = center()?;
            let (tx, rx) = sync_channel(1);
            let callback = RcBlock::new(
                move |settings: std::ptr::NonNull<
                    objc2_user_notifications::UNNotificationSettings,
                >| {
                    // SAFETY: Apple supplies a valid settings object for this callback;
                    // only a copied scalar leaves its lifetime.
                    let status = unsafe { settings.as_ref() }.authorizationStatus();
                    let mapped = match status {
                        UNAuthorizationStatus::NotDetermined => Permission::NotDetermined,
                        UNAuthorizationStatus::Denied => Permission::Denied,
                        UNAuthorizationStatus::Authorized
                        | UNAuthorizationStatus::Provisional
                        | UNAuthorizationStatus::Ephemeral => Permission::Authorized,
                        _ => Permission::Unknown,
                    };
                    let _ = tx.send(mapped);
                },
            );
            center.getNotificationSettingsWithCompletionHandler(&callback);
            rx.recv_timeout(Duration::from_secs(2))
                .context("notification status timed out")
        }
        fn request_permission(&mut self) -> Result<Permission> {
            let center = center()?;
            let (tx, rx) = sync_channel(1);
            let callback = RcBlock::new(move |_granted: Bool, error: *mut NSError| {
                let _ = tx.send(error.is_null());
            });
            center.requestAuthorizationWithOptions_completionHandler(
                UNAuthorizationOptions::Alert,
                &callback,
            );
            if !rx
                .recv_timeout(Duration::from_secs(2))
                .context("notification permission response pending; refresh status later")?
            {
                bail!("notification authorization request failed");
            }
            self.permission()
        }
        fn post(&mut self, payload: &Payload) -> Delivery {
            let Ok(center) = center() else {
                return Delivery::Unavailable;
            };
            let content = UNMutableNotificationContent::new();
            content.setTitle(&NSString::from_str(&payload.title));
            if let Some(body) = &payload.body {
                content.setBody(&NSString::from_str(body));
            }
            content.setThreadIdentifier(&NSString::from_str(&payload.thread.to_string()));
            let request = UNNotificationRequest::requestWithIdentifier_content_trigger(
                &NSString::from_str(&payload.id),
                &content,
                None,
            );
            let (tx, rx) = sync_channel(1);
            let callback = RcBlock::new(move |error: *mut NSError| {
                let _ = tx.send(error.is_null());
            });
            center.addNotificationRequest_withCompletionHandler(&request, Some(&callback));
            match rx.recv_timeout(Duration::from_secs(2)) {
                Ok(true) => Delivery::Accepted,
                Ok(false) => Delivery::Unavailable,
                Err(_) => Delivery::Uncertain,
            }
        }
        fn clear_thread(&mut self, thread: Uuid) -> Result<()> {
            let center = center()?;
            let prefix = thread_prefix(thread);
            let (tx, rx) = sync_channel(1);
            let delivered_prefix = prefix.clone();
            let delivered = RcBlock::new(
                move |items: std::ptr::NonNull<
                    NSArray<objc2_user_notifications::UNNotification>,
                >| {
                    // SAFETY: collection is borrowed only for callback duration.
                    let items = unsafe { items.as_ref() };
                    let ids: Vec<String> = (0..items.count())
                        .map(|index| {
                            items
                                .objectAtIndex(index)
                                .request()
                                .identifier()
                                .to_string()
                        })
                        .filter(|id| id.starts_with(&delivered_prefix))
                        .collect();
                    let _ = tx.send(ids);
                },
            );
            center.getDeliveredNotificationsWithCompletionHandler(&delivered);
            let ids = rx
                .recv_timeout(Duration::from_secs(2))
                .context("delivered notification enumeration timed out")?;
            let strings: Vec<_> = ids.iter().map(|id| NSString::from_str(id)).collect();
            center.removeDeliveredNotificationsWithIdentifiers(&NSArray::from_retained_slice(
                &strings,
            ));
            let (tx, rx) = sync_channel(1);
            let pending = RcBlock::new(
                move |items: std::ptr::NonNull<NSArray<UNNotificationRequest>>| {
                    // SAFETY: collection is borrowed only for callback duration.
                    let items = unsafe { items.as_ref() };
                    let ids: Vec<String> = (0..items.count())
                        .map(|index| items.objectAtIndex(index).identifier().to_string())
                        .filter(|id| id.starts_with(&prefix))
                        .collect();
                    let _ = tx.send(ids);
                },
            );
            center.getPendingNotificationRequestsWithCompletionHandler(&pending);
            let ids = rx
                .recv_timeout(Duration::from_secs(2))
                .context("pending notification enumeration timed out")?;
            let strings: Vec<_> = ids.iter().map(|id| NSString::from_str(id)).collect();
            center.removePendingNotificationRequestsWithIdentifiers(&NSArray::from_retained_slice(
                &strings,
            ));
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fake {
        permission: Permission,
        queries: usize,
        requests: usize,
        posts: Vec<Payload>,
        cleared: Vec<Uuid>,
        result: Delivery,
    }
    impl Default for Fake {
        fn default() -> Self {
            Self {
                permission: Permission::NotDetermined,
                queries: 0,
                requests: 0,
                posts: vec![],
                cleared: vec![],
                result: Delivery::Accepted,
            }
        }
    }
    impl Backend for Fake {
        fn permission(&mut self) -> Result<Permission> {
            self.queries += 1;
            Ok(self.permission)
        }
        fn request_permission(&mut self) -> Result<Permission> {
            self.requests += 1;
            self.permission = Permission::Authorized;
            Ok(self.permission)
        }
        fn post(&mut self, p: &Payload) -> Delivery {
            self.posts.push(p.clone());
            self.result
        }
        fn clear_thread(&mut self, id: Uuid) -> Result<()> {
            self.cleared.push(id);
            Ok(())
        }
    }
    fn alert() -> Alert {
        Alert {
            key: EventKey {
                thread: Uuid::new_v4(),
                item: Uuid::new_v4(),
                kind: AlertKind::Approval,
            },
            title: "PRIVATE THREAD".into(),
            body: Some("PRIVATE TRANSCRIPT".into()),
        }
    }
    #[test]
    fn disabled_and_unrequested_permission_never_prompt_or_post() {
        let mut adapter = DesktopNotifications::new(Fake::default());
        assert_eq!(
            adapter.deliver(&Route::Desktop, &alert()),
            Delivery::Unavailable
        );
        assert_eq!(adapter.backend.queries, 0);
        adapter.set_settings(Settings {
            enabled: true,
            ..Settings::default()
        });
        assert_eq!(
            adapter.deliver(&Route::Desktop, &alert()),
            Delivery::Unavailable
        );
        assert_eq!(adapter.backend.requests, 0);
        assert!(adapter.backend.posts.is_empty());
        adapter.request_permission_from_user_action().unwrap();
        assert_eq!(adapter.backend.requests, 1);
    }
    #[test]
    fn default_payload_is_private_and_ids_stable() {
        let mut adapter = DesktopNotifications::new(Fake {
            permission: Permission::Authorized,
            ..Fake::default()
        });
        adapter.set_settings(Settings {
            enabled: true,
            ..Settings::default()
        });
        let a = alert();
        assert_eq!(adapter.deliver(&Route::Desktop, &a), Delivery::Accepted);
        let p = &adapter.backend.posts[0];
        assert_eq!(p.title, "Agent needs approval");
        assert!(p.body.is_none());
        assert_eq!(p.id, event_id(a.key));
        assert!(p.id.starts_with(&thread_prefix(a.key.thread)));
        adapter.deliver(&Route::Desktop, &a);
        assert_eq!(adapter.backend.posts[0].id, adapter.backend.posts[1].id);
        assert_eq!(adapter.backend.queries, 2);
    }
    #[test]
    fn permission_revocation_is_checked_and_remote_routes_refused() {
        let mut adapter = DesktopNotifications::new(Fake {
            permission: Permission::Authorized,
            ..Fake::default()
        });
        adapter.set_settings(Settings {
            enabled: true,
            ..Settings::default()
        });
        let a = alert();
        adapter.deliver(&Route::Desktop, &a);
        adapter.backend.permission = Permission::Denied;
        assert_eq!(adapter.deliver(&Route::Desktop, &a), Delivery::Unavailable);
        assert_eq!(
            adapter.deliver(&Route::Device("fixture".into()), &a),
            Delivery::Unavailable
        );
        assert_eq!(adapter.backend.posts.len(), 1);
        assert_eq!(adapter.backend.requests, 0);
    }
    #[test]
    fn explicit_preview_bounded_and_uncertainty_preserved() {
        let mut adapter = DesktopNotifications::new(Fake {
            permission: Permission::Authorized,
            result: Delivery::Uncertain,
            ..Fake::default()
        });
        adapter.set_settings(Settings {
            enabled: true,
            include_preview: true,
        });
        let mut a = alert();
        a.body = Some("界".repeat(400));
        assert_eq!(adapter.deliver(&Route::Desktop, &a), Delivery::Uncertain);
        assert_eq!(
            adapter.backend.posts[0]
                .body
                .as_ref()
                .unwrap()
                .chars()
                .count(),
            240
        );
        assert!(adapter.last_error().is_some());
    }
    #[test]
    fn clear_thread_works_while_disabled_and_ids_separate_kinds() {
        let mut adapter = DesktopNotifications::new(Fake::default());
        let a = alert();
        adapter.clear_thread(a.key.thread);
        assert_eq!(adapter.backend.cleared, vec![a.key.thread]);
        let mut changed = a.key;
        changed.kind = AlertKind::Question;
        assert_ne!(event_id(a.key), event_id(changed));
    }
    #[test]
    fn click_identifier_requires_namespace_uuids_and_known_event() {
        let a = alert();
        assert_eq!(thread_from_event_id(&event_id(a.key)), Some(a.key.thread));
        assert_eq!(
            thread_from_event_id(&format!("{}.extra", event_id(a.key))),
            None
        );
        assert_eq!(
            thread_from_event_id(&event_id(a.key).replace("coincide-rust", "coincide")),
            None
        );
        assert_eq!(
            thread_from_event_id(&event_id(a.key).replace("approval", "execute")),
            None
        );
    }
    #[test]
    fn status_and_clear_errors_are_visible_without_attempting_post() {
        struct Fails;
        impl Backend for Fails {
            fn permission(&mut self) -> Result<Permission> {
                bail!("fixture status unavailable");
            }
            fn request_permission(&mut self) -> Result<Permission> {
                bail!("fixture request unavailable");
            }
            fn post(&mut self, _: &Payload) -> Delivery {
                panic!("must not post without status");
            }
            fn clear_thread(&mut self, _: Uuid) -> Result<()> {
                bail!("fixture clear unavailable");
            }
        }
        let mut adapter = DesktopNotifications::new(Fails);
        adapter.set_settings(Settings {
            enabled: true,
            ..Settings::default()
        });
        let a = alert();
        assert_eq!(adapter.deliver(&Route::Desktop, &a), Delivery::Unavailable);
        assert_eq!(adapter.permission_status(), Permission::Unknown);
        assert!(adapter.last_error().is_some());
        adapter.clear_thread(a.key.thread);
        assert_eq!(adapter.last_error(), Some("fixture clear unavailable"));
    }
    #[test]
    fn unsupported_never_claims_delivery() {
        let mut adapter = DesktopNotifications::new(UnsupportedBackend);
        adapter.set_settings(Settings {
            enabled: true,
            ..Settings::default()
        });
        assert_eq!(
            adapter.deliver(&Route::Desktop, &alert()),
            Delivery::Unavailable
        );
        assert_eq!(adapter.permission_status(), Permission::Unsupported);
        assert!(adapter.request_permission_from_user_action().is_err());
    }
}

#[cfg(all(target_os = "linux", feature = "native-notifications"))]
#[path = "notifications_linux.rs"]
pub(crate) mod linux;

#[cfg(all(windows, feature = "native-notifications"))]
#[path = "notifications_windows.rs"]
pub(crate) mod windows;
#[cfg(any(all(windows, feature = "native-notifications"), test))]
#[path = "notifications_windows_policy.rs"]
mod windows_policy;
