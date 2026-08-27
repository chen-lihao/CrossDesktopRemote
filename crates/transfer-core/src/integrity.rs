use std::{fs::File, io::Read, path::Path};

use sha2::{Digest, Sha256};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Sha256Digest(pub [u8; 32]);

impl Sha256Digest {
    #[must_use]
    pub fn to_hex(self) -> String {
        const HEX: &[u8; 16] = b"0123456789abcdef";
        let mut output = String::with_capacity(64);
        for byte in self.0 {
            output.push(char::from(HEX[usize::from(byte >> 4)]));
            output.push(char::from(HEX[usize::from(byte & 0x0f)]));
        }
        output
    }
}

#[derive(Debug, Default)]
pub struct Sha256Verifier(Sha256);

impl Sha256Verifier {
    #[must_use]
    pub fn new() -> Self {
        Self(Sha256::new())
    }

    pub fn update(&mut self, bytes: &[u8]) {
        self.0.update(bytes);
    }

    #[must_use]
    pub fn finalize(self) -> Sha256Digest {
        Sha256Digest(self.0.finalize().into())
    }

    pub fn verify(self, expected: Sha256Digest) -> crate::TransferResult<()> {
        if self.finalize() == expected {
            Ok(())
        } else {
            Err(crate::TransferError::new(
                crate::TransferErrorKind::Integrity,
                "SHA-256 verification failed",
            ))
        }
    }
}

pub fn sha256_reader(mut reader: impl Read) -> std::io::Result<Sha256Digest> {
    let mut verifier = Sha256Verifier::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        verifier.update(&buffer[..read]);
    }
    Ok(verifier.finalize())
}

pub fn sha256_file(path: impl AsRef<Path>) -> std::io::Result<Sha256Digest> {
    sha256_reader(File::open(path)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_the_standard_abc_vector() {
        let digest = sha256_reader("abc".as_bytes()).expect("hash");
        assert_eq!(
            digest.to_hex(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn rejects_a_mismatched_digest() {
        let mut verifier = Sha256Verifier::new();
        verifier.update(b"abc");
        assert_eq!(
            verifier
                .verify(Sha256Digest([0; 32]))
                .expect_err("digest must not match")
                .kind,
            crate::TransferErrorKind::Integrity
        );
    }
}
