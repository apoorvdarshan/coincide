//! Internal test host for the exact production native adapter modules.
//! It has no binary, application UI toolkit, copied adapter, or independent authority.
#![cfg(any(windows, target_os = "linux"))]

#[cfg(test)]
#[path = "../../coincide-desktop/src/computer_use.rs"]
mod computer_use;

#[cfg(all(test, target_os = "linux"))]
#[path = "../../coincide-desktop/src/appshots_platform.rs"]
mod appshots_platform;
#[cfg(all(test, target_os = "linux"))]
#[path = "../../coincide-desktop/src/notification_activity.rs"]
mod notification_activity;
#[cfg(test)]
#[path = "../../coincide-desktop/src/notifications.rs"]
mod notifications;
