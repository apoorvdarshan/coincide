//! Authenticated loopback-only OpenCode HTTP, isolated from proxy/cookie state.
use super::*;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use std::sync::{Arc, Mutex, mpsc::SyncSender};

const MAX_BODY: usize = 8 * 1024 * 1024;
#[derive(Clone)]
pub(super) struct Http {
    pub base: url::Url,
    authorization: String,
    agent: ureq::Agent,
}
impl Http {
    pub fn new(base: url::Url, password: &str) -> Self {
        let config = ureq::Agent::config_builder()
            .proxy(None)
            .max_redirects(0)
            .http_status_as_error(false)
            .timeout_connect(Some(Duration::from_secs(2)))
            .timeout_send_request(Some(Duration::from_secs(5)))
            .timeout_send_body(Some(Duration::from_secs(10)))
            .timeout_recv_response(Some(Duration::from_secs(10)))
            .build();
        Self {
            base,
            authorization: format!("Basic {}", STANDARD.encode(format!("opencode:{password}"))),
            agent: config.new_agent(),
        }
    }
    pub fn request(
        &self,
        method: &str,
        path: &str,
        body: Option<Value>,
        timeout: Duration,
    ) -> Result<Value> {
        self.request_at(method, path, body, timeout, None)
    }
    pub(super) fn catalog(
        &self,
        path: &'static str,
        directory: &str,
        timeout: Duration,
    ) -> Result<Value> {
        ensure!(
            matches!(
                path,
                "/api/model" | "/api/provider" | "/api/integration" | "/api/command" | "/api/skill"
            ),
            "Invalid OpenCode metadata path"
        );
        self.request_at("GET", path, None, timeout, Some(directory))
    }
    fn request_at(
        &self,
        method: &str,
        path: &str,
        body: Option<Value>,
        timeout: Duration,
        directory: Option<&str>,
    ) -> Result<Value> {
        let mut url = self.base.clone();
        // Paths originate in this adapter; persisted IDs are encoded as segments.
        ensure!(path.starts_with("/api/"), "Invalid OpenCode API path");
        url.set_path(path);
        if let Some(directory) = directory {
            url.query_pairs_mut()
                .append_pair("location[directory]", directory);
        }
        let request = ureq::http::Request::builder()
            .method(method)
            .uri(url.as_str())
            .header("Authorization", &self.authorization)
            .header("Accept", "application/json")
            .header("Content-Type", "application/json")
            .body(body.map(|value| value.to_string()).unwrap_or_default())?;
        let request = self
            .agent
            .configure_request(request)
            .timeout_global(Some(timeout))
            .build();
        let mut response = self
            .agent
            .run(request)
            .map_err(|_| anyhow::anyhow!("OpenCode HTTP request failed or timed out"))?;
        let status = response.status().as_u16();
        let mut bytes = Vec::new();
        response
            .body_mut()
            .as_reader()
            .take((MAX_BODY + 1) as u64)
            .read_to_end(&mut bytes)?;
        ensure!(bytes.len() <= MAX_BODY, "OpenCode response exceeded 8 MiB");
        ensure!(
            (200..300).contains(&status),
            "OpenCode rejected {method} {path} (HTTP {status})"
        );
        if bytes.is_empty() {
            Ok(Value::Null)
        } else {
            serde_json::from_slice(&bytes).context("OpenCode returned invalid JSON")
        }
    }
    pub fn stream(&self, sender: SyncSender<Result<Value>>, heartbeat: Arc<Mutex<Instant>>) {
        let result = (|| -> Result<()> {
            let mut url = self.base.clone();
            url.set_path("/api/event");
            let mut response = self
                .agent
                .get(url.as_str())
                .header("Authorization", &self.authorization)
                .header("Accept", "text/event-stream")
                .call()
                .map_err(|_| anyhow::anyhow!("OpenCode event stream could not connect"))?;
            ensure!(
                response.status().as_u16() == 200,
                "OpenCode refused its event stream"
            );
            ensure!(
                response
                    .headers()
                    .get("Content-Type")
                    .and_then(|v| v.to_str().ok())
                    .is_some_and(|v| v.starts_with("text/event-stream")),
                "OpenCode returned an unexpected stream content type"
            );
            let mut reader = response.body_mut().as_reader();
            let mut parser = Sse::default();
            let mut bytes = [0; 8192];
            loop {
                let count = reader.read(&mut bytes)?;
                ensure!(
                    count > 0,
                    "OpenCode event stream disconnected; this turn may be incomplete"
                );
                *heartbeat
                    .lock()
                    .map_err(|_| anyhow::anyhow!("Stream clock unavailable"))? = Instant::now();
                for value in parser.feed(&bytes[..count])? {
                    if sender.send(Ok(value)).is_err() {
                        return Ok(());
                    }
                }
            }
        })();
        if let Err(error) = result {
            let _ = sender.send(Err(error));
        }
    }
}

pub(super) fn segment(value: &str) -> String {
    url::form_urlencoded::byte_serialize(value.as_bytes())
        .collect::<String>()
        .replace('+', "%20")
}
pub(super) fn listening_url(line: &str) -> Option<url::Url> {
    let offset = line.to_ascii_lowercase().find("server listening on ")?;
    let raw = line[offset + 20..].split_whitespace().next()?;
    let url = url::Url::parse(raw).ok()?;
    (url.scheme() == "http"
        && url.host_str() == Some("127.0.0.1")
        && url.port().is_some_and(|p| p > 0)
        && url.username().is_empty()
        && url.password().is_none()
        && url.path() == "/"
        && url.query().is_none()
        && url.fragment().is_none())
    .then_some(url)
}

#[derive(Default)]
pub(super) struct Sse {
    buffer: Vec<u8>,
    data: String,
}
impl Sse {
    pub fn feed(&mut self, bytes: &[u8]) -> Result<Vec<Value>> {
        ensure!(
            self.buffer.len() + self.data.len() + bytes.len() <= MAX_BODY,
            "OpenCode stream frame exceeded 8 MiB"
        );
        self.buffer.extend_from_slice(bytes);
        let mut result = Vec::new();
        let mut consumed = 0;
        while let Some(length) = self.buffer[consumed..].iter().position(|b| *b == b'\n') {
            let end = consumed + length;
            let line = std::str::from_utf8(&self.buffer[consumed..end])?.trim_end_matches('\r');
            if line.is_empty() {
                if !self.data.is_empty() {
                    result.push(
                        serde_json::from_str(&self.data).context("OpenCode event was not JSON")?,
                    );
                    self.data.clear();
                }
            } else if let Some(value) = line.strip_prefix("data:") {
                if !self.data.is_empty() {
                    self.data.push('\n');
                }
                self.data.push_str(value.strip_prefix(' ').unwrap_or(value));
            }
            consumed = end + 1;
        }
        self.buffer.drain(..consumed);
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn metadata_uses_the_workspace_query_and_header_authentication() {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let worker = std::thread::spawn(move || {
            let (mut connection, _) = listener.accept().unwrap();
            connection
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut request = Vec::new();
            let mut bytes = [0; 512];
            while !request.windows(4).any(|part| part == b"\r\n\r\n") {
                let count = connection.read(&mut bytes).unwrap();
                assert!(count > 0);
                request.extend_from_slice(&bytes[..count]);
            }
            connection.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}").unwrap();
            String::from_utf8(request).unwrap()
        });
        let http = Http::new(
            url::Url::parse(&format!("http://{addr}/")).unwrap(),
            "synthetic-password",
        );
        http.catalog("/api/skill", "/project with space", Duration::from_secs(3))
            .unwrap();
        let request = worker.join().unwrap();
        let first = request.lines().next().unwrap();
        assert!(first.starts_with("GET /api/skill?location%5Bdirectory%5D=%2Fproject+with+space "));
        assert!(!first.contains("synthetic-password"));
        assert!(
            request
                .to_ascii_lowercase()
                .contains("authorization: basic ")
        );
    }
    #[test]
    fn untrusted_listening_line_cannot_redirect_credentials() {
        assert!(listening_url("server listening on http://127.0.0.1:1234").is_some());
        for url in [
            "http://evil.test:1234",
            "http://127.0.0.1:1234@evil.test",
            "http://127.0.0.1:1234/path",
            "http://localhost:1234",
            "https://127.0.0.1:1234",
            "http://127.0.0.1:1234?secret=bad",
        ] {
            assert!(listening_url(&format!("server listening on {url}")).is_none());
        }
    }
    #[test]
    fn sse_accepts_fragmented_utf8_comments_crlf_and_multiline_data() {
        let bytes = ": keepalive\r\ndata: {\"text\":\r\ndata: \"héllo\"}\r\n\r\n".as_bytes();
        let mut parser = Sse::default();
        let mut frames = Vec::new();
        for byte in bytes {
            frames.extend(parser.feed(&[*byte]).unwrap());
        }
        assert_eq!(frames, vec![json!({"text":"héllo"})]);
        assert!(parser.feed(b"data: nope\n\n").is_err());
    }
    #[test]
    fn oversized_unterminated_event_is_rejected() {
        let mut parser = Sse::default();
        assert!(parser.feed(&vec![b'x'; MAX_BODY + 1]).is_err());
        assert_eq!(segment("a/b?#"), "a%2Fb%3F%23");
    }
}
