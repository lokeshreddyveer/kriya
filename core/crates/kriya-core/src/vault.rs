//! Sealing what the clipboard history holds, so the file on disk is unreadable without the key.
//!
//! The key is made and kept by the app (in the macOS Keychain) and handed to the core as 32 bytes. Each value is sealed on its
//! own with AES-256-GCM and a fresh random nonce, and is bound to the row and column it belongs to, so a sealed value copied
//! to another row does not open. Text is stored as a marker and hex; binary values start with `KV1\0`. A value with neither
//! marker is plain, which is how history from before the vault was turned on looks, and how it reads until it is sealed.

use aes_gcm::{
    aead::{Aead, AeadCore, KeyInit, OsRng, Payload},
    Aes256Gcm, Key, Nonce,
};
use hmac::{Hmac, Mac};
use sha2::Sha256;

use crate::error::CoreError;

pub const KEY_BYTES: usize = 32;
const NONCE_BYTES: usize = 12;
/// Starts every sealed text value. It begins with a control character, so ordinary copied text never looks sealed.
pub const TEXT_PREFIX: &str = "\u{1}kv1\u{1}";
const BLOB_MAGIC: &[u8] = b"KV1\0";
/// What the key check holds, sealed. Opening it back proves a key is the right one.
const VERIFIER_PLAIN: &[u8] = b"kriya clipboard vault";
const VERIFIER_CONTEXT: &str = "vault:verifier";

pub struct Vault {
    cipher: Aes256Gcm,
    mac_key: [u8; KEY_BYTES],
}

impl Vault {
    pub fn new(key: &[u8]) -> Result<Vault, CoreError> {
        if key.len() != KEY_BYTES {
            return Err(CoreError::invalid("the encryption key is the wrong size"));
        }
        let mut mac_key = [0u8; KEY_BYTES];
        // A separate key for the content fingerprint, so the one key is never used for two jobs.
        let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(key)
            .map_err(|_| CoreError::invalid("the encryption key is the wrong size"))?;
        mac.update(b"kriya clipboard fingerprint key");
        mac_key.copy_from_slice(&mac.finalize().into_bytes());
        Ok(Vault {
            cipher: Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key)),
            mac_key,
        })
    }

    /// Seals `plain`, bound to `context` (the row and column). The result is the nonce followed by the ciphertext.
    pub fn seal(&self, plain: &[u8], context: &str) -> Vec<u8> {
        let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
        let mut out = nonce.to_vec();
        // Sealing only fails for inputs far larger than anything the history holds; an empty result is then refused on open.
        if let Ok(sealed) = self.cipher.encrypt(
            &nonce,
            Payload {
                msg: plain,
                aad: context.as_bytes(),
            },
        ) {
            out.extend_from_slice(&sealed);
        }
        out
    }

    pub fn open(&self, sealed: &[u8], context: &str) -> Option<Vec<u8>> {
        if sealed.len() <= NONCE_BYTES {
            return None;
        }
        let (nonce, body) = sealed.split_at(NONCE_BYTES);
        self.cipher
            .decrypt(
                Nonce::from_slice(nonce),
                Payload {
                    msg: body,
                    aad: context.as_bytes(),
                },
            )
            .ok()
    }

    pub fn seal_text(&self, plain: &str, context: &str) -> String {
        format!(
            "{TEXT_PREFIX}{}",
            to_hex(&self.seal(plain.as_bytes(), context))
        )
    }

    pub fn open_text(&self, sealed: &str, context: &str) -> Option<String> {
        let hex = sealed.strip_prefix(TEXT_PREFIX)?;
        let bytes = from_hex(hex)?;
        String::from_utf8(self.open(&bytes, context)?).ok()
    }

    pub fn seal_blob(&self, plain: &[u8], context: &str) -> Vec<u8> {
        let mut out = BLOB_MAGIC.to_vec();
        out.extend_from_slice(&self.seal(plain, context));
        out
    }

    pub fn open_blob(&self, sealed: &[u8], context: &str) -> Option<Vec<u8>> {
        self.open(sealed.strip_prefix(BLOB_MAGIC)?, context)
    }

    /// A fingerprint of some content that cannot be checked without the key, used to spot the same copy twice.
    pub fn fingerprint(&self, plain_hash: &str) -> String {
        let Ok(mut mac) = <Hmac<Sha256> as Mac>::new_from_slice(&self.mac_key) else {
            return plain_hash.to_string();
        };
        mac.update(plain_hash.as_bytes());
        to_hex(&mac.finalize().into_bytes())
    }

    pub fn verifier(&self) -> Vec<u8> {
        self.seal_blob(VERIFIER_PLAIN, VERIFIER_CONTEXT)
    }

    pub fn matches_verifier(&self, verifier: &[u8]) -> bool {
        self.open_blob(verifier, VERIFIER_CONTEXT).as_deref() == Some(VERIFIER_PLAIN)
    }
}

pub fn is_sealed_text(value: &str) -> bool {
    value.starts_with(TEXT_PREFIX)
}

pub fn is_sealed_blob(value: &[u8]) -> bool {
    value.starts_with(BLOB_MAGIC)
}

fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn from_hex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) || !text.is_ascii() {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&text[i..i + 2], 16).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vault(byte: u8) -> Vault {
        Vault::new(&[byte; KEY_BYTES]).unwrap()
    }

    #[test]
    fn text_and_blobs_round_trip_and_are_not_readable() {
        let v = vault(7);
        let sealed = v.seal_text("correct horse battery staple", "row1:preview");
        assert!(is_sealed_text(&sealed));
        assert!(!sealed.contains("horse"));
        assert_eq!(
            v.open_text(&sealed, "row1:preview").as_deref(),
            Some("correct horse battery staple")
        );
        let blob = v.seal_blob(&[1, 2, 3, 4, 5], "row1:image");
        assert!(is_sealed_blob(&blob));
        assert_eq!(v.open_blob(&blob, "row1:image"), Some(vec![1, 2, 3, 4, 5]));
    }

    #[test]
    fn a_sealed_value_only_opens_for_its_own_row_and_key() {
        let v = vault(1);
        let sealed = v.seal_text("secret", "row1:preview");
        assert_eq!(
            v.open_text(&sealed, "row2:preview"),
            None,
            "moved to another row"
        );
        assert_eq!(
            v.open_text(&sealed, "row1:title"),
            None,
            "moved to another column"
        );
        assert_eq!(
            vault(2).open_text(&sealed, "row1:preview"),
            None,
            "wrong key"
        );
        let mut changed = sealed.clone();
        let last = changed.pop().unwrap();
        changed.push(if last == '0' { '1' } else { '0' });
        assert_eq!(v.open_text(&changed, "row1:preview"), None, "changed value");
    }

    #[test]
    fn the_same_text_seals_differently_each_time() {
        let v = vault(3);
        assert_ne!(v.seal_text("same", "c"), v.seal_text("same", "c"));
    }

    #[test]
    fn the_key_check_accepts_only_the_right_key() {
        let a = vault(4);
        let check = a.verifier();
        assert!(a.matches_verifier(&check));
        assert!(!vault(5).matches_verifier(&check));
        assert!(!a.matches_verifier(b"nonsense"));
    }

    #[test]
    fn fingerprints_depend_on_the_key() {
        assert_eq!(vault(1).fingerprint("abc"), vault(1).fingerprint("abc"));
        assert_ne!(vault(1).fingerprint("abc"), vault(2).fingerprint("abc"));
        assert_eq!(vault(1).fingerprint("abc").len(), 64);
    }

    #[test]
    fn a_key_of_the_wrong_size_is_refused() {
        assert!(Vault::new(&[0u8; 16]).is_err());
        assert!(Vault::new(&[]).is_err());
    }
}
