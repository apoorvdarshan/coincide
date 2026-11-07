//! Owned on-device Apple Speech. Inert until an explicit Voice action. No native
//! API is called from capability/render/status queries on other platforms.

#[derive(Clone, PartialEq, Eq)]
pub(super) struct Configuration {
    pub locale: String,
    pub maximum_seconds: usize,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Error {
    Unavailable,
    #[cfg(all(target_os = "macos", feature = "native-microphone"))]
    Denied,
    Bounds,
    Cancelled,
    CleanupPending,
}
pub(super) fn compiled() -> bool {
    cfg!(all(target_os = "macos", feature = "native-microphone"))
}
/// The engine that actually dictates: Swift's default Apple Speech exists only
/// on macOS, so elsewhere a saved Apple choice uses Local Whisper, which also
/// keeps audio on this device. The saved setting itself is not changed.
pub(super) fn effective_engine(
    engine: coincide_core::voice::Engine,
) -> coincide_core::voice::Engine {
    use coincide_core::voice::Engine;
    if engine == Engine::Apple && !compiled() {
        Engine::Whisper
    } else {
        engine
    }
}
#[cfg(all(target_os = "macos", feature = "native-microphone"))]
mod native {
    use super::*;
    use std::time::{Duration, Instant};
    use std::{ffi::c_void, ptr::NonNull};
    unsafe extern "C" {
        fn cc_voice_speech_create(language: *const u8, length: usize) -> *mut c_void;
        fn cc_voice_speech_prepare(raw: *mut c_void) -> i32;
        fn cc_voice_speech_begin(raw: *mut c_void) -> i32;
        fn cc_voice_speech_append(raw: *mut c_void, samples: *const f32, count: usize) -> i32;
        fn cc_voice_speech_finish(raw: *mut c_void) -> i32;
        fn cc_voice_speech_status(
            raw: *mut c_void,
            phase: *mut i32,
            returned: *mut i32,
            code: *mut i32,
            progress: *mut f64,
        );
        fn cc_voice_speech_revision(raw: *mut c_void) -> u64;
        fn cc_voice_speech_partial(raw: *mut c_void, output: *mut u8, capacity: usize) -> isize;
        fn cc_voice_speech_text(raw: *mut c_void, output: *mut u8, capacity: usize) -> isize;
        fn cc_voice_speech_cancel(raw: *mut c_void);
        fn cc_voice_speech_release(raw: *mut c_void);
    }
    pub(crate) struct Session {
        raw: NonNull<c_void>,
        streamed: usize,
        begun: bool,
        revision: u64,
    }
    impl Session {
        pub fn prepare(
            config: &Configuration,
            cancelled: &(dyn Fn() -> bool + Sync),
        ) -> Result<Self, Error> {
            if !(1..=60).contains(&config.maximum_seconds)
                || config.locale.is_empty()
                || config.locale.len() > 64
                || config.locale.chars().any(char::is_control)
            {
                return Err(Error::Bounds);
            }
            if cancelled() {
                return Err(Error::Cancelled);
            }
            let raw = NonNull::new(unsafe {
                cc_voice_speech_create(config.locale.as_ptr(), config.locale.len())
            })
            .ok_or(Error::Unavailable)?;
            let mut session = Self {
                raw,
                streamed: 0,
                begun: false,
                revision: 0,
            };
            let result = (|| {
                if unsafe { cc_voice_speech_prepare(raw.as_ptr()) } != 1 {
                    return Err(Error::Unavailable);
                }
                session.wait(2, cancelled, Duration::from_secs(180))
            })();
            if let Err(error) = result {
                if error == Error::CleanupPending {
                    return Err(error);
                }
                if session.cancel() == Err(Error::CleanupPending) {
                    return Err(Error::CleanupPending);
                }
                return Err(error);
            }
            Ok(session)
        }
        fn status(&self) -> (i32, bool, i32) {
            let (mut phase, mut returned, mut code, mut progress) = (0, 0, 0, 0.0);
            unsafe {
                cc_voice_speech_status(
                    self.raw.as_ptr(),
                    &mut phase,
                    &mut returned,
                    &mut code,
                    &mut progress,
                )
            };
            (phase, returned == 1, code)
        }
        fn wait(
            &mut self,
            expected: i32,
            cancelled: &(dyn Fn() -> bool + Sync),
            timeout: Duration,
        ) -> Result<(), Error> {
            let deadline = Instant::now() + timeout;
            loop {
                let (phase, returned, code) = self.status();
                if cancelled() || Instant::now() >= deadline {
                    return self.cancel_and_wait();
                }
                if returned {
                    if phase == expected {
                        return Ok(());
                    }
                    if phase >= 7 {
                        return Err(match code {
                            2 => Error::Denied,
                            3 => Error::Bounds,
                            4 => Error::Cancelled,
                            _ => Error::Unavailable,
                        });
                    }
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        fn cancel_and_wait(&mut self) -> Result<(), Error> {
            unsafe { cc_voice_speech_cancel(self.raw.as_ptr()) };
            let deadline = Instant::now() + Duration::from_secs(5);
            while !self.status().1 {
                if Instant::now() >= deadline {
                    return Err(Error::CleanupPending);
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(Error::Cancelled)
        }
        pub fn cancel(&mut self) -> Result<(), Error> {
            match self.cancel_and_wait() {
                Err(Error::Cancelled) => Ok(()),
                result => result,
            }
        }
        fn begin(&mut self, cancelled: &(dyn Fn() -> bool + Sync)) -> Result<(), Error> {
            if cancelled() {
                return self.cancel_and_wait();
            }
            if self.begun {
                return Ok(());
            }
            if unsafe { cc_voice_speech_begin(self.raw.as_ptr()) } != 1 {
                return Err(Error::Unavailable);
            }
            self.wait(4, cancelled, Duration::from_secs(30))?;
            self.begun = true;
            Ok(())
        }
        fn append_pcm(
            &mut self,
            offset: usize,
            samples: &[f32],
            cancelled: &(dyn Fn() -> bool + Sync),
        ) -> Result<(), Error> {
            if offset != self.streamed
                || samples.is_empty()
                || samples.len() > 4096
                || offset.saturating_add(samples.len()) > 16_000 * 60
                || samples.iter().any(|s| !s.is_finite() || s.abs() > 1.0)
            {
                return Err(Error::Bounds);
            }
            self.begin(cancelled)?;
            if unsafe { cc_voice_speech_append(self.raw.as_ptr(), samples.as_ptr(), samples.len()) }
                != 1
            {
                return Err(Error::Unavailable);
            }
            self.streamed += samples.len();
            Ok(())
        }
        pub fn stream(
            &mut self,
            offset: usize,
            samples: &[f32],
            cancelled: &(dyn Fn() -> bool + Sync),
        ) -> Result<(), Error> {
            if samples.len() > 4096 || samples.iter().any(|s| !s.is_finite()) {
                return Err(Error::Bounds);
            }
            // Match the canonical final-WAV codec exactly so its unread tail
            // and this prefix do not use different quantization.
            let pcm = samples
                .iter()
                .map(|s| ((s.clamp(-1.0, 1.0) * i16::MAX as f32) as i16) as f32 / 32768.0)
                .collect::<Vec<_>>();
            self.append_pcm(offset, &pcm, cancelled)
        }
        pub fn partial(&mut self) -> Option<String> {
            if !self.begun {
                return None;
            }
            let revision = unsafe { cc_voice_speech_revision(self.raw.as_ptr()) };
            if revision == self.revision {
                return None;
            }
            let length =
                unsafe { cc_voice_speech_partial(self.raw.as_ptr(), std::ptr::null_mut(), 0) };
            if !(0..=1_048_576).contains(&length) {
                return None;
            }
            // Bounded slack permits a small concurrent native update. Larger
            // growth is retried on the next owned tick without publishing it.
            let mut bytes = vec![0; (length as usize).saturating_add(1024).min(1_048_576)];
            let count = unsafe {
                cc_voice_speech_partial(self.raw.as_ptr(), bytes.as_mut_ptr(), bytes.len())
            };
            if count < 0 || count as usize > bytes.len() {
                return None;
            }
            bytes.truncate(count as usize);
            let text = String::from_utf8(bytes).ok()?;
            self.revision = revision;
            Some(text)
        }
        pub fn transcribe(
            &mut self,
            wav: &[u8],
            cancelled: &(dyn Fn() -> bool + Sync),
        ) -> Result<String, Error> {
            let samples = pcm_samples(wav)?;
            if self.streamed > samples.len() {
                return Err(Error::Bounds);
            }
            self.begin(cancelled)?;
            let tail = &samples[self.streamed..];
            for chunk in tail.chunks(4096) {
                self.append_pcm(self.streamed, chunk, cancelled)?;
            }
            if unsafe { cc_voice_speech_finish(self.raw.as_ptr()) } != 1 {
                return Err(Error::Unavailable);
            }
            self.wait(6, cancelled, Duration::from_secs(120))?;
            let length =
                unsafe { cc_voice_speech_text(self.raw.as_ptr(), std::ptr::null_mut(), 0) };
            if !(0..=1_048_576).contains(&length) {
                return Err(Error::Bounds);
            }
            let mut output = vec![0; length as usize];
            if unsafe { cc_voice_speech_text(self.raw.as_ptr(), output.as_mut_ptr(), output.len()) }
                != length
            {
                return Err(Error::Unavailable);
            }
            if cancelled() {
                return self.cancel_and_wait().map(|_| String::new());
            }
            String::from_utf8(output).map_err(|_| Error::Bounds)
        }
    }
    impl Drop for Session {
        fn drop(&mut self) {
            unsafe { cc_voice_speech_release(self.raw.as_ptr()) };
        }
    }
}
#[cfg(all(target_os = "macos", feature = "native-microphone"))]
pub(super) use native::Session;
#[cfg(not(all(target_os = "macos", feature = "native-microphone")))]
pub(super) struct Session;
#[cfg(not(all(target_os = "macos", feature = "native-microphone")))]
impl Session {
    pub fn stream(
        &mut self,
        _: usize,
        _: &[f32],
        _: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), Error> {
        Err(Error::Unavailable)
    }
    pub fn partial(&mut self) -> Option<String> {
        None
    }

    pub fn cancel(&mut self) -> Result<(), Error> {
        Ok(())
    }
    pub fn prepare(
        config: &Configuration,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<Self, Error> {
        if cancelled() {
            return Err(Error::Cancelled);
        }
        if config.locale.is_empty()
            || config.locale.len() > 64
            || !(1..=60).contains(&config.maximum_seconds)
        {
            return Err(Error::Bounds);
        }
        Err(Error::Unavailable)
    }
    pub fn transcribe(&mut self, _: &[u8], _: &(dyn Fn() -> bool + Sync)) -> Result<String, Error> {
        Err(Error::Unavailable)
    }
}
// The capture adapter's closed WAV codec is validated again at the FFI boundary.
#[cfg(any(test, all(target_os = "macos", feature = "native-microphone")))]
fn pcm_samples(wav: &[u8]) -> Result<Vec<f32>, Error> {
    // Native capture writes the canonical 44-byte PCM header. Refuse other
    // layouts rather than interpreting arbitrary WAV chunks as sample data.
    if wav.len() <= 44
        || !wav.len().is_multiple_of(2)
        || u32::from_le_bytes(wav[4..8].try_into().unwrap()) as usize != wav.len() - 8
        || &wav[..4] != b"RIFF"
        || &wav[8..12] != b"WAVE"
        || &wav[12..16] != b"fmt "
        || &wav[36..40] != b"data"
        || u32::from_le_bytes(wav[16..20].try_into().unwrap()) != 16
        || u16::from_le_bytes(wav[20..22].try_into().unwrap()) != 1
        || u16::from_le_bytes(wav[22..24].try_into().unwrap()) != 1
        || u32::from_le_bytes(wav[24..28].try_into().unwrap()) != 16_000
        || u16::from_le_bytes(wav[34..36].try_into().unwrap()) != 16
        || u16::from_le_bytes(wav[32..34].try_into().unwrap()) != 2
        || u32::from_le_bytes(wav[28..32].try_into().unwrap()) != 32_000
        || wav.len() != 44 + u32::from_le_bytes(wav[40..44].try_into().unwrap()) as usize
        || wav.len() > 44 + 16_000 * 60 * 2
    {
        return Err(Error::Bounds);
    }
    Ok(wav[44..]
        .chunks_exact(2)
        .map(|sample| i16::from_le_bytes([sample[0], sample[1]]) as f32 / 32768.0)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::pcm_samples;
    #[test]
    fn saved_apple_speech_dictates_with_local_whisper_where_apple_is_missing() {
        use coincide_core::voice::Engine;
        let apple = super::effective_engine(Engine::Apple);
        if super::compiled() {
            assert_eq!(apple, Engine::Apple);
        } else {
            assert_eq!(apple, Engine::Whisper);
        }
        for engine in [Engine::Whisper, Engine::OpenAi, Engine::Groq] {
            assert_eq!(super::effective_engine(engine), engine);
        }
    }
    #[test]
    fn ffi_audio_codec_accepts_only_bounded_canonical_native_pcm() {
        let wav =
            coincide_core::dictation::transcription::encode_wav(&[0.0, 0.5, -0.5], 16_000).unwrap();
        assert_eq!(
            pcm_samples(&wav).unwrap(),
            vec![0.0, 16383.0 / 32768.0, -16383.0 / 32768.0]
        );
        for index in [0, 8, 12, 16, 20, 22, 24, 28, 32, 34, 36, 40] {
            let mut changed = wav.clone();
            changed[index] ^= 1;
            assert!(
                pcm_samples(&changed).is_err(),
                "changed canonical field must be rejected"
            );
        }
        let mut odd = wav;
        odd.push(0);
        assert!(pcm_samples(&odd).is_err());
        assert!(pcm_samples(b"not audio").is_err());
    }
}
