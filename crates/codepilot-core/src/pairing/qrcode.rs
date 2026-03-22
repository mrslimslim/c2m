use qrcode::{QrCode, render::unicode};

pub fn render_pairing_qr(payload: &str) -> Result<String, qrcode::types::QrError> {
    let code = QrCode::new(payload.as_bytes())?;
    Ok(code.render::<unicode::Dense1x2>().quiet_zone(false).build())
}
