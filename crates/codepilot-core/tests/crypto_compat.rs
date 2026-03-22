use base64::{Engine as _, engine::general_purpose::STANDARD};
use codepilot_core::pairing::crypto::{EncryptedMessage, decrypt, derive_session_key_from_raw};

fn fixture_encrypted_message() -> EncryptedMessage {
    EncryptedMessage {
        v: 1,
        nonce: "ElFfXGGedmdn/zd3".to_owned(),
        ciphertext: "eyC7YZEAilOp3962aotF4UdUsAPJvCieyl8sTlISjTwvYb8=".to_owned(),
        tag: "Vhix6knV9TV05isaZra9zQ==".to_owned(),
    }
}

#[test]
fn derive_session_key_matches_the_current_typescript_implementation() {
    let bridge_private_key_base64 = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=";
    let phone_public_key_base64 = "V9tLNZ8jrl4Ubk4lEgVnBHIlBjSMFQwUdT0Mkz0E1CE=";
    let otp = "a1b2c3";

    let session_key =
        derive_session_key_from_raw(bridge_private_key_base64, phone_public_key_base64, otp)
            .unwrap();

    assert_eq!(
        STANDARD.encode(session_key),
        "+Sl2VCg2c9KDZW7kGpI7+a+S2KqvDjmuKKJQE3zhEKo="
    );
}

#[test]
fn decrypt_matches_a_message_encrypted_by_the_current_typescript_implementation() {
    let bridge_private_key_base64 = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=";
    let phone_public_key_base64 = "V9tLNZ8jrl4Ubk4lEgVnBHIlBjSMFQwUdT0Mkz0E1CE=";
    let otp = "a1b2c3";

    let session_key =
        derive_session_key_from_raw(bridge_private_key_base64, phone_public_key_base64, otp)
            .unwrap();
    let plaintext = decrypt(&session_key, &fixture_encrypted_message()).unwrap();

    assert_eq!(plaintext, r#"{"type":"command","text":"ship it"}"#);
}
