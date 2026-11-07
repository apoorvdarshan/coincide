//! The app around its main window, as Swift's `AppDelegate` and
//! `SecondInstance`: the Dock icon reopens the main window after it was
//! closed, its menu offers New Thread and the five most recent threads, its
//! badge counts approvals waiting, and a second copy started while Coincide
//! runs brings the running one forward and quits.
use gpui_kit::{App, Global, MenuItem, actions};
use serde_json::{Value, json};
use std::{
    path::Path,
    sync::{Arc, Mutex},
};

actions!(
    coincide_dock,
    [
        DockNewThread,
        DockRecent0,
        DockRecent1,
        DockRecent2,
        DockRecent3,
        DockRecent4
    ]
);

/// Swift `applicationDockMenu` lists this many recent threads.
pub(super) const DOCK_RECENT: usize = 5;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum DockRequest {
    NewThread,
    OpenThread(String),
}

#[derive(Default)]
struct DockState {
    pending: Arc<Mutex<Vec<DockRequest>>>,
    /// The (id, title) pairs the current Dock menu lists, in its order.
    recent: Arc<Mutex<Vec<(String, String)>>>,
    badge: Option<usize>,
}
impl Global for DockState {}

fn push(cx: &mut App, request: impl FnOnce(&[(String, String)]) -> Option<DockRequest>) {
    if !cx.has_global::<DockState>() {
        return;
    }
    let state = cx.global::<DockState>();
    let request = state.recent.lock().ok().and_then(|recent| request(&recent));
    if let (Some(request), Ok(mut pending)) = (request, state.pending.lock()) {
        pending.push(request);
    }
}
fn recent(index: usize) -> impl Fn(&[(String, String)]) -> Option<DockRequest> {
    move |recent| {
        recent
            .get(index)
            .map(|(id, _)| DockRequest::OpenThread(id.clone()))
    }
}

/// Registers the Dock menu's actions. Their handlers only queue a request for
/// the main window's next tick.
pub(super) fn install(cx: &mut App) {
    cx.set_global(DockState::default());
    cx.on_action(|_: &DockNewThread, cx| push(cx, |_| Some(DockRequest::NewThread)));
    cx.on_action(|_: &DockRecent0, cx| push(cx, recent(0)));
    cx.on_action(|_: &DockRecent1, cx| push(cx, recent(1)));
    cx.on_action(|_: &DockRecent2, cx| push(cx, recent(2)));
    cx.on_action(|_: &DockRecent3, cx| push(cx, recent(3)));
    cx.on_action(|_: &DockRecent4, cx| push(cx, recent(4)));
}

pub(super) fn take_requests(cx: &mut App) -> Vec<DockRequest> {
    if !cx.has_global::<DockState>() {
        return Vec::new();
    }
    cx.global::<DockState>()
        .pending
        .lock()
        .map(|mut pending| std::mem::take(&mut *pending))
        .unwrap_or_default()
}

/// The Dock menu's items: New Thread, then the recent threads after a separator.
pub(super) fn menu_items(recent: &[(String, String)]) -> Vec<MenuItem> {
    let mut items = vec![MenuItem::action("New Thread", DockNewThread)];
    if !recent.is_empty() {
        items.push(MenuItem::separator());
    }
    for (index, (_, title)) in recent.iter().take(DOCK_RECENT).enumerate() {
        let title = title.clone();
        items.push(match index {
            0 => MenuItem::action(title, DockRecent0),
            1 => MenuItem::action(title, DockRecent1),
            2 => MenuItem::action(title, DockRecent2),
            3 => MenuItem::action(title, DockRecent3),
            _ => MenuItem::action(title, DockRecent4),
        });
    }
    items
}

/// Rebuilds the Dock menu when its recent threads changed (macOS only).
pub(super) fn update_menu(recent: Vec<(String, String)>, cx: &mut App) {
    if !cfg!(target_os = "macos") || !cx.has_global::<DockState>() {
        return;
    }
    let shared = cx.global::<DockState>().recent.clone();
    let Ok(mut listed) = shared.lock() else {
        return;
    };
    if *listed == recent {
        return;
    }
    let items = menu_items(&recent);
    *listed = recent;
    drop(listed);
    cx.set_dock_menu(items);
}

/// The approvals waiting, from `app.status`'s per-thread `pendingApprovals`.
pub(super) fn pending_approvals(status: &Value) -> usize {
    status["pendingApprovals"]
        .as_object()
        .map(|threads| {
            threads
                .values()
                .filter_map(Value::as_u64)
                .map(|count| count as usize)
                .sum()
        })
        .unwrap_or(0)
}

/// Shows `count` on the Dock icon, or nothing for zero (macOS only).
pub(super) fn set_badge(count: usize, cx: &mut App) {
    if !cx.has_global::<DockState>() || cx.global::<DockState>().badge == Some(count) {
        return;
    }
    cx.global_mut::<DockState>().badge = Some(count);
    #[cfg(target_os = "macos")]
    {
        let label = (count > 0).then(|| std::ffi::CString::new(count.to_string()).ok());
        let label = label.flatten();
        // SAFETY: GPUI runs this on the main thread; the C string outlives the call.
        unsafe {
            ffi::coincide_set_dock_badge(label.as_ref().map_or(std::ptr::null(), |l| l.as_ptr()))
        };
    }
}

/// The most recently active threads the Dock menu offers, archived ones left
/// out, as `(id, title)`.
pub(super) fn recent_threads(
    threads: &[coincide_core::store::ThreadSummary],
) -> Vec<(String, String)> {
    let mut threads = threads
        .iter()
        .filter(|thread| !thread.archived && !thread.id.is_empty())
        .collect::<Vec<_>>();
    let updated = |thread: &coincide_core::store::ThreadSummary| {
        thread
            .navigation
            .as_ref()
            .and_then(|meta| meta.updated_at)
            .unwrap_or(f64::MIN)
    };
    threads.sort_by(|a, b| updated(b).total_cmp(&updated(a)));
    threads
        .into_iter()
        .take(DOCK_RECENT)
        .map(|thread| {
            let title = thread.title.trim();
            let title = if title.is_empty() {
                "New conversation".to_owned()
            } else {
                title.chars().take(80).collect()
            };
            (thread.id.clone(), title)
        })
        .collect()
}

/// When another Coincide already answers on the control socket, asks it to
/// come forward and returns true, so this copy quits instead of opening a
/// second window onto the same threads.
pub(super) fn hand_off(socket: &Path) -> bool {
    if !socket.exists() && !cfg!(windows) {
        return false;
    }
    #[cfg(target_os = "windows")]
    // SAFETY: plain Win32 call; lets the running copy take the foreground.
    unsafe {
        let _ = windows::Win32::UI::WindowsAndMessaging::AllowSetForegroundWindow(
            windows::Win32::UI::WindowsAndMessaging::ASFW_ANY,
        );
    }
    coincide_core::control::request(
        socket,
        &json!({"id": "second-instance", "method": "app.activate", "params": {}}),
    )
    .is_ok()
}

/// PNG bytes of an application's Finder icon, `side` pixels square.
#[cfg(target_os = "macos")]
pub(super) fn application_icon_png(path: &std::ffi::CStr, side: i32) -> Option<Vec<u8>> {
    let mut length = 0usize;
    // SAFETY: the C function returns malloc'd bytes of `length`, freed below.
    unsafe {
        let bytes = ffi::coincide_application_icon_png(path.as_ptr(), side, &mut length);
        if bytes.is_null() {
            return None;
        }
        let png = std::slice::from_raw_parts(bytes, length).to_vec();
        ffi::coincide_free(bytes.cast());
        Some(png)
    }
}

#[cfg(target_os = "macos")]
mod ffi {
    unsafe extern "C" {
        pub fn coincide_application_icon_png(
            path: *const std::ffi::c_char,
            side: i32,
            length: *mut usize,
        ) -> *mut u8;
        pub fn coincide_free(bytes: *mut std::ffi::c_void);
        pub fn coincide_set_dock_badge(label: *const std::ffi::c_char);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use coincide_core::store::{ThreadNavigation, ThreadSummary};

    fn thread(id: &str, title: &str, updated: f64, archived: bool) -> ThreadSummary {
        ThreadSummary {
            id: id.into(),
            title: title.into(),
            project_id: String::new(),
            archived,
            pinned: false,
            snoozed_until: None,
            navigation: Some(ThreadNavigation {
                updated_at: Some(updated),
                ..Default::default()
            }),
        }
    }

    #[::core::prelude::v1::test]
    fn the_dock_lists_the_five_most_recent_unarchived_threads() {
        let threads = (0..8)
            .map(|i| {
                thread(
                    &format!("t{i}"),
                    &format!("Thread {i}"),
                    f64::from(i),
                    i == 7,
                )
            })
            .chain([thread("blank", "  ", 3.5, false)])
            .collect::<Vec<_>>();
        let recent = recent_threads(&threads);
        assert_eq!(
            recent.iter().map(|(id, _)| id.as_str()).collect::<Vec<_>>(),
            ["t6", "t5", "t4", "blank", "t3"]
        );
        assert_eq!(recent[3].1, "New conversation");
        assert_eq!(menu_items(&recent).len(), 1 + 1 + 5);
        assert_eq!(menu_items(&[]).len(), 1);
    }

    #[::core::prelude::v1::test]
    fn the_badge_counts_every_threads_waiting_approvals() {
        assert_eq!(pending_approvals(&json!({})), 0);
        assert_eq!(
            pending_approvals(&json!({"pendingApprovals":{"a":2,"b":1}})),
            3
        );
    }

    #[::core::prelude::v1::test]
    fn no_running_copy_means_no_hand_off() {
        let dir = std::env::temp_dir().join(format!("coincide-hand-off-{}", uuid::Uuid::new_v4()));
        assert!(!hand_off(&dir.join("control.sock")));
    }
}
