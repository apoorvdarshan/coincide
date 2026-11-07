//! Composer integration independent of capture/transcription backends.
//! Byte offsets are used by Rust callers; never pass Cocoa UTF-16 ranges here.
use std::ops::Range;
#[derive(Debug, PartialEq, Eq)]
pub enum DictationError {
    InvalidSelection,
    ComposerChanged,
    Unavailable,
    EmptyTranscript,
}
#[derive(Debug, Clone, Copy)]
pub enum Engine {
    AppleSpeech,
    LocalWhisper,
    OpenAi,
    Groq,
}
pub fn capture_capability(_engine: Engine) -> Result<(), DictationError> {
    // No Rust microphone permission/capture or native speech bridge yet.
    Err(DictationError::Unavailable)
}
/// Trusted backend receives audio, returns text, and must not log recordings or
/// persist keys in settings. No provider is advertised ready without a backend.
pub trait Transcriber {
    fn transcribe(&mut self, wav: &[u8]) -> Result<String, DictationError>;
}
pub struct DictationSession {
    expected: String,
    range: Range<usize>,
    before: Option<char>,
    after: Option<char>,
}
impl DictationSession {
    pub fn start(text: &str, range: Range<usize>) -> Result<Self, DictationError> {
        if range.start > range.end
            || !text.is_char_boundary(range.start)
            || !text.is_char_boundary(range.end)
        {
            return Err(DictationError::InvalidSelection);
        }
        Ok(Self {
            expected: text.into(),
            before: text[..range.start].chars().next_back(),
            after: text[range.end..].chars().next(),
            range,
        })
    }
    /// Each partial replaces the preceding partial. Concurrent composer edits
    /// cancel insertion rather than overwriting the user's new text.
    pub fn update(
        &mut self,
        composer: &mut String,
        transcript: &str,
    ) -> Result<usize, DictationError> {
        if *composer != self.expected {
            return Err(DictationError::ComposerChanged);
        }
        let trimmed = transcript.trim();
        if trimmed.is_empty() {
            return Ok(self.range.end);
        }
        let mut replacement = String::new();
        if self.before.is_some_and(|c| !c.is_whitespace()) {
            replacement.push(' ');
        }
        replacement.push_str(trimmed);
        if self
            .after
            .is_some_and(|c| !c.is_whitespace() && !".,;:!?)]}”’'\"…".contains(c))
        {
            replacement.push(' ');
        }
        composer.replace_range(self.range.clone(), &replacement);
        self.range.end = self.range.start + replacement.len();
        self.expected.clone_from(composer);
        Ok(self.range.end)
    }
    pub fn finish(
        &mut self,
        composer: &mut String,
        wav: &[u8],
        backend: &mut impl Transcriber,
    ) -> Result<usize, DictationError> {
        if *composer != self.expected {
            return Err(DictationError::ComposerChanged);
        }
        let transcript = backend.transcribe(wav)?;
        if transcript.trim().is_empty() {
            return Err(DictationError::EmptyTranscript);
        }
        self.update(composer, &transcript)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unicode_partial_replacement_and_stale_edit() {
        let mut text = "hello🌍!".to_owned();
        let mut session = DictationSession::start(&text, 5..9).unwrap();
        session.update(&mut text, "world").unwrap();
        assert_eq!(text, "hello world!");
        session.update(&mut text, "earth").unwrap();
        assert_eq!(text, "hello earth!");
        text.push('?');
        assert_eq!(
            session.update(&mut text, "lost"),
            Err(DictationError::ComposerChanged)
        );
        assert!(DictationSession::start("🌍", 1..2).is_err());
    }
    #[test]
    fn backend_failure_preserves_selection() {
        struct Offline;
        impl Transcriber for Offline {
            fn transcribe(&mut self, _: &[u8]) -> Result<String, DictationError> {
                Err(DictationError::Unavailable)
            }
        }
        let mut text = "keep me".to_owned();
        let mut session = DictationSession::start(&text, 0..7).unwrap();
        assert_eq!(
            session.finish(&mut text, b"synthetic", &mut Offline),
            Err(DictationError::Unavailable)
        );
        assert_eq!(text, "keep me");
        assert_eq!(
            capture_capability(Engine::AppleSpeech),
            Err(DictationError::Unavailable)
        );
    }
}

pub mod transcription;

pub mod local;

pub mod voice_api;

pub mod voice_secret;
