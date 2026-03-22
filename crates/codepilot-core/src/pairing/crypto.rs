use aes_gcm::{
    Aes256Gcm, Nonce,
    aead::{Aead, KeyInit},
};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use codepilot_protocol::messages::EncryptedWireMessage;
use hkdf::Hkdf;
use rand::random;
use sha2::Sha256;
use std::fmt::{Display, Formatter};
use x25519_dalek::{PublicKey, StaticSecret};

const INFO: &[u8] = b"codepilot-e2e-v1";

pub type EncryptedMessage = EncryptedWireMessage;

#[derive(Debug)]
pub enum CryptoError {
    InvalidPrivateKeyLength(usize),
    InvalidPublicKeyLength(usize),
    InvalidNonceLength(usize),
    Base64(base64::DecodeError),
    Encrypt(aes_gcm::Error),
    Decrypt(aes_gcm::Error),
    HkdfLength(hkdf::InvalidLength),
    Utf8(std::string::FromUtf8Error),
}

impl Display for CryptoError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidPrivateKeyLength(len) => {
                write!(
                    f,
                    "invalid private key length: expected 32 bytes, got {len}"
                )
            }
            Self::InvalidPublicKeyLength(len) => {
                write!(f, "invalid public key length: expected 32 bytes, got {len}")
            }
            Self::InvalidNonceLength(len) => {
                write!(f, "invalid nonce length: expected 12 bytes, got {len}")
            }
            Self::Base64(err) => write!(f, "base64 decode error: {err}"),
            Self::Encrypt(_) => write!(f, "aes-256-gcm encryption failed"),
            Self::Decrypt(_) => write!(f, "aes-256-gcm decryption failed"),
            Self::HkdfLength(err) => write!(f, "hkdf output length error: {err}"),
            Self::Utf8(err) => write!(f, "utf-8 decode error: {err}"),
        }
    }
}

impl std::error::Error for CryptoError {}

impl From<base64::DecodeError> for CryptoError {
    fn from(value: base64::DecodeError) -> Self {
        Self::Base64(value)
    }
}

impl From<hkdf::InvalidLength> for CryptoError {
    fn from(value: hkdf::InvalidLength) -> Self {
        Self::HkdfLength(value)
    }
}

impl From<std::string::FromUtf8Error> for CryptoError {
    fn from(value: std::string::FromUtf8Error) -> Self {
        Self::Utf8(value)
    }
}

pub type Result<T> = std::result::Result<T, CryptoError>;

fn decode_32_bytes(input: &str, kind: &'static str) -> Result<[u8; 32]> {
    let bytes = STANDARD.decode(input)?;
    if bytes.len() != 32 {
        return Err(match kind {
            "private" => CryptoError::InvalidPrivateKeyLength(bytes.len()),
            _ => CryptoError::InvalidPublicKeyLength(bytes.len()),
        });
    }

    let mut out = [0_u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

pub fn public_key_from_private_key_base64(private_key_base64: &str) -> Result<String> {
    let private_key_bytes = decode_32_bytes(private_key_base64, "private")?;
    let secret = StaticSecret::from(private_key_bytes);
    let public_key = PublicKey::from(&secret);
    Ok(STANDARD.encode(public_key.as_bytes()))
}

pub fn derive_session_key_from_raw(
    my_private_key_base64: &str,
    their_public_key_base64: &str,
    otp: &str,
) -> Result<[u8; 32]> {
    let private_key_bytes = decode_32_bytes(my_private_key_base64, "private")?;
    let public_key_bytes = decode_32_bytes(their_public_key_base64, "public")?;

    let private_key = StaticSecret::from(private_key_bytes);
    let public_key = PublicKey::from(public_key_bytes);
    let shared_secret = private_key.diffie_hellman(&public_key);

    let hkdf = Hkdf::<Sha256>::new(Some(otp.as_bytes()), shared_secret.as_bytes());
    let mut session_key = [0_u8; 32];
    hkdf.expand(INFO, &mut session_key)?;
    Ok(session_key)
}

pub fn encrypt(session_key: &[u8; 32], plaintext: &str) -> Result<EncryptedMessage> {
    let cipher = Aes256Gcm::new_from_slice(session_key).expect("32-byte key");
    let nonce_bytes: [u8; 12] = random();
    let nonce = Nonce::from_slice(&nonce_bytes);

    let encrypted = cipher
        .encrypt(nonce, plaintext.as_bytes())
        .map_err(CryptoError::Encrypt)?;
    let split_at = encrypted.len() - 16;
    let (ciphertext, tag) = encrypted.split_at(split_at);

    Ok(EncryptedMessage {
        v: 1,
        nonce: STANDARD.encode(nonce_bytes),
        ciphertext: STANDARD.encode(ciphertext),
        tag: STANDARD.encode(tag),
    })
}

pub fn decrypt(session_key: &[u8; 32], msg: &EncryptedMessage) -> Result<String> {
    if msg.v != 1 {
        return Err(CryptoError::InvalidNonceLength(usize::from(msg.v)));
    }

    let nonce_bytes = STANDARD.decode(&msg.nonce)?;
    if nonce_bytes.len() != 12 {
        return Err(CryptoError::InvalidNonceLength(nonce_bytes.len()));
    }

    let mut nonce_array = [0_u8; 12];
    nonce_array.copy_from_slice(&nonce_bytes);

    let ciphertext = STANDARD.decode(&msg.ciphertext)?;
    let tag = STANDARD.decode(&msg.tag)?;

    let cipher = Aes256Gcm::new_from_slice(session_key).expect("32-byte key");
    let mut combined = ciphertext;
    combined.extend_from_slice(&tag);
    let plaintext = cipher
        .decrypt(Nonce::from_slice(&nonce_array), combined.as_ref())
        .map_err(CryptoError::Decrypt)?;

    Ok(String::from_utf8(plaintext)?)
}
