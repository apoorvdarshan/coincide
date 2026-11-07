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
        fn cc_voice_speech_text(raw: *mut c_void, output: *mut u8, capacity: usize) -> isize;
        fn cc_voice_speech_cancel(raw: *mut c_void);
        fn cc_voice_speech_release(raw: *mut c_void);
    }
    pub(crate) struct Session {
        raw: NonNull<c_void>,
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
            let mut session = Self { raw };
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
        pub fn transcribe(
            &mut self,
            wav: &[u8],
            cancelled: &(dyn Fn() -> bool + Sync),
        ) -> Result<String, Error> {
            let samples = pcm_samples(wav)?;
            if cancelled() {
                return self.cancel_and_wait().map(|_| String::new());
            }
            if unsafe { cc_voice_speech_begin(self.raw.as_ptr()) } != 1 {
                return Err(Error::Unavailable);
            }
            self.wait(4, cancelled, Duration::from_secs(30))?;
            for chunk in samples.chunks(4096) {
                if cancelled() {
                    return self.cancel_and_wait().map(|_| String::new());
                }
                if unsafe { cc_voice_speech_append(self.raw.as_ptr(), chunk.as_ptr(), chunk.len()) }
                    != 1
                {
                    return Err(Error::Unavailable);
                }
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
