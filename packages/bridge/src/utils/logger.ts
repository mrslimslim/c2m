/**
 * Simple colored logger for the bridge CLI.
 */

const COLORS = {
  reset: "\x1b[0m",
  dim: "\x1b[2m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  red: "\x1b[31m",
  cyan: "\x1b[36m",
  magenta: "\x1b[35m",
} as const;

export const log = {
  info: (msg: string, ...args: unknown[]) =>
    console.log(`${COLORS.cyan}[codepilot]${COLORS.reset} ${msg}`, ...args),

  success: (msg: string, ...args: unknown[]) =>
    console.log(`${COLORS.green}✓${COLORS.reset} ${msg}`, ...args),

  warn: (msg: string, ...args: unknown[]) =>
    console.log(`${COLORS.yellow}⚠${COLORS.reset} ${msg}`, ...args),

  error: (msg: string, ...args: unknown[]) =>
    console.error(`${COLORS.red}✗${COLORS.reset} ${msg}`, ...args),

  event: (sessionId: string, eventType: string, detail: string) =>
    console.log(
      `${COLORS.dim}[${sessionId.slice(0, 12)}]${COLORS.reset} ${COLORS.magenta}${eventType}${COLORS.reset} ${detail}`,
    ),

  connection: (msg: string) =>
    console.log(`${COLORS.green}📱${COLORS.reset} ${msg}`),
};
