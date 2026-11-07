//! Private in-memory transcription codec. Transport is injected; this module
//! does not claim microphone capture or an installed/network-ready provider.
use super::{DictationError, Transcriber};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    OpenAi,
    Groq,
}
impl Provider {
    fn endpoint(self) -> &'static str {
        match self {
            Self::OpenAi => "https://api.openai.com/v1/audio/transcriptions",
            Self::Groq => "https://api.groq.com/openai/v1/audio/transcriptions",
        }
    }
}
#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    MissingKey,
    Cancelled,
    InvalidConfiguration,
    InvalidAudio,
    TooLarge,
    Unauthorized,
    Forbidden,
    RateLimited,
    Rejected,
    Server,
    Network,
    InvalidResponse,
}
const MAX_AUDIO: usize = 25_000_000;
const MAX_RESPONSE: usize = 1_048_576;
/// No Debug/Serialize. Header and body may contain secrets/personal speech.
pub struct Request {
    method: &'static str,
    endpoint: &'static str,
    authorization: String,
    content_type: String,
    body: Vec<u8>,
}
impl Request {
    pub fn method(&self) -> &'static str {
        self.method
    }
    pub fn endpoint(&self) -> &str {
        self.endpoint
    }
    /// Trusted HTTP transport only: send as Authorization header, never URL.
    pub fn authorization(&self) -> &str {
        &self.authorization
    }
    pub fn content_type(&self) -> &str {
        &self.content_type
    }
    pub fn body(&self) -> &[u8] {
        &self.body
    }
}
impl Drop for Request {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.authorization.zeroize();
        self.body.zeroize();
    }
}
/// Authenticated metadata probe, only after a native Test Key action. No audio.
pub fn models_request(provider: Provider, key: &str) -> Result<Request, Error> {
    if key.is_empty() {
        return Err(Error::MissingKey);
    }
    if key.len() > 4096 || !key.bytes().all(|b| b.is_ascii_graphic()) {
        return Err(Error::InvalidConfiguration);
    }
    Ok(Request {
        method: "GET",
        endpoint: match provider {
            Provider::OpenAi => "https://api.openai.com/v1/models",
            Provider::Groq => "https://api.groq.com/openai/v1/models",
        },
        authorization: format!("Bearer {key}"),
        content_type: "application/json".into(),
        body: Vec::new(),
    })
}
pub fn models_response(response: Response) -> Result<(), Error> {
    if response.body.len() > MAX_RESPONSE {
        return Err(Error::TooLarge);
    }
    match response.status {
        200..=299 => {}
        401 => return Err(Error::Unauthorized),
        403 => return Err(Error::Forbidden),
        429 => return Err(Error::RateLimited),
        400..=499 => return Err(Error::Rejected),
        500..=599 => return Err(Error::Server),
        _ => return Err(Error::InvalidResponse),
    }
    let value: serde_json::Value =
        serde_json::from_slice(&response.body).map_err(|_| Error::InvalidResponse)?;
    if !value["data"].is_array() {
        return Err(Error::InvalidResponse);
    }
    Ok(())
}
/// Response bodies are untrusted and may echo credentials; never log them.
pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}
impl Drop for Response {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.body.zeroize();
    }
}
/// Implementations must use TLS, forbid redirects, set a bounded timeout and
/// cap response bytes while receiving (not only after allocating the body).
/// Errors must be classified, never include provider bodies/headers/keys.
pub trait Transport {
    fn send(&mut self, request: &Request) -> Result<Response, Error>;
    fn send_cancellable(
        &mut self,
        request: &Request,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<Response, Error> {
        if cancelled() {
            return Err(Error::Cancelled);
        }
        let response = self.send(request)?;
        if cancelled() {
            Err(Error::Cancelled)
        } else {
            Ok(response)
        }
    }
}

/// Provider settings contain no key. Keys are supplied privately from an OS
/// store to the worker at construction; this type is not a settings document.
pub struct ApiTranscriber<T> {
    provider: Provider,
    key: zeroize::Zeroizing<String>,
    model: String,
    language: Option<String>,
    transport: T,
}
impl<T: Transport> ApiTranscriber<T> {
    pub fn new(
        provider: Provider,
        key: String,
        model: String,
        language: Option<String>,
        transport: T,
    ) -> Self {
        Self {
            provider,
            key: zeroize::Zeroizing::new(key),
            model,
            language,
            transport,
        }
    }
    pub fn transcribe_private(&mut self, wav: &[u8]) -> Result<String, Error> {
        self.transcribe_cancellable(wav, &|| false)
    }
    pub fn transcribe_cancellable(
        &mut self,
        wav: &[u8],
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<String, Error> {
        let request = request(
            self.provider,
            &self.key,
            &self.model,
            self.language.as_deref(),
            wav,
        )?;
        transcript(self.transport.send_cancellable(&request, cancelled)?)
    }
}
impl<T: Transport> Transcriber for ApiTranscriber<T> {
    fn transcribe(&mut self, wav: &[u8]) -> Result<String, DictationError> {
        self.transcribe_private(wav)
            .map_err(|_| DictationError::Unavailable)
    }
}
pub fn request(
    provider: Provider,
    key: &str,
    model: &str,
    language: Option<&str>,
    wav: &[u8],
) -> Result<Request, Error> {
    if key.trim().is_empty() {
        return Err(Error::MissingKey);
    }
    if key.len() > 4096 || !key.bytes().all(|b| b.is_ascii_graphic()) {
        return Err(Error::InvalidConfiguration);
    }
    if model.is_empty()
        || model.len() > 128
        || !model
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b))
    {
        return Err(Error::InvalidConfiguration);
    }
    if language.is_some_and(|s| {
        s.is_empty() || s.len() > 32 || !s.bytes().all(|b| b.is_ascii_alphabetic() || b == b'-')
    }) {
        return Err(Error::InvalidConfiguration);
    }
    validate_wav(wav)?;
    // Random boundaries are also checked against the audio; uploaded content
    // cannot escape its multipart part by providing its own boundary marker.
    let boundary = loop {
        let candidate = format!("coincide-{}", uuid::Uuid::new_v4());
        if !wav
            .windows(candidate.len())
            .any(|b| b == candidate.as_bytes())
        {
            break candidate;
        }
    };
    let mut body = Vec::with_capacity(wav.len() + 1024);
    let mut field = |name: &str, value: &str| {
        body.extend_from_slice(
            format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n"
            )
            .as_bytes(),
        )
    };
    field("model", model);
    field("response_format", "json");
    if let Some(language) = language {
        field(
            if matches!(provider, Provider::OpenAi) && model == "gpt-transcribe" {
                "languages[]"
            } else {
                "language"
            },
            language,
        );
    }
    body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\nContent-Type: audio/wav\r\n\r\n").as_bytes());
    body.extend_from_slice(wav);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    Ok(Request {
        method: "POST",
        endpoint: provider.endpoint(),
        authorization: format!("Bearer {key}"),
        content_type: format!("multipart/form-data; boundary={boundary}"),
        body,
    })
}
pub fn transcript(response: Response) -> Result<String, Error> {
    if response.body.len() > MAX_RESPONSE {
        return Err(Error::TooLarge);
    }
    match response.status {
        200..=299 => {}
        401 => return Err(Error::Unauthorized),
        403 => return Err(Error::Forbidden),
        413 => return Err(Error::TooLarge),
        429 => return Err(Error::RateLimited),
        400..=499 => return Err(Error::Rejected),
        500..=599 => return Err(Error::Server),
        _ => return Err(Error::InvalidResponse),
    }
    let json: serde_json::Value =
        serde_json::from_slice(&response.body).map_err(|_| Error::InvalidResponse)?;
    Ok(json["text"]
        .as_str()
        .ok_or(Error::InvalidResponse)?
        .trim()
        .into())
}
/// Narrow format we produce: canonical 44-byte-header mono 16-bit PCM WAV.
/// Refuses arbitrary containers/chunk extensions rather than guessing audio.
fn validate_wav(wav: &[u8]) -> Result<(), Error> {
    if wav.len() > MAX_AUDIO {
        return Err(Error::TooLarge);
    }
    if wav.len() < 46
        || &wav[..4] != b"RIFF"
        || &wav[8..16] != b"WAVEfmt "
        || &wav[36..40] != b"data"
    {
        return Err(Error::InvalidAudio);
    }
    let u32_at = |offset| u32::from_le_bytes(wav[offset..offset + 4].try_into().unwrap());
    let u16_at = |offset| u16::from_le_bytes(wav[offset..offset + 2].try_into().unwrap());
    let rate = u32_at(24);
    if u32_at(4) as usize != wav.len() - 8
        || u32_at(16) != 16
        || u16_at(20) != 1
        || u16_at(22) != 1
        || !(8_000..=192_000).contains(&rate)
        || u32_at(28) != rate * 2
        || u16_at(32) != 2
        || u16_at(34) != 16
        || u32_at(40) as usize != wav.len() - 44
        || !(wav.len() - 44).is_multiple_of(2)
    {
        return Err(Error::InvalidAudio);
    }
    Ok(())
}
/// Encode finite mono float samples without touching disk.
pub fn encode_wav(samples: &[f32], rate: u32) -> Result<Vec<u8>, Error> {
    if samples.is_empty()
        || samples.iter().any(|s| !s.is_finite())
        || !(8_000..=192_000).contains(&rate)
    {
        return Err(Error::InvalidAudio);
    }
    if samples.len() > (MAX_AUDIO - 44) / 2 {
        return Err(Error::TooLarge);
    }
    let size = (samples.len() * 2) as u32;
    let mut wav = Vec::with_capacity(size as usize + 44);
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(size + 36).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16_u32.to_le_bytes());
    wav.extend_from_slice(&1_u16.to_le_bytes());
    wav.extend_from_slice(&1_u16.to_le_bytes());
    wav.extend_from_slice(&rate.to_le_bytes());
    wav.extend_from_slice(&(rate * 2).to_le_bytes());
    wav.extend_from_slice(&2_u16.to_le_bytes());
    wav.extend_from_slice(&16_u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&size.to_le_bytes());
    for sample in samples {
        wav.extend_from_slice(&((sample.clamp(-1.0, 1.0) * i16::MAX as f32) as i16).to_le_bytes());
    }
    Ok(wav)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn synthetic_request_has_private_header_and_exact_audio() {
        let wav = encode_wav(&[0.0, -1.0, 1.0, 2.0], 16000).unwrap();
        let request = request(
            Provider::OpenAi,
            "synthetic-key",
            "gpt-transcribe",
            Some("en"),
            &wav,
        )
        .unwrap();
        assert!(!request.endpoint().contains("synthetic"));
        assert_eq!(request.authorization(), "Bearer synthetic-key");
        assert!(!request.body().windows(13).any(|w| w == b"synthetic-key"));
        assert!(request.body().windows(wav.len()).any(|w| w == wav));
        assert!(request.body().windows(11).any(|w| w == b"languages[]"));
        assert_eq!(&wav[44..], &[0, 0, 1, 128, 255, 127, 255, 127]);
    }
    #[test]
    fn invalid_audio_headers_and_configuration_fail_closed() {
        let mut wav = encode_wav(&[0.0], 16000).unwrap();
        wav[40] = 7;
        assert!(matches!(
            request(Provider::Groq, "synthetic", "whisper", None, &wav),
            Err(Error::InvalidAudio)
        ));
        assert!(encode_wav(&[f32::NAN], 16000).is_err());
        assert!(encode_wav(&[0.0], 0).is_err());
        let wav = encode_wav(&[0.0], 16000).unwrap();
        assert!(matches!(
            request(Provider::Groq, "bad\r\nheader", "whisper", None, &wav),
            Err(Error::InvalidConfiguration)
        ));
    }
    #[test]
    fn provider_error_bodies_are_never_exposed() {
        for (status, expected) in [
            (401, Error::Unauthorized),
            (403, Error::Forbidden),
            (429, Error::RateLimited),
            (500, Error::Server),
        ] {
            assert_eq!(
                transcript(Response {
                    status,
                    body: b"echoed synthetic credential".to_vec()
                }),
                Err(expected)
            );
        }
        assert_eq!(
            transcript(Response {
                status: 200,
                body: br#"{"text":"  hello fixture  "}"#.to_vec()
            }),
            Ok("hello fixture".into())
        );
    }
    #[test]
    fn injected_transport_integrates_with_composer() {
        struct Fixture;
        impl Transport for Fixture {
            fn send(&mut self, request: &Request) -> Result<Response, Error> {
                assert_eq!(request.endpoint(), Provider::Groq.endpoint());
                Ok(Response {
                    status: 200,
                    body: br#"{"text":"world"}"#.to_vec(),
                })
            }
        }
        let mut backend = ApiTranscriber::new(
            Provider::Groq,
            "synthetic".into(),
            "whisper-large-v3".into(),
            None,
            Fixture,
        );
        let mut composer = "Hello!".to_owned();
        let mut session = super::super::DictationSession::start(&composer, 5..5).unwrap();
        session
            .finish(
                &mut composer,
                &encode_wav(&[0.0], 16000).unwrap(),
                &mut backend,
            )
            .unwrap();
        assert_eq!(composer, "Hello world!");
    }
}
