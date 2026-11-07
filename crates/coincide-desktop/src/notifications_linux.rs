//! freedesktop Notifications on the existing serialized notification worker.
//! No bus connection, activation, permission query or delivery at construction.
use super::Payload;
use crate::notification_server::{NativeServer, Server};
use anyhow::{Result, ensure};
use std::{
    collections::{BTreeMap, HashMap},
    time::Duration,
};
use zbus::blocking::{Connection, Proxy, connection::Builder};
#[derive(Default)]
pub(crate) struct BusServer {
    connection: Option<Connection>,
    markup: BTreeMap<String, bool>,
}
impl BusServer {
    fn connection(&mut self) -> Result<&Connection> {
        if self.connection.is_none() {
            self.connection = Some(
                Builder::session()
                    .map_err(|_| anyhow::anyhow!("Desktop notification bus unavailable"))?
                    .method_timeout(Duration::from_secs(2))
                    .build()
                    .map_err(|_| anyhow::anyhow!("Desktop notification bus unavailable"))?,
            );
        }
        Ok(self.connection.as_ref().unwrap())
    }
}
impl Server for BusServer {
    fn owner(&mut self) -> Result<String> {
        let result = (|| -> Result<(String, bool)> {
            let connection = self.connection()?;
            let notifications = Proxy::new(
                connection,
                "org.freedesktop.Notifications",
                "/org/freedesktop/Notifications",
                "org.freedesktop.Notifications",
            )?;
            let capabilities: Vec<String> = notifications
                .call("GetCapabilities", &())
                .map_err(|_| anyhow::anyhow!("Desktop notification service unavailable"))?;
            ensure!(
                capabilities.len() <= 64 && capabilities.iter().all(|c| c.len() <= 256),
                "Invalid notification service capabilities"
            );
            let bus = Proxy::new(
                connection,
                "org.freedesktop.DBus",
                "/org/freedesktop/DBus",
                "org.freedesktop.DBus",
            )?;
            let name: String = bus.call("GetNameOwner", &("org.freedesktop.Notifications",))?;
            let guid: String = bus.call("GetId", &())?;
            ensure!(
                name.starts_with(':')
                    && name.len() <= 200
                    && guid.len() == 32
                    && guid.bytes().all(|c| c.is_ascii_hexdigit()),
                "Invalid notification service identity"
            );
            Ok((
                format!("{guid}|{name}"),
                capabilities.iter().any(|c| c == "body-markup"),
            ))
        })();
        match result {
            Ok((owner, markup)) => {
                if self.markup.len() >= 16 {
                    self.markup.clear();
                }
                self.markup.insert(owner.clone(), markup);
                Ok(owner)
            }
            Err(_) => {
                self.connection = None;
                anyhow::bail!("Desktop notification service unavailable")
            }
        }
    }
    fn notify(&mut self, owner: &str, replace: u32, payload: &Payload) -> Result<u32> {
        let supports_markup = self.markup.get(owner).copied().unwrap_or(false);
        let (guid, name) = owner
            .split_once('|')
            .ok_or_else(|| anyhow::anyhow!("Notification receipt identity unavailable"))?;
        let connection = self.connection()?;
        let bus = Proxy::new(
            connection,
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
        )?;
        let current: String = bus.call("GetId", &())?;
        ensure!(current == guid, "Notification bus instance changed");
        let proxy = Proxy::new(
            connection,
            name,
            "/org/freedesktop/Notifications",
            "org.freedesktop.Notifications",
        )?;
        let hints: HashMap<&str, zbus::zvariant::Value<'_>> = HashMap::new();
        let actions: Vec<&str> = Vec::new();
        // Escape the optional preview as literal body text on servers supporting
        // markup; never put user text into action IDs, hints or service names.
        let plain = payload.body.as_deref().unwrap_or("");
        let body = if supports_markup {
            plain
                .replace('&', "&amp;")
                .replace('<', "&lt;")
                .replace('>', "&gt;")
        } else {
            plain.to_owned()
        };
        proxy
            .call(
                "Notify",
                &(
                    "Coincide",
                    replace,
                    "",
                    payload.title.as_str(),
                    body.as_str(),
                    actions,
                    hints,
                    -1i32,
                ),
            )
            .map_err(|_| anyhow::anyhow!("Desktop notification acknowledgement unavailable"))
    }
    fn close(&mut self, owner: &str, id: u32) -> Result<()> {
        let (guid, name) = owner
            .split_once('|')
            .ok_or_else(|| anyhow::anyhow!("Notification receipt identity unavailable"))?;
        let connection = self.connection()?;
        let bus = Proxy::new(
            connection,
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
        )?;
        let current: String = bus.call("GetId", &())?;
        ensure!(current == guid, "Notification bus instance changed");
        let proxy = Proxy::new(
            connection,
            name,
            "/org/freedesktop/Notifications",
            "org.freedesktop.Notifications",
        )?;
        proxy
            .call("CloseNotification", &(id,))
            .map_err(|_| anyhow::anyhow!("Desktop notification close acknowledgement unavailable"))
    }
}
pub(crate) fn backend() -> NativeServer<BusServer> {
    NativeServer::new(BusServer::default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notifications::{Backend, Permission};
    use coincide_core::platform_host::notifications::Delivery;
    use std::sync::{Arc, Mutex};
    use uuid::Uuid;
    #[derive(Default)]
    struct Calls {
        replacements: Vec<u32>,
        closed: Vec<u32>,
        bodies: Vec<String>,
    }
    struct Service(Arc<Mutex<Calls>>);
    #[zbus::interface(name = "org.freedesktop.Notifications")]
    impl Service {
        fn get_capabilities(&self) -> Vec<&str> {
            vec!["body", "body-markup"]
        }
        #[allow(clippy::too_many_arguments)]
        fn notify(
            &self,
            app_name: &str,
            replaces_id: u32,
            icon: &str,
            summary: &str,
            body: &str,
            actions: Vec<String>,
            hints: HashMap<String, zbus::zvariant::OwnedValue>,
            timeout: i32,
        ) -> u32 {
            assert_eq!(app_name, "Coincide");
            assert!(icon.is_empty() && actions.is_empty() && hints.is_empty());
            assert_eq!(summary, "Synthetic notice");
            assert_eq!(timeout, -1);
            let mut calls = self.0.lock().unwrap();
            calls.replacements.push(replaces_id);
            calls.bodies.push(body.into());
            if replaces_id == 0 {
                19
            } else {
                assert_eq!(replaces_id, 19);
                replaces_id
            }
        }
        fn close_notification(&self, id: u32) {
            self.0.lock().unwrap().closed.push(id);
        }
    }
    #[::core::prelude::v1::test]
    #[ignore = "fresh Linux CI private dbus-run-session only; never the user session bus"]
    fn actual_private_notification_bus_round_trip() {
        assert_eq!(std::env::var("GITHUB_ACTIONS").as_deref(), Ok("true"));
        assert_eq!(
            std::env::var("COINCIDE_NOTIFICATION_BUS_CI").as_deref(),
            Ok("private-synthetic-server-v1")
        );
        let calls = Arc::new(Mutex::new(Calls::default()));
        let server = Builder::session()
            .unwrap()
            .name("org.freedesktop.Notifications")
            .unwrap()
            .serve_at("/org/freedesktop/Notifications", Service(calls.clone()))
            .unwrap()
            .build()
            .unwrap();
        let mut native = backend();
        assert!(calls.lock().unwrap().replacements.is_empty());
        assert_eq!(native.permission().unwrap(), Permission::Authorized);
        let thread = Uuid::new_v4();
        let payload = Payload {
            id: format!("coincide-rust.{thread}.{}.completed", Uuid::new_v4()),
            thread,
            title: "Synthetic notice".into(),
            body: Some("Literal <text> & data".into()),
        };
        assert_eq!(native.post(&payload), Delivery::Accepted);
        assert_eq!(native.post(&payload), Delivery::Accepted);
        native.clear_thread(thread).unwrap();
        {
            let calls = calls.lock().unwrap();
            assert_eq!(calls.replacements, vec![0, 19]);
            assert_eq!(calls.closed, vec![19]);
            assert_eq!(calls.bodies, vec!["Literal &lt;text&gt; &amp; data"; 2]);
        }
        drop(native);
        drop(server);
        println!(
            "Private notification service accepted exact payload, replacement and owned close; no desktop banner requested"
        );
    }
}
