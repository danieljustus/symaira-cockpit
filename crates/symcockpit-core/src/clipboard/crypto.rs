//! AES-256-GCM sealing of clipboard payloads. A sealed blob is `nonce (12) || ciphertext+tag`.
//! The item id is bound as associated data, so a blob cannot be moved to another item.

use aes_gcm::{
    Aes256Gcm, Nonce,
    aead::{Aead, KeyInit, Payload},
};

pub const KEY_LEN: usize = 32;
const NONCE_LEN: usize = 12;

pub type Key = [u8; KEY_LEN];

pub fn random_key() -> Key {
    let mut k = [0u8; KEY_LEN];
    getrandom::fill(&mut k).expect("system random source");
    k
}

pub fn seal(key: &Key, aad: &[u8], plain: &[u8]) -> Vec<u8> {
    let cipher = Aes256Gcm::new_from_slice(key).expect("32-byte key");
    let mut nonce = [0u8; NONCE_LEN];
    getrandom::fill(&mut nonce).expect("system random source");
    // A random 96-bit nonce is safe for far more items than a clipboard history ever holds.
    let ct = cipher
        .encrypt(&Nonce::from(nonce), Payload { msg: plain, aad })
        .expect("AES-GCM encryption of in-memory data");
    [nonce.as_slice(), &ct].concat()
}

/// `None` for a wrong key, wrong `aad`, truncation or any tampering.
pub fn open(key: &Key, aad: &[u8], blob: &[u8]) -> Option<Vec<u8>> {
    if blob.len() < NONCE_LEN + 16 {
        return None;
    }
    let (nonce, ct) = blob.split_at(NONCE_LEN);
    let nonce: [u8; NONCE_LEN] = nonce.try_into().ok()?;
    Aes256Gcm::new_from_slice(key)
        .ok()?
        .decrypt(&Nonce::from(nonce), Payload { msg: ct, aad })
        .ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_every_kind_of_tampering_fails() {
        let key = random_key();
        let blob = seal(&key, b"item-1", b"secret text");
        assert!(!blob.windows(11).any(|w| w == b"secret text"));
        assert_eq!(
            open(&key, b"item-1", &blob).as_deref(),
            Some(&b"secret text"[..])
        );
        assert_eq!(open(&key, b"item-2", &blob), None, "bound to its item");
        assert_eq!(open(&random_key(), b"item-1", &blob), None, "wrong key");
        let mut flipped = blob.clone();
        *flipped.last_mut().unwrap() ^= 1;
        assert_eq!(open(&key, b"item-1", &flipped), None);
        assert_eq!(open(&key, b"item-1", &blob[..20]), None);
        assert_ne!(
            blob,
            seal(&key, b"item-1", b"secret text"),
            "fresh nonce each time"
        );
    }
}
