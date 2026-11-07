//! The pairing QR code's modules, as Core Image's `qrCodeGenerator` makes the
//! Mac's: byte mode, error correction level M.
use qrcodegen::{QrCode, QrCodeEcc};

/// A square of dark (`true`) and light modules, without the quiet zone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Matrix {
    pub size: usize,
    pub modules: Vec<bool>,
}
impl Matrix {
    pub fn dark(&self, x: usize, y: usize) -> bool {
        self.modules[y * self.size + x]
    }

    /// Runs of dark modules per row as (row, first column, length), so a view
    /// can draw a code with a few hundred rectangles instead of thousands.
    pub fn runs(&self) -> Vec<(usize, usize, usize)> {
        let mut runs = Vec::new();
        for y in 0..self.size {
            let mut x = 0;
            while x < self.size {
                if self.dark(x, y) {
                    let start = x;
                    while x < self.size && self.dark(x, y) {
                        x += 1;
                    }
                    runs.push((y, start, x - start));
                } else {
                    x += 1;
                }
            }
        }
        runs
    }
}

pub fn encode(text: &str) -> Option<Matrix> {
    let code = QrCode::encode_binary(text.as_bytes(), QrCodeEcc::Medium).ok()?;
    let size = usize::try_from(code.size()).ok()?;
    let modules = (0..size)
        .flat_map(|y| (0..size).map(move |x| (x, y)))
        .map(|(x, y)| code.get_module(x as i32, y as i32))
        .collect();
    Some(Matrix { size, modules })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pairing_codes_encode_with_finder_patterns() {
        let payload = format!("coincide-remote:pair#{}", "A".repeat(400));
        let matrix = encode(&payload).unwrap();
        assert!(matrix.size >= 21 && (matrix.size - 21).is_multiple_of(4));
        // The top-left finder pattern: a dark 7×7 ring around a light ring.
        assert!((0..7).all(|i| matrix.dark(i, 0) && matrix.dark(0, i)));
        assert!(!matrix.dark(1, 1) && matrix.dark(2, 2));
        let dark = matrix.modules.iter().filter(|&&m| m).count();
        assert_eq!(matrix.runs().iter().map(|r| r.2).sum::<usize>(), dark);
    }
}
