//! Advertises the server as `_coincide._tcp` with the TXT record the phone's
//! Bonjour browser reads (`id` = server id, `v` = protocol version), as the
//! Mac's `NWListener.Service` does. macOS registers with the system's
//! mDNSResponder and Linux with Avahi over D-Bus; elsewhere the pairing code's
//! addresses are how phones find the computer.
use super::protocol::{SERVICE_TYPE, VERSION};

/// Keeps the advertisement up until dropped.
pub struct Advertisement {
    #[cfg(target_os = "macos")]
    service: macos::Service,
    #[cfg(target_os = "linux")]
    _group: linux::Group,
}

/// The TXT record: length-prefixed `key=value` strings.
pub fn txt_record(server_id: &str) -> Vec<Vec<u8>> {
    vec![
        format!("id={server_id}").into_bytes(),
        format!("v={VERSION}").into_bytes(),
    ]
}

/// Bonjour instance names are at most 63 bytes of UTF-8.
pub fn service_name(name: &str) -> String {
    let mut result = String::new();
    for character in name.chars() {
        if result.len() + character.len_utf8() > 63 {
            break;
        }
        result.push(character);
    }
    if result.is_empty() {
        "Coincide".into()
    } else {
        result
    }
}

/// Starts advertising; an error means phones on this network won't see it in
/// their list, though saved addresses and pairing codes still work.
pub fn advertise(name: &str, server_id: &str, port: u16) -> anyhow::Result<Advertisement> {
    let name = service_name(name);
    let txt = txt_record(server_id);
    #[cfg(target_os = "macos")]
    {
        Ok(Advertisement {
            service: macos::Service::register(&name, port, &txt)?,
        })
    }
    #[cfg(target_os = "linux")]
    {
        Ok(Advertisement {
            _group: linux::Group::register(&name, port, txt)?,
        })
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = (name, txt, port);
        anyhow::bail!("Bonjour advertising isn’t available on this system")
    }
}

impl Drop for Advertisement {
    fn drop(&mut self) {
        #[cfg(target_os = "macos")]
        self.service.deallocate();
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use std::ffi::{CString, c_char, c_void};

    #[repr(C)]
    struct ServiceRef {
        _private: [u8; 0],
    }
    // dns_sd.h, in libSystem.
    unsafe extern "C" {
        fn DNSServiceRegister(
            service: *mut *mut ServiceRef,
            flags: u32,
            interface: u32,
            name: *const c_char,
            kind: *const c_char,
            domain: *const c_char,
            host: *const c_char,
            port: u16,
            txt_length: u16,
            txt: *const c_void,
            callback: *const c_void,
            context: *mut c_void,
        ) -> i32;
        fn DNSServiceRefDeallocate(service: *mut ServiceRef);
    }

    pub struct Service(*mut ServiceRef);
    // SAFETY: the reference is only deallocated, once, by its owner.
    unsafe impl Send for Service {}

    impl Service {
        pub fn register(name: &str, port: u16, txt: &[Vec<u8>]) -> anyhow::Result<Self> {
            let mut record = Vec::new();
            for entry in txt {
                record.push(u8::try_from(entry.len())?);
                record.extend_from_slice(entry);
            }
            let name = CString::new(name)?;
            let kind = CString::new(super::SERVICE_TYPE)?;
            let mut service = std::ptr::null_mut();
            // SAFETY: all pointers outlive the call; a null callback is allowed
            // and means no asynchronous replies are delivered. The port is in
            // network byte order, as dns_sd expects.
            let error = unsafe {
                DNSServiceRegister(
                    &mut service,
                    0,
                    0,
                    name.as_ptr(),
                    kind.as_ptr(),
                    std::ptr::null(),
                    std::ptr::null(),
                    port.to_be(),
                    u16::try_from(record.len())?,
                    record.as_ptr().cast(),
                    std::ptr::null(),
                    std::ptr::null_mut(),
                )
            };
            anyhow::ensure!(
                error == 0 && !service.is_null(),
                "Bonjour registration failed ({error})"
            );
            Ok(Self(service))
        }

        pub fn deallocate(&mut self) {
            if !self.0.is_null() {
                // SAFETY: registered above and deallocated once.
                unsafe { DNSServiceRefDeallocate(self.0) };
                self.0 = std::ptr::null_mut();
            }
        }
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use zbus::{
        blocking::{Connection, Proxy},
        zvariant::OwnedObjectPath,
    };

    /// An Avahi entry group; Avahi removes it with this connection.
    pub struct Group {
        group: Proxy<'static>,
        _connection: Connection,
    }

    impl Group {
        pub fn register(name: &str, port: u16, txt: Vec<Vec<u8>>) -> anyhow::Result<Self> {
            let connection = Connection::system()?;
            let server = Proxy::new(
                &connection,
                "org.freedesktop.Avahi",
                "/",
                "org.freedesktop.Avahi.Server",
            )?;
            let path: OwnedObjectPath = server.call("EntryGroupNew", &())?;
            let group = Proxy::new(
                &connection,
                "org.freedesktop.Avahi",
                path,
                "org.freedesktop.Avahi.EntryGroup",
            )?;
            // Any interface and protocol (-1), no flags, default domain and host.
            group.call::<_, _, ()>(
                "AddService",
                &(
                    -1i32,
                    -1i32,
                    0u32,
                    name,
                    super::SERVICE_TYPE,
                    "",
                    "",
                    port,
                    txt,
                ),
            )?;
            group.call::<_, _, ()>("Commit", &())?;
            Ok(Self {
                group,
                _connection: connection,
            })
        }
    }

    impl Drop for Group {
        fn drop(&mut self) {
            let _ = self.group.call::<_, _, ()>("Free", &());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn names_and_txt_records_match_the_phone_browser() {
        assert_eq!(txt_record("S-1"), vec![b"id=S-1".to_vec(), b"v=1".to_vec()]);
        assert_eq!(service_name(""), "Coincide");
        let long = "é".repeat(40);
        let name = service_name(&long);
        assert!(name.len() <= 63 && long.starts_with(&name));
    }
}
