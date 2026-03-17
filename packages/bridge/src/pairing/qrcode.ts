/**
 * QR code generation for terminal display.
 */

import qrcode from "qrcode-terminal";

export function displayQRCode(data: Record<string, unknown>): void {
  const json = JSON.stringify(data);
  qrcode.generate(json, { small: true }, (code: string) => {
    console.log();
    console.log(code);
    console.log();
  });
}
