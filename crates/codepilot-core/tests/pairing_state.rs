use std::{
    fs,
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

use codepilot_core::pairing::state::{
    PairingMaterialOptions, default_pairing_state_path, load_or_create_pairing_material,
};
use sha2::{Digest, Sha256};

fn unique_temp_dir() -> PathBuf {
    let suffix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("codepilot-rust-pairing-{suffix}"))
}

#[test]
fn default_pairing_state_path_matches_the_typescript_hashing_scheme() {
    let work_dir = unique_temp_dir();
    fs::create_dir_all(&work_dir).unwrap();

    let path = default_pairing_state_path(&work_dir).unwrap();
    let normalized = fs::canonicalize(&work_dir).unwrap();
    let work_dir_hash = hex::encode(Sha256::digest(normalized.to_string_lossy().as_bytes()));
    let expected = PathBuf::from(std::env::var("HOME").unwrap())
        .join(".codepilot")
        .join("pairing")
        .join(format!("{}.json", &work_dir_hash[..16]));

    assert_eq!(path, expected);
}

#[test]
fn load_or_create_pairing_material_writes_the_existing_json_shape() {
    let temp_root = unique_temp_dir();
    fs::create_dir_all(&temp_root).unwrap();
    let state_path = temp_root.join("pairing.json");

    let material = load_or_create_pairing_material(PairingMaterialOptions {
        file_path: Some(state_path.clone()),
        work_dir: None,
    })
    .unwrap();

    let raw = fs::read_to_string(&state_path).unwrap();
    let value: serde_json::Value = serde_json::from_str(&raw).unwrap();

    assert_eq!(value["version"], 1);
    assert_eq!(
        value["privateKeyBase64"].as_str().unwrap(),
        material.private_key_base64()
    );
    assert_eq!(value["otp"], material.otp);
    assert_eq!(value["token"], material.token);
}
