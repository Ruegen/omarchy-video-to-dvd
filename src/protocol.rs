use std::io::{self, Write};

pub fn emit(line: &str) {
    let mut out = io::stdout();
    let _ = writeln!(out, "{line}");
    let _ = out.flush();
}

pub fn fail(err: &str) -> i32 {
    emit(&format!("RESULT:ERROR:{err}"));
    1
}

pub fn progress(pct: i32, payload: &str) {
    emit(&format!("PROGRESS:{pct}:{payload}"));
}

pub fn printable(s: &str) -> String {
    s.chars().filter(|c| !c.is_control()).collect()
}
