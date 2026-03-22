use crate::pairing::crypto::public_key_from_private_key_base64;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use rand::random;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    env,
    fmt::{Display, Formatter},
    fs, io,
    path::{Path, PathBuf},
};

#[derive(Debug)]
pub enum PairingStateError {
    MissingHomeDirectory,
    Io(io::Error),
    Json(serde_json::Error),
    InvalidPersistedState(PathBuf),
    Crypto(crate::pairing::crypto::CryptoError),
}

impl Display for PairingStateError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::MissingHomeDirectory => write!(f, "HOME is not set"),
            Self::Io(err) => write!(f, "io error: {err}"),
            Self::Json(err) => write!(f, "json error: {err}"),
            Self::InvalidPersistedState(path) => {
                write!(f, "invalid pairing state file: {}", path.display())
            }
            Self::Crypto(err) => write!(f, "crypto error: {err}"),
        }
    }
}

impl std::error::Error for PairingStateError {}

impl From<io::Error> for PairingStateError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

impl From<serde_json::Error> for PairingStateError {
    fn from(value: serde_json::Error) -> Self {
        Self::Json(value)
    }
}

impl From<crate::pairing::crypto::CryptoError> for PairingStateError {
    fn from(value: crate::pairing::crypto::CryptoError) -> Self {
        Self::Crypto(value)
    }
}

pub type Result<T> = std::result::Result<T, PairingStateError>;

#[derive(Debug, Clone, Default)]
pub struct PairingMaterialOptions {
    pub file_path: Option<PathBuf>,
    pub work_dir: Option<PathBuf>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PersistedPairingMaterial {
    version: u8,
    #[serde(rename = "privateKeyBase64")]
    private_key_base64: String,
    otp: String,
    token: String,
}

#[derive(Debug, Clone)]
pub struct PairingMaterial {
    pub private_key_base64: String,
    pub public_key_base64: String,
    pub otp: String,
    pub token: String,
    pub state_path: PathBuf,
}

impl PairingMaterial {
    pub fn private_key_base64(&self) -> &str {
        &self.private_key_base64
    }
}

fn home_dir() -> Result<PathBuf> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or(PairingStateError::MissingHomeDirectory)
}

pub fn default_pairing_state_path(work_dir: impl AsRef<Path>) -> Result<PathBuf> {
    let normalized =
        fs::canonicalize(work_dir.as_ref()).unwrap_or_else(|_| work_dir.as_ref().to_path_buf());
    let hash = hex::encode(Sha256::digest(normalized.to_string_lossy().as_bytes()));

    Ok(home_dir()?
        .join(".codepilot")
        .join("pairing")
        .join(format!("{}.json", &hash[..16])))
}

fn random_hex<const N: usize>() -> String {
    let bytes: [u8; N] = random();
    hex::encode(bytes)
}

fn random_private_key_base64() -> String {
    let private_key_bytes: [u8; 32] = random();
    STANDARD.encode(private_key_bytes)
}

fn load_persisted_pairing_material(path: &Path) -> Result<Option<PersistedPairingMaterial>> {
    match fs::read_to_string(path) {
        Ok(raw) => {
            let parsed: PersistedPairingMaterial = serde_json::from_str(&raw)?;
            if parsed.version != 1
                || parsed.private_key_base64.is_empty()
                || parsed.otp.is_empty()
                || parsed.token.is_empty()
            {
                return Err(PairingStateError::InvalidPersistedState(path.to_path_buf()));
            }
            Ok(Some(parsed))
        }
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(PairingStateError::Io(err)),
    }
}

fn save_persisted_pairing_material(material: &PairingMaterial) -> Result<()> {
    let persisted = PersistedPairingMaterial {
        version: 1,
        private_key_base64: material.private_key_base64.clone(),
        otp: material.otp.clone(),
        token: material.token.clone(),
    };

    if let Some(parent) = material.state_path.parent() {
        fs::create_dir_all(parent)?;
    }

    let raw = format!("{}\n", serde_json::to_string_pretty(&persisted)?);
    fs::write(&material.state_path, raw)?;
    Ok(())
}

pub fn load_or_create_pairing_material(options: PairingMaterialOptions) -> Result<PairingMaterial> {
    let state_path = match options.file_path {
        Some(path) => path,
        None => default_pairing_state_path(
            options
                .work_dir
                .unwrap_or_else(|| env::current_dir().expect("current dir")),
        )?,
    };

    if let Some(persisted) = load_persisted_pairing_material(&state_path)? {
        return Ok(PairingMaterial {
            public_key_base64: public_key_from_private_key_base64(&persisted.private_key_base64)?,
            private_key_base64: persisted.private_key_base64,
            otp: persisted.otp,
            token: persisted.token,
            state_path,
        });
    }

    let private_key_base64 = random_private_key_base64();
    let material = PairingMaterial {
        public_key_base64: public_key_from_private_key_base64(&private_key_base64)?,
        private_key_base64,
        otp: random_hex::<3>(),
        token: random_hex::<16>(),
        state_path,
    };
    save_persisted_pairing_material(&material)?;
    Ok(material)
}
