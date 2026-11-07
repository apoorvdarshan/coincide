//! Real bounded COM IStream for CapturePreview. Never a disk/HGLOBAL stream.
use super::super::super::shutdown::NativeLease;
use super::super::windows_plan::Buffer;
use std::{
    ffi::c_void,
    sync::{Arc, Mutex},
};
use windows::{
    Win32::{
        Foundation::{
            E_NOTIMPL, E_POINTER, S_FALSE, S_OK, STG_E_INVALIDFUNCTION, STG_E_MEDIUMFULL,
        },
        System::Com::*,
    },
    core::{HRESULT, Ref, implement},
};
#[implement(IStream, ISequentialStream)]
struct Stream {
    buffer: Arc<Mutex<Buffer>>,
    _native: NativeLease,
}
pub(super) fn stream(buffer: Arc<Mutex<Buffer>>, native: NativeLease) -> IStream {
    Stream {
        buffer,
        _native: native,
    }
    .into()
}
impl ISequentialStream_Impl for Stream_Impl {
    fn Read(&self, pv: *mut c_void, cb: u32, read: *mut u32) -> HRESULT {
        if !read.is_null() {
            unsafe {
                *read = 0;
            }
        }
        if cb != 0 && pv.is_null() {
            return E_POINTER;
        }
        if cb as usize > coincide_core::browser_screenshot::MAX_PNG_BYTES {
            return STG_E_INVALIDFUNCTION;
        }
        let out = if cb == 0 {
            &mut []
        } else {
            unsafe { std::slice::from_raw_parts_mut(pv.cast::<u8>(), cb as usize) }
        };
        let Some(count) = self
            .buffer
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .read(out)
        else {
            return STG_E_INVALIDFUNCTION;
        };
        if !read.is_null() {
            unsafe {
                *read = count as u32;
            }
        }
        if count == cb as usize { S_OK } else { S_FALSE }
    }
    fn Write(&self, pv: *const c_void, cb: u32, written: *mut u32) -> HRESULT {
        if !written.is_null() {
            unsafe {
                *written = 0;
            }
        }
        if cb != 0 && pv.is_null() {
            return E_POINTER;
        }
        // Reject excess length BEFORE constructing a slice from a native write
        // pointer. The backing buffer never grows beyond the fixed PNG budget.
        if cb as usize > coincide_core::browser_screenshot::MAX_PNG_BYTES {
            return STG_E_MEDIUMFULL;
        }
        let bytes = if cb == 0 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(pv.cast::<u8>(), cb as usize) }
        };
        if !self
            .buffer
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .write(bytes)
        {
            return STG_E_MEDIUMFULL;
        }
        if !written.is_null() {
            unsafe {
                *written = cb;
            }
        }
        S_OK
    }
}
impl IStream_Impl for Stream_Impl {
    fn Seek(
        &self,
        offset: i64,
        origin: STREAM_SEEK,
        position: *mut u64,
    ) -> windows::core::Result<()> {
        let mut buffer = self.buffer.lock().unwrap_or_else(|e| e.into_inner());
        if !buffer.seek(offset, origin.0) {
            return Err(STG_E_INVALIDFUNCTION.into());
        }
        if !position.is_null() {
            unsafe {
                *position = buffer.position() as u64;
            }
        }
        Ok(())
    }
    fn SetSize(&self, size: u64) -> windows::core::Result<()> {
        if self
            .buffer
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .resize(size)
        {
            Ok(())
        } else {
            Err(STG_E_MEDIUMFULL.into())
        }
    }
    fn CopyTo(
        &self,
        _stream: Ref<'_, IStream>,
        _size: u64,
        read: *mut u64,
        written: *mut u64,
    ) -> windows::core::Result<()> {
        if !read.is_null() {
            unsafe {
                *read = 0;
            }
        }
        if !written.is_null() {
            unsafe {
                *written = 0;
            }
        }
        Err(E_NOTIMPL.into())
    }
    fn Commit(&self, _flags: &STGC) -> windows::core::Result<()> {
        Ok(())
    }
    fn Revert(&self) -> windows::core::Result<()> {
        Err(E_NOTIMPL.into())
    }
    fn LockRegion(&self, _offset: u64, _size: u64, _kind: &LOCKTYPE) -> windows::core::Result<()> {
        Err(STG_E_INVALIDFUNCTION.into())
    }
    fn UnlockRegion(&self, _offset: u64, _size: u64, _kind: u32) -> windows::core::Result<()> {
        Err(STG_E_INVALIDFUNCTION.into())
    }
    fn Stat(&self, stat: *mut STATSTG, _flags: &STATFLAG) -> windows::core::Result<()> {
        if stat.is_null() {
            return Err(E_POINTER.into());
        }
        let size = self.buffer.lock().unwrap_or_else(|e| e.into_inner()).len();
        unsafe {
            stat.write(STATSTG {
                r#type: STGTY_STREAM.0 as u32,
                cbSize: size as u64,
                grfMode: STGM_READWRITE,
                ..Default::default()
            });
        }
        Ok(())
    }
    fn Clone(&self) -> windows::core::Result<IStream> {
        Err(E_NOTIMPL.into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::browser::shutdown::Shutdown;
    #[test]
    fn actual_bounded_com_stream_keeps_native_lease_until_last_release() {
        let mut owner = Shutdown::default();
        let buffer = Arc::new(Mutex::new(Buffer::default()));
        let stream = stream(buffer.clone(), owner.callbacks.lifetimes().block());
        let retained = stream.clone();
        assert_eq!(owner.status(0, 0, 0).callback_blocks_pending, 1);
        let png = coincide_core::appshots::encode_rgba(1, 1, vec![0; 4]).unwrap();
        let mut written = 0;
        assert!(
            unsafe { stream.Write(png.as_ptr().cast(), png.len() as u32, Some(&mut written)) }
                .is_ok()
        );
        assert_eq!(written as usize, png.len());
        drop(stream);
        assert_eq!(owner.status(0, 0, 0).callback_blocks_pending, 1);
        assert_eq!(buffer.lock().unwrap().seal().unwrap(), png);
        let value = [7u8];
        written = 99;
        assert!(unsafe { retained.Write(value.as_ptr().cast(), 1, Some(&mut written)) }.is_err());
        assert_eq!(written, 0);
        drop(retained);
        assert_eq!(owner.status(0, 0, 0).callback_blocks_pending, 0);
    }
}
