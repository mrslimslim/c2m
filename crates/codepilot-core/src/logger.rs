const RESET: &str = "\x1b[0m";
const DIM: &str = "\x1b[2m";
const GREEN: &str = "\x1b[32m";
const YELLOW: &str = "\x1b[33m";
const RED: &str = "\x1b[31m";
const CYAN: &str = "\x1b[36m";
const MAGENTA: &str = "\x1b[35m";

pub struct Logger;

impl Logger {
    pub fn info(&self, message: &str) {
        println!("{CYAN}[codepilot]{RESET} {message}");
    }

    pub fn success(&self, message: &str) {
        println!("{GREEN}\u{2713}{RESET} {message}");
    }

    pub fn warn(&self, message: &str) {
        println!("{YELLOW}!{RESET} {message}");
    }

    pub fn error(&self, message: &str) {
        eprintln!("{RED}x{RESET} {message}");
    }

    pub fn event(&self, session_id: &str, event_type: &str, detail: &str) {
        let trimmed = session_id.chars().take(12).collect::<String>();
        println!("{DIM}[{trimmed}]{RESET} {MAGENTA}{event_type}{RESET} {detail}");
    }

    pub fn connection(&self, message: &str) {
        println!("{GREEN}device{RESET} {message}");
    }
}

pub static LOG: Logger = Logger;
