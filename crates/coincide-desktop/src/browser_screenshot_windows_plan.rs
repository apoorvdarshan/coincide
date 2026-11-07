//! Bounded in-memory native stream data. No path, SDK method or browser grant.
use coincide_core::browser_screenshot::MAX_PNG_BYTES;
#[derive(Default)]
pub(super) struct Buffer {
    bytes: Vec<u8>,
    position: usize,
    sealed: bool,
}
impl Buffer {
    pub fn len(&self) -> usize {
        self.bytes.len()
    }
    pub fn position(&self) -> usize {
        self.position
    }
    pub fn write(&mut self, bytes: &[u8]) -> bool {
        let Some(end) = self
            .position
            .checked_add(bytes.len())
            .filter(|end| *end <= MAX_PNG_BYTES)
        else {
            return false;
        };
        if self.sealed {
            return false;
        }
        if end > self.bytes.capacity()
            && self
                .bytes
                .try_reserve_exact(end - self.bytes.len())
                .is_err()
        {
            return false;
        }
        self.bytes.resize(self.bytes.len().max(end), 0);
        self.bytes[self.position..end].copy_from_slice(bytes);
        self.position = end;
        true
    }
    pub fn read(&mut self, out: &mut [u8]) -> Option<usize> {
        if self.sealed {
            return None;
        }
        if self.position >= self.bytes.len() {
            return Some(0);
        }
        let size = out
            .len()
            .min(self.bytes.len().saturating_sub(self.position));
        out[..size].copy_from_slice(&self.bytes[self.position..self.position + size]);
        self.position += size;
        Some(size)
    }
    pub fn seek(&mut self, offset: i64, origin: u32) -> bool {
        if self.sealed {
            return false;
        }
        let base = match origin {
            0 => 0i128,
            1 => self.position as i128,
            2 => self.bytes.len() as i128,
            _ => return false,
        };
        let position = base + i128::from(offset);
        if !(0..=MAX_PNG_BYTES as i128).contains(&position) {
            return false;
        }
        self.position = position as usize;
        true
    }
    pub fn resize(&mut self, size: u64) -> bool {
        if self.sealed || size > MAX_PNG_BYTES as u64 {
            return false;
        }
        if size as usize > self.bytes.capacity()
            && self
                .bytes
                .try_reserve_exact(size as usize - self.bytes.len())
                .is_err()
        {
            return false;
        }
        self.bytes.resize(size as usize, 0);
        self.position = self.position.min(size as usize);
        true
    }
    /// Seal at the actual SDK callback boundary. A retained native IStream can
    /// never alter the pixels later used by the encoder worker.
    pub fn seal(&mut self) -> Option<Vec<u8>> {
        if self.sealed {
            return None;
        }
        self.sealed = true;
        let bytes = std::mem::take(&mut self.bytes);
        (bytes.len() <= MAX_PNG_BYTES && bytes.starts_with(b"\x89PNG\r\n\x1a\n")).then_some(bytes)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_stream_seek_write_read_and_hard_cap() {
        let mut stream = Buffer::default();
        assert!(stream.write(b"abc"));
        assert_eq!(stream.position(), 3);
        assert!(stream.seek(-2, 1));
        assert!(stream.write(b"Z"));
        assert_eq!(stream.len(), 3);
        assert!(stream.seek(0, 0));
        let mut output = [0; 4];
        assert_eq!(stream.read(&mut output), Some(3));
        assert_eq!(&output[..3], b"aZc");
        assert!(!stream.seek(i64::MAX, 2));
        assert!(!stream.seek(-1, 0));
        assert!(!stream.resize(MAX_PNG_BYTES as u64 + 1));
        assert!(stream.seek(MAX_PNG_BYTES as i64, 0));
        assert!(!stream.write(&[1]));
        assert_eq!(stream.read(&mut [0; 4]), Some(0));
        assert_eq!(stream.len(), 3);
        assert!(stream.resize(1));
        assert_eq!(stream.len(), 1);
        assert!(stream.resize((12 * 1024 * 1024) as u64));
        assert!(stream.seek(0, 2));
        assert!(stream.write(&vec![0; 1024 * 1024]));
        assert!(stream.bytes.capacity() <= MAX_PNG_BYTES);
    }
    #[test]
    fn sdk_completion_seals_png_and_refuses_retained_writer_mutation() {
        let mut invalid = Buffer::default();
        assert!(invalid.write(b"not PNG"));
        assert!(invalid.seal().is_none());
        assert!(!invalid.write(b"later"));
        let png = coincide_core::appshots::encode_rgba(1, 1, vec![0; 4]).unwrap();
        let mut stream = Buffer::default();
        assert!(stream.write(&png));
        assert_eq!(stream.seal().unwrap(), png);
        assert!(!stream.write(b"later"));
        assert!(!stream.resize(1));
        assert!(!stream.seek(0, 0));
        assert!(stream.read(&mut [0]).is_none());
        assert!(stream.seal().is_none());
    }
}
