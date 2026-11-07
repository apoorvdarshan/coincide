//! Fixed official Voice endpoints, separate from agent/provider accounts.
//! No calls occur on construction. Invoke only on the owned native worker.
//! Contract: https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create
//! https://console.groq.com/docs/api-reference#audio-create-transcription
use super::transcription::{Error, Request, Response, Transport};
use std::{io::Read, sync::mpsc, time::Duration};
const LIMIT: usize = 1_048_576;
const DEADLINE: Duration = Duration::from_secs(120);

/// Interrupt active TLS/socket I/O through this request's private ureq Agent.
/// DNS/connect retain their explicit bounded timeouts. The monitor is scoped
/// and actually joins before any result, cancellation or panic leaves here.
fn owned_cancellation<T>(
    cancelled: &(dyn Fn() -> bool + Sync),
    shutdown: impl FnOnce() + Send,
    work: impl FnOnce() -> Result<T, Error>,
) -> Result<T, Error> {
    if cancelled() {
        return Err(Error::Cancelled);
    }
    std::thread::scope(|scope| {
        let (finished, wait) = mpsc::sync_channel::<()>(1);
        let monitor = scope.spawn(move || {
            loop {
                if cancelled() {
                    shutdown();
                    return;
                }
                match wait.recv_timeout(Duration::from_millis(10)) {
                    Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => return,
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                }
            }
        });
        let result = work();
        drop(finished);
        monitor.join().map_err(|_| Error::Network)?;
        if cancelled() {
            Err(Error::Cancelled)
        } else {
            result
        }
    })
}
fn bounded_body(mut input: impl Read, cancelled: &dyn Fn() -> bool) -> Result<Vec<u8>, Error> {
    let mut bytes = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        if cancelled() {
            return Err(Error::Cancelled);
        }
        let n = input.read(&mut chunk).map_err(|_| Error::Network)?;
        if n == 0 {
            break;
        }
        if bytes.len() + n > LIMIT {
            return Err(Error::TooLarge);
        }
        bytes.extend_from_slice(&chunk[..n]);
    }
    if cancelled() {
        Err(Error::Cancelled)
    } else {
        Ok(bytes)
    }
}
/// Created only from a credential minted by an explicit native secret-store
/// operation. Preferences/JSON cannot construct Credential or this authority.
#[derive(Clone)]
pub struct HostedConfig {
    credential: std::sync::Arc<super::voice_secret::Credential>,
    pub model: String,
    pub language: Option<String>,
    pub maximum_seconds: usize,
}
impl PartialEq for HostedConfig {
    fn eq(&self, other: &Self) -> bool {
        self.credential.id() == other.credential.id()
            && self.model == other.model
            && self.language == other.language
            && self.maximum_seconds == other.maximum_seconds
    }
}
impl Eq for HostedConfig {}
impl HostedConfig {
    pub fn new(
        credential: std::sync::Arc<super::voice_secret::Credential>,
        model: String,
        language: Option<String>,
    ) -> Self {
        Self {
            credential,
            model,
            language,
            maximum_seconds: 60,
        }
    }
    pub fn transcribe(
        &self,
        wav: &[u8],
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<String, Error> {
        self.transcribe_with_transport(wav, cancelled, HttpsTransport)
    }
    pub fn transcribe_with_transport<T: Transport>(
        &self,
        wav: &[u8],
        cancelled: &(dyn Fn() -> bool + Sync),
        transport: T,
    ) -> Result<String, Error> {
        let mut client = super::transcription::ApiTranscriber::new(
            self.credential.provider(),
            self.credential.key().to_owned(),
            self.model.clone(),
            self.language.clone(),
            transport,
        );
        client.transcribe_cancellable(wav, cancelled)
    }
}
pub fn test_key(
    credential: &super::voice_secret::Credential,
    cancelled: &(dyn Fn() -> bool + Sync),
) -> Result<(), Error> {
    test_key_with_transport(credential, cancelled, HttpsTransport)
}
pub fn test_key_with_transport<T: Transport>(
    credential: &super::voice_secret::Credential,
    cancelled: &(dyn Fn() -> bool + Sync),
    mut transport: T,
) -> Result<(), Error> {
    let request = super::transcription::models_request(credential.provider(), credential.key())?;
    super::transcription::models_response(transport.send_cancellable(&request, cancelled)?)
}
/// Stateless construction: no DNS, TLS, vault access, permission or discovery.
pub struct HttpsTransport;
impl Transport for HttpsTransport {
    fn send(&mut self, request: &Request) -> Result<Response, Error> {
        self.send_cancellable(request, &|| false)
    }
    fn send_cancellable(
        &mut self,
        request: &Request,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<Response, Error> {
        let config = ureq::Agent::config_builder()
            .https_only(true)
            .proxy(None)
            .max_redirects(0)
            .http_status_as_error(false)
            .timeout_global(Some(DEADLINE))
            .timeout_connect(Some(Duration::from_secs(10)))
            .timeout_resolve(Some(Duration::from_secs(10)))
            .timeout_send_request(Some(Duration::from_secs(10)))
            .timeout_send_body(Some(Duration::from_secs(30)))
            .timeout_recv_response(Some(DEADLINE))
            .timeout_recv_body(Some(Duration::from_secs(30)))
            .build();
        let agent = config.new_agent();
        let shutdown = agent.clone();
        owned_cancellation(
            cancelled,
            move || shutdown.shutdown(),
            || {
                // Request endpoints/methods are closed codec values, never a JSON
                // base URL; credentials occur only in this Authorization header.
                let mut authorization = ureq::http::HeaderValue::from_str(request.authorization())
                    .map_err(|_| Error::InvalidConfiguration)?;
                authorization.set_sensitive(true);
                let request = ureq::http::Request::builder()
                    .method(request.method())
                    .uri(request.endpoint())
                    .header("Authorization", authorization)
                    .header("Content-Type", request.content_type())
                    .header("Accept", "application/json")
                    .header("Accept-Encoding", "identity")
                    .body(request.body())
                    .map_err(|_| Error::InvalidConfiguration)?;
                let mut response = agent.run(request).map_err(|_| Error::Network)?;
                if response
                    .body()
                    .content_length()
                    .is_some_and(|length| length > LIMIT as u64)
                {
                    return Err(Error::TooLarge);
                }
                let status = response.status().as_u16();
                let body = bounded_body(response.body_mut().as_reader(), cancelled)?;
                Ok(Response { status, body })
            },
        )
    }
}
#[cfg(test)]
mod tests {
    use super::{Error, LIMIT, bounded_body, owned_cancellation};
    use std::{
        io::{self, Read},
        sync::{
            Arc,
            atomic::{AtomicBool, AtomicUsize, Ordering},
            mpsc,
        },
        time::Duration,
    };
    #[test]
    fn cancellation_closes_owned_io_and_monitor_actually_returns() {
        let cancelled = Arc::new(AtomicBool::new(false));
        let stopped = Arc::new(AtomicUsize::new(0));
        let (release, wait) = mpsc::channel();
        let flag = cancelled.clone();
        let count = stopped.clone();
        let result = owned_cancellation(
            &|| cancelled.load(Ordering::Acquire),
            move || {
                count.fetch_add(1, Ordering::AcqRel);
                release.send(()).unwrap();
            },
            || {
                flag.store(true, Ordering::Release);
                wait.recv_timeout(Duration::from_secs(5)).unwrap();
                Ok("must be discarded")
            },
        );
        assert_eq!(result, Err(Error::Cancelled));
        assert_eq!(stopped.load(Ordering::Acquire), 1);
        assert_eq!(
            owned_cancellation(&|| true, || panic!("no active socket"), || Ok(1)),
            Err(Error::Cancelled)
        );
    }
    struct Endless {
        read: usize,
    }
    impl Read for Endless {
        fn read(&mut self, b: &mut [u8]) -> io::Result<usize> {
            self.read += b.len();
            b.fill(b'x');
            Ok(b.len())
        }
    }
    #[test]
    fn receive_cap_is_enforced_during_read_and_cancel_rejects_body() {
        assert_eq!(
            bounded_body(Endless { read: 0 }, &|| false),
            Err(Error::TooLarge)
        );
        assert_eq!(
            bounded_body(&b"private response"[..], &|| true),
            Err(Error::Cancelled)
        );
        assert_eq!(
            bounded_body(&vec![b'x'; LIMIT][..], &|| false)
                .unwrap()
                .len(),
            LIMIT
        );
    }
}

#[cfg(test)]
mod private_session_tests {
    use super::{HostedConfig, test_key_with_transport};
    use crate::dictation::{
        transcription::{Error, Provider, Request, Response, Transport, encode_wav},
        voice_secret::{Backend, Failure, VoiceSecrets},
    };
    use std::sync::{Arc, Mutex};
    use zeroize::Zeroizing;
    struct FakeStore(Mutex<String>);
    impl Backend for FakeStore {
        fn read(&self, _: Provider) -> Result<Zeroizing<String>, Failure> {
            Ok(Zeroizing::new(self.0.lock().unwrap().clone()))
        }
        fn write(&self, _: Provider, key: &str) -> Result<(), Failure> {
            *self.0.lock().unwrap() = key.into();
            Ok(())
        }
        fn delete(&self, _: Provider) -> Result<(), Failure> {
            self.0.lock().unwrap().clear();
            Ok(())
        }
    }
    struct FakeHttp {
        key: &'static str,
        method: &'static str,
        calls: Arc<Mutex<usize>>,
        status: u16,
    }
    impl Transport for FakeHttp {
        fn send(&mut self, request: &Request) -> Result<Response, Error> {
            *self.calls.lock().unwrap() += 1;
            assert_eq!(request.method(), self.method);
            assert_eq!(request.authorization(), format!("Bearer {}", self.key));
            assert!(!request.endpoint().contains('?'));
            let body = if self.method == "GET" {
                assert_eq!(request.endpoint(), "https://api.openai.com/v1/models");
                assert!(request.body().is_empty());
                br#"{"data":[{"id":"gpt-transcribe"}]}"#.to_vec()
            } else {
                assert_eq!(
                    request.endpoint(),
                    "https://api.openai.com/v1/audio/transcriptions"
                );
                let body = String::from_utf8_lossy(request.body());
                assert!(body.contains("languages[]"));
                assert!(body.contains("gpt-transcribe"));
                assert!(body.contains("Content-Type: audio/wav"));
                br#"{"text":"synthetic hosted transcript"}"#.to_vec()
            };
            Ok(Response {
                status: self.status,
                body,
            })
        }
    }
    #[test]
    fn hosted_snapshot_keeps_exact_private_voice_key_model_and_language_without_real_access() {
        let store = VoiceSecrets::with_backend(Arc::new(FakeStore(Mutex::new(
            "synthetic-old-voice-key".into(),
        ))));
        let old = store.load(Provider::OpenAi).unwrap();
        let snapshot = HostedConfig::new(old.clone(), "gpt-transcribe".into(), Some("en".into()));
        let replacement = store
            .save(
                Provider::OpenAi,
                Zeroizing::new("synthetic-new-voice-key".into()),
            )
            .unwrap();
        let new = HostedConfig::new(replacement, "gpt-transcribe".into(), Some("en".into()));
        assert!(snapshot != new);
        let calls = Arc::new(Mutex::new(0));
        let wav = encode_wav(&[0.0, 0.5], 16_000).unwrap();
        let text = snapshot
            .transcribe_with_transport(
                &wav,
                &|| false,
                FakeHttp {
                    key: "synthetic-old-voice-key",
                    method: "POST",
                    calls: calls.clone(),
                    status: 200,
                },
            )
            .unwrap();
        assert_eq!(text, "synthetic hosted transcript");
        assert_eq!(*calls.lock().unwrap(), 1);
        assert_eq!(
            snapshot.transcribe_with_transport(
                &wav,
                &|| true,
                FakeHttp {
                    key: "synthetic-old-voice-key",
                    method: "POST",
                    calls: calls.clone(),
                    status: 200
                }
            ),
            Err(Error::Cancelled)
        );
        assert_eq!(*calls.lock().unwrap(), 1);
        test_key_with_transport(
            &old,
            &|| false,
            FakeHttp {
                key: "synthetic-old-voice-key",
                method: "GET",
                calls: calls.clone(),
                status: 200,
            },
        )
        .unwrap();
        assert_eq!(
            test_key_with_transport(
                &old,
                &|| false,
                FakeHttp {
                    key: "synthetic-old-voice-key",
                    method: "GET",
                    calls: calls.clone(),
                    status: 401
                }
            ),
            Err(Error::Unauthorized)
        );
        assert_eq!(*calls.lock().unwrap(), 3);
    }
}
