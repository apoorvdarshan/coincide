//! Bounded streaming downmix/resampling for native capture. No device access,
//! persistence or inference. The callback allocates nothing after construction.
use super::CaptureError;

const RATE: u64 = 16_000;
const HALF: i64 = 16;
const RING: usize = 64;

pub(super) struct Samples {
    channels: usize,
    rate: u64,
    ring: [f32; RING],
    frames: u64,
    next: u64,
    maximum: usize,
    output: Vec<f32>,
    limited: bool,
}

impl Samples {
    pub(super) fn new(rate: u32, channels: u16, maximum: usize) -> Result<Self, CaptureError> {
        if !(8_000..=192_000).contains(&rate)
            || !(1..=8).contains(&channels)
            || maximum == 0
            || maximum > super::SAMPLE_RATE * super::MAX_SECONDS
        {
            return Err(CaptureError::InvalidLimit);
        }
        Ok(Self {
            channels: channels as usize,
            rate: rate as u64,
            ring: [0.0; RING],
            frames: 0,
            next: 0,
            maximum,
            output: Vec::with_capacity(maximum),
            limited: false,
        })
    }

    pub(super) fn push<T: Copy>(
        &mut self,
        input: &[T],
        convert: impl Fn(T) -> f32,
    ) -> Result<bool, CaptureError> {
        if !input.len().is_multiple_of(self.channels) {
            return Err(CaptureError::Conversion);
        }
        for frame in input.chunks_exact(self.channels) {
            let mut mono = 0.0;
            for sample in frame {
                let sample = convert(*sample);
                if !sample.is_finite() {
                    return Err(CaptureError::Conversion);
                }
                mono += sample.clamp(-1.0, 1.0) / self.channels as f32;
            }
            self.frame(mono);
            self.emit(None);
            if self.output.len() == self.maximum {
                self.limited = true;
                break;
            }
        }
        Ok(self.limited)
    }

    fn frame(&mut self, sample: f32) {
        self.ring[self.frames as usize % RING] = sample;
        self.frames += 1;
    }

    fn emit(&mut self, end: Option<u64>) {
        while self.output.len() < self.maximum {
            let center = (self.next / RATE) as i64;
            if center + HALF >= self.frames as i64 || end.is_some_and(|end| self.next >= end * RATE)
            {
                break;
            }
            let position = self.next as f64 / RATE as f64;
            // A windowed sinc low-pass avoids aliasing when downsampling the
            // device's common 44.1/48/96 kHz input to 16 kHz mono.
            let cutoff = (RATE as f64 / self.rate as f64).min(1.0) * 0.90;
            let mut value = 0.0;
            let mut weight = 0.0;
            for index in (center - HALF + 1)..=(center + HALF) {
                let distance = index as f64 - position;
                let phase = std::f64::consts::PI * distance * cutoff;
                let sinc = if phase.abs() < 1e-12 {
                    1.0
                } else {
                    phase.sin() / phase
                };
                let window = 0.42
                    + 0.5 * (std::f64::consts::PI * distance / HALF as f64).cos()
                    + 0.08 * (2.0 * std::f64::consts::PI * distance / HALF as f64).cos();
                let coefficient = sinc * cutoff * window;
                weight += coefficient;
                if index >= 0 && index < self.frames as i64 {
                    value += self.ring[index as usize % RING] as f64 * coefficient;
                }
            }
            self.output.push((value / weight).clamp(-1.0, 1.0) as f32);
            self.next += self.rate;
        }
    }

    pub(super) fn finish(mut self) -> (Vec<f32>, bool) {
        let end = self.frames;
        if !self.limited {
            for _ in 0..=HALF {
                self.frame(0.0);
                self.emit(Some(end));
            }
        }
        (std::mem::take(&mut self.output), self.limited)
    }
}

impl Drop for Samples {
    fn drop(&mut self) {
        self.ring.fill(0.0);
        self.output.fill(0.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn convert(rate: u32, chunks: usize, frequency: f32) -> Vec<f32> {
        let input: Vec<f32> = (0..rate)
            .flat_map(|frame| {
                let value = (frame as f32 * frequency * std::f32::consts::TAU / rate as f32).sin();
                [value, value]
            })
            .collect();
        let mut samples = Samples::new(rate, 2, 32_000).unwrap();
        for block in input.chunks(chunks * 2) {
            assert!(!samples.push(block, |sample| sample).unwrap());
        }
        let (output, limited) = samples.finish();
        assert!(!limited);
        assert_eq!(output.len(), 16_000);
        output
    }

    #[::core::prelude::v1::test]
    fn native_pcm_resampling_preserves_duration_channels_and_chunk_boundaries() {
        for rate in [8_000, 16_000, 44_100, 48_000, 96_000, 192_000] {
            let whole = convert(rate, rate as usize, 1_000.0);
            assert_eq!(whole, convert(rate, 127, 1_000.0));
            let rms = (whole[64..15_936]
                .iter()
                .map(|value| value * value)
                .sum::<f32>()
                / 15_872.0)
                .sqrt();
            assert!((0.65..0.76).contains(&rms), "rate={rate} rms={rms}");
        }
        let output = convert(48_000, 311, 12_000.0);
        let rms = (output[64..15_936]
            .iter()
            .map(|value| value * value)
            .sum::<f32>()
            / 15_872.0)
            .sqrt();
        assert!(rms < 0.05, "out-of-band input must be attenuated: {rms}");
    }

    #[::core::prelude::v1::test]
    fn capture_limit_invalid_audio_and_silent_cancellation_are_bounded() {
        let mut samples = Samples::new(48_000, 2, 16).unwrap();
        assert!(samples.push(&[0.5; 256], |sample| sample).unwrap());
        let (output, limited) = samples.finish();
        assert_eq!(output.len(), 16);
        assert!(limited);
        let mut samples = Samples::new(48_000, 2, 100).unwrap();
        assert_eq!(
            samples.push(&[0.0], |sample| sample),
            Err(CaptureError::Conversion)
        );
        assert_eq!(
            samples.push(&[f32::NAN; 2], |sample| sample),
            Err(CaptureError::Conversion)
        );
        assert!(Samples::new(0, 2, 100).is_err());
        assert!(Samples::new(48_000, 0, 100).is_err());
        assert!(Samples::new(48_000, 2, usize::MAX).is_err());
        let samples = Samples::new(48_000, 2, 100).unwrap();
        assert!(samples.finish().0.is_empty());
    }
}
