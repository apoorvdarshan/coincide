//! Windows WASAPI / Linux ALSA capture. Only explicit Record opens a device.
//! CPAL 0.18.2's two stream implementations terminate and join their owned
//! callback thread in Drop; we drop on this owner before reading sample storage.
use super::{
    BackendEvent, BackendProgress, CaptureBackend, CaptureError, InputDevice, Permission,
    samples::Samples,
};
use cpal::{
    ErrorKind, SampleFormat,
    traits::{DeviceTrait, HostTrait, StreamTrait},
};
use std::{
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU8, AtomicU32, AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

#[derive(Default)]
pub(super) struct Native {
    armed: bool,
    permission_pending: bool,
    capture: Option<Capture>,
    finished: Option<BackendEvent>,
}
struct Capture {
    stream: cpal::Stream,
    shared: Arc<Buffer>,
    deadline: Instant,
}
struct Buffer {
    samples: Mutex<Option<Samples>>,
    accepting: AtomicBool,
    limited: AtomicBool,
    fault: AtomicU8,
    samples_written: AtomicUsize,
    level: AtomicU32,
}
fn error(error: cpal::Error) -> CaptureError {
    match error.kind() {
        ErrorKind::PermissionDenied => CaptureError::PermissionRequired,
        ErrorKind::DeviceNotAvailable => CaptureError::NoInput,
        ErrorKind::DeviceChanged | ErrorKind::StreamInvalidated => CaptureError::DeviceChanged,
        ErrorKind::DeviceBusy => CaptureError::Busy,
        _ => CaptureError::Unavailable,
    }
}
impl Native {
    fn finish(&mut self, cancelled: bool, deadline: bool) {
        let Some(Capture { stream, shared, .. }) = self.capture.take() else {
            return;
        };
        shared.accepting.store(false, Ordering::Release);
        // Neither callback captures this Native/controller/Engine. Stream Drop
        // joins from this distinct owner thread, including error/limit paths.
        drop(stream);
        let samples = shared
            .samples
            .lock()
            .ok()
            .and_then(|mut samples| samples.take());
        self.finished = if cancelled {
            drop(samples);
            None
        } else if shared.fault.load(Ordering::Acquire) != 0 {
            drop(samples);
            Some(BackendEvent::Failed(CaptureError::DeviceChanged))
        } else {
            Some(match samples {
                Some(samples) => {
                    let (samples, limited) = samples.finish();
                    BackendEvent::Ready(samples, limited || deadline)
                }
                None => BackendEvent::Failed(CaptureError::Conversion),
            })
        };
    }
}
fn stream<T: cpal::SizedSample + Copy + 'static>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    shared: Arc<Buffer>,
    convert: fn(T) -> f32,
) -> Result<cpal::Stream, CaptureError> {
    let failure = shared.clone();
    device
        .build_input_stream(
            config,
            move |data: &[T], _| {
                if !shared.accepting.load(Ordering::Acquire) {
                    return;
                }
                // No blocking UI/worker lock, allocation or IPC on the audio callback.
                let Ok(mut samples) = shared.samples.try_lock() else {
                    shared.fault.store(1, Ordering::Release);
                    shared.accepting.store(false, Ordering::Release);
                    return;
                };
                match samples.as_mut().map(|samples| samples.push(data, convert)) {
                    Some(Ok(true)) => {
                        shared.limited.store(true, Ordering::Release);
                        shared.accepting.store(false, Ordering::Release);
                    }
                    Some(Ok(false)) => {}
                    _ => {
                        shared.fault.store(1, Ordering::Release);
                        shared.accepting.store(false, Ordering::Release);
                    }
                }
                if let Some(samples) = samples.as_ref() {
                    let (written, level) = samples.progress();
                    shared.samples_written.store(written, Ordering::Release);
                    shared.level.store(level.to_bits(), Ordering::Release);
                }
            },
            move |_| {
                // Native diagnostic strings can contain personal device information.
                failure.fault.store(1, Ordering::Release);
                failure.accepting.store(false, Ordering::Release);
            },
            Some(Duration::from_secs(2)),
        )
        .map_err(error)
}
impl CaptureBackend for Native {
    fn available(&self) -> bool {
        true
    }
    fn progress(&self) -> Option<BackendProgress> {
        let capture = self.capture.as_ref()?;
        Some(BackendProgress {
            samples: capture.shared.samples_written.load(Ordering::Acquire),
            level: f32::from_bits(capture.shared.level.load(Ordering::Acquire)),
        })
    }
    fn permission(&self) -> Permission {
        // WASAPI/ALSA report actual access failure when opening the stream.
        // Ready means explicitly armed, never an OS authorization attestation.
        if self.armed {
            Permission::Ready
        } else {
            Permission::NotDetermined
        }
    }
    fn request_permission(&mut self) -> Result<(), CaptureError> {
        if self.capture.is_some() || self.permission_pending {
            return Err(CaptureError::Busy);
        }
        self.armed = true;
        self.permission_pending = true;
        Ok(())
    }
    fn poll_permission(&mut self) -> Option<Permission> {
        std::mem::take(&mut self.permission_pending).then_some(self.permission())
    }
    fn discard_permission(&mut self) {
        self.permission_pending = false;
    }
    fn start(&mut self, maximum_samples: usize) -> Result<(), CaptureError> {
        self.start_on_device(maximum_samples, None)
    }
    fn input_devices(&mut self) -> Result<Vec<InputDevice>, CaptureError> {
        if self.capture.is_some() {
            return Err(CaptureError::Busy);
        }
        let host = cpal::default_host();
        let default = host
            .default_input_device()
            .and_then(|device| device.id().ok());
        let mut devices = Vec::new();
        for device in host.input_devices().map_err(error)?.take(129) {
            let id = device.id().map_err(error)?;
            let name = device.description().map_err(error)?.name().to_owned();
            devices.push(InputDevice {
                uid: id.to_string(),
                name,
                is_default: default.as_ref() == Some(&id),
            });
        }
        super::validate_devices(&devices)?;
        Ok(devices)
    }
    fn start_on_device(
        &mut self,
        maximum_samples: usize,
        uid: Option<&str>,
    ) -> Result<(), CaptureError> {
        if self.capture.is_some() {
            return Err(CaptureError::Busy);
        }
        if !self.armed {
            return Err(CaptureError::PermissionRequired);
        }
        self.finished = None;
        let host = cpal::default_host();
        let device = match uid {
            None => host.default_input_device().ok_or(CaptureError::NoInput)?,
            Some(uid) => {
                let id: cpal::DeviceId = uid.parse().map_err(|_| CaptureError::NoInput)?;
                let device = host.device_by_id(&id).ok_or(CaptureError::NoInput)?;
                if device.id().map_err(error)? != id {
                    return Err(CaptureError::NoInput);
                }
                device
            }
        };
        let config = device.default_input_config().map_err(error)?;
        let samples = Samples::new(config.sample_rate(), config.channels(), maximum_samples)?;
        let shared = Arc::new(Buffer {
            samples: Mutex::new(Some(samples)),
            accepting: AtomicBool::new(true),
            limited: AtomicBool::new(false),
            fault: AtomicU8::new(0),
            samples_written: AtomicUsize::new(0),
            level: AtomicU32::new(0.0_f32.to_bits()),
        });
        let input = config.config();
        let stream = match config.sample_format() {
            SampleFormat::F32 => stream(&device, input, shared.clone(), |sample: f32| sample),
            SampleFormat::F64 => {
                stream(&device, input, shared.clone(), |sample: f64| sample as f32)
            }
            SampleFormat::I8 => stream(&device, input, shared.clone(), |sample: i8| {
                sample as f32 / 128.0
            }),
            SampleFormat::I16 => stream(&device, input, shared.clone(), |sample: i16| {
                sample as f32 / 32768.0
            }),
            SampleFormat::I32 => stream(&device, input, shared.clone(), |sample: i32| {
                sample as f32 / 2147483648.0
            }),
            SampleFormat::U8 => stream(&device, input, shared.clone(), |sample: u8| {
                (sample as f32 - 128.0) / 128.0
            }),
            SampleFormat::U16 => stream(&device, input, shared.clone(), |sample: u16| {
                (sample as f32 - 32768.0) / 32768.0
            }),
            _ => Err(CaptureError::Conversion),
        }?;
        stream.play().map_err(error)?;
        self.capture = Some(Capture {
            stream,
            shared,
            deadline: Instant::now()
                + Duration::from_secs_f64(maximum_samples as f64 / super::SAMPLE_RATE as f64),
        });
        Ok(())
    }
    fn stop(&mut self) {
        self.finish(false, false);
    }
    fn cancel(&mut self) {
        self.finish(true, false);
        self.finished = None;
    }
    fn poll(&mut self) -> Option<BackendEvent> {
        if let Some(capture) = &self.capture {
            let deadline = Instant::now() >= capture.deadline;
            if deadline
                || capture.shared.limited.load(Ordering::Acquire)
                || capture.shared.fault.load(Ordering::Acquire) != 0
            {
                self.finish(false, deadline);
            }
        }
        self.finished.take()
    }
}
impl Drop for Native {
    fn drop(&mut self) {
        self.cancel();
    }
}
