use super::{Downloader, Error, Result, Spec};
use std::{
    io::{Read, Write},
    sync::mpsc,
    time::Duration,
};
use ureq::unversioned::{
    resolver::{DefaultResolver, ResolvedSocketAddrs, Resolver},
    transport::{DefaultConnector, NextTimeout},
};
#[derive(Debug, Default)]
struct ModelResolver(DefaultResolver);
fn allowed(uri: &ureq::http::Uri) -> bool {
    uri.scheme_str() == Some("https")
        && uri.authority().is_some_and(|authority| {
            !authority.as_str().contains('@') && authority.port_u16().is_none_or(|port| port == 443)
        })
        && matches!(
            uri.host(),
            Some(
                "huggingface.co"
                    | "cdn-lfs.huggingface.co"
                    | "cdn-lfs-us-1.hf.co"
                    | "cdn-lfs-eu-1.hf.co"
                    | "cas-bridge.xethub.hf.co"
                    | "us.aws.cdn.hf.co"
                    | "cdn-lfs.hf.co"
            )
        )
}
impl Resolver for ModelResolver {
    fn resolve(
        &self,
        uri: &ureq::http::Uri,
        config: &ureq::config::Config,
        timeout: NextTimeout,
    ) -> std::result::Result<ResolvedSocketAddrs, ureq::Error> {
        if !allowed(uri) {
            return Err(ureq::Error::Io(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "Model download host rejected",
            )));
        }
        self.0.resolve(uri, config, timeout)
    }
}
/// Inert until an explicit native Download. No credential/cookie/proxy state is
/// inherited. Redirect DNS is restricted to the official asset host family.
pub struct HttpsDownloader;
impl Downloader for HttpsDownloader {
    fn fetch(
        &self,
        spec: &Spec,
        output: &mut dyn Write,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<()> {
        if cancelled() {
            return Err(Error::Cancelled);
        }
        let config = ureq::Agent::config_builder()
            .https_only(true)
            .proxy(None)
            .max_redirects(5)
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(1800)))
            .timeout_resolve(Some(Duration::from_secs(10)))
            .timeout_connect(Some(Duration::from_secs(10)))
            .timeout_recv_response(Some(Duration::from_secs(30)))
            .timeout_recv_body(Some(Duration::from_secs(60)))
            .build();
        let agent = ureq::Agent::with_parts(
            config,
            DefaultConnector::default(),
            ModelResolver::default(),
        );
        let shutdown = agent.clone();
        std::thread::scope(|scope| {
            let (finished, wait) = mpsc::sync_channel::<()>(1);
            let monitor = scope.spawn(move || {
                loop {
                    if cancelled() {
                        shutdown.shutdown();
                        return;
                    }
                    match wait.recv_timeout(Duration::from_millis(10)) {
                        Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => return,
                        Err(mpsc::RecvTimeoutError::Timeout) => {}
                    }
                }
            });
            let result = (|| {
                let mut response = agent
                    .get(spec.url())
                    .header("Accept-Encoding", "identity")
                    .call()
                    .map_err(|_| Error::Network)?;
                if response.status().as_u16() != 200 {
                    return Err(Error::Rejected);
                }
                if response
                    .body()
                    .content_length()
                    .is_some_and(|length| length != spec.bytes)
                {
                    return Err(Error::SizeMismatch);
                }
                let mut reader = response.body_mut().as_reader();
                let mut buffer = [0u8; 65536];
                loop {
                    if cancelled() {
                        return Err(Error::Cancelled);
                    }
                    let count = reader.read(&mut buffer).map_err(|_| Error::Network)?;
                    if count == 0 {
                        break;
                    }
                    output.write_all(&buffer[..count]).map_err(|_| {
                        if cancelled() {
                            Error::Cancelled
                        } else {
                            Error::Storage
                        }
                    })?;
                }
                output.flush().map_err(|_| Error::Storage)
            })();
            drop(finished);
            monitor.join().map_err(|_| Error::Network)?;
            if cancelled() {
                Err(Error::Cancelled)
            } else {
                result
            }
        })
    }
}
#[cfg(test)]
mod tests {
    use super::allowed;
    #[test]
    fn redirect_policy_is_https_official_assets_only_without_userinfo_or_private_hosts() {
        for value in [
            "https://huggingface.co/ggerganov/whisper.cpp/file",
            "https://cas-bridge.xethub.hf.co/public-file?temporary=public-fixture",
        ] {
            assert!(allowed(&value.parse().unwrap()));
        }
        for value in [
            "http://huggingface.co/file",
            "https://127.0.0.1/file",
            "https://huggingface.co.evil.invalid/file",
            "https://user@huggingface.co/file",
            "https://huggingface.co:444/file",
        ] {
            assert!(!allowed(&value.parse().unwrap()));
        }
    }
}
