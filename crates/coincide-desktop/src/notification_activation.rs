//! Open the conversation associated with a user-activated notification.
use coincide_core::api::SharedEngine;
use gpui_kit::{App, SystemNotificationResponse};
use serde_json::json;
use std::{
    rc::Rc,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

#[cfg(target_os = "macos")]
pub(super) fn install(engine: SharedEngine, cx: &mut App) {
    install_with(engine, cx, super::reopen_main_window);
}

fn target(response: &SystemNotificationResponse) -> Option<uuid::Uuid> {
    if response.action_id.is_some() {
        return None;
    }
    super::notifications::thread_from_event_id(response.tag.as_ref())
}

fn install_with(engine: SharedEngine, cx: &mut App, reopen: impl Fn(&mut App) + 'static) {
    let newest = Arc::new(AtomicU64::new(0));
    let reopen: Rc<dyn Fn(&mut App)> = Rc::new(reopen);
    // GPUI installs the macOS UNUserNotificationCenter delegate before a
    // notification is posted, including when the app is opened by a click.
    cx.on_system_notification_response(move |response, cx| {
        let Some(thread) = target(&response) else {
            return;
        };
        let revision = newest.fetch_add(1, Ordering::SeqCst) + 1;
        let latest = newest.clone();
        let worker_latest = latest.clone();
        let engine = engine.clone();
        let open = cx.background_executor().spawn(async move {
            let Ok(mut engine) = engine.lock() else {
                return false;
            };
            if engine.shutdown || worker_latest.load(Ordering::SeqCst) != revision {
                return false;
            }
            let Ok(Some(id)) = engine.store.resolve_thread_id(thread) else {
                return false;
            };
            engine
                .dispatch(json!({"method":"threads.open", "params":{"threadId":id}}))
                .get("error")
                .is_none()
        });
        let reopen = reopen.clone();
        cx.spawn(async move |cx| {
            if open.await && latest.load(Ordering::SeqCst) == revision {
                let _ = cx.update(|cx| reopen(cx));
            }
        })
        .detach();
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use coincide_core::{api::Engine, store::Store};
    use gpui_kit::TestAppContext;
    use std::{cell::Cell, sync::Mutex};

    #[gpui_kit::test]
    fn notification_click_opens_only_an_existing_owned_thread(cx: &mut TestAppContext) {
        let directory = tempfile::tempdir().unwrap();
        let mut engine = Engine::new(Store::open(&directory.path().join("data.sqlite")).unwrap());
        let id = engine
            .store
            .new_thread("00000000-0000-0000-0000-000000000000")
            .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let thread = uuid::Uuid::parse_str(&id).unwrap();
        let item = uuid::Uuid::new_v4();
        let engine = Arc::new(Mutex::new(engine));
        let opened = Rc::new(Cell::new(0));
        cx.update(|cx| {
            install_with(engine.clone(), cx, {
                let opened = opened.clone();
                move |_| opened.set(opened.get() + 1)
            })
        });

        for (tag, action_id) in [
            (
                format!("coincide-rust.{thread}.{item}.completed"),
                Some("unexpected"),
            ),
            (format!("other.{thread}.{item}.completed"), None),
            (
                format!("coincide-rust.{}.{item}.completed", uuid::Uuid::new_v4()),
                None,
            ),
        ] {
            cx.simulate_system_notification_response(SystemNotificationResponse {
                tag: tag.into(),
                action_id: action_id.map(Into::into),
            });
            cx.run_until_parked();
        }
        assert_eq!(opened.get(), 0);
        assert!(engine.lock().unwrap().requested_open.is_none());

        cx.simulate_system_notification_response(SystemNotificationResponse {
            tag: format!("coincide-rust.{thread}.{item}.approval").into(),
            action_id: None,
        });
        cx.run_until_parked();
        assert_eq!(opened.get(), 1);
        assert_eq!(
            engine.lock().unwrap().requested_open.as_deref(),
            Some(id.as_str())
        );
    }
}
