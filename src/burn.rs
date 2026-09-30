use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::classify::{classify_blank, classify_udev_props, iso_size_of};
use crate::job::Phase;
use crate::protocol::{emit, fail};
use crate::security::{
    become_session_leader, capture_limited, cmd, have_cmd, iso_fingerprint, iso_is_safe_output,
    kill_group_children, maybe_newgrp_wrap, optical_dev_identity, require_optical_dev, resolve_dev,
    run_deadline, safe_unlink_iso, Runtime, CANCELLED, TIMEOUT_EJECT, TIMEOUT_GROWISOFS,
    TIMEOUT_MEDIAINFO,
};

fn try_eject(raw: &str, rt: &Runtime) -> bool {
    let Some(dev) = require_optical_dev(raw, None) else {
        return false;
    };
    let Some(ident) = optical_dev_identity(&dev) else {
        return false;
    };
    rt.append_log(&format!("=== eject dev={dev} ==="));
    std::thread::sleep(Duration::from_secs(1));
    let Some(dev) = require_optical_dev(&dev, Some(&ident)) else {
        return false;
    };
    if have_cmd("udisksctl") {
        let _ = run_deadline(TIMEOUT_EJECT, cmd("udisksctl", &["unmount", "-b", &dev]));
    }
    let _ = run_deadline(TIMEOUT_EJECT, cmd("umount", &[&dev]));
    let _ = run_deadline(TIMEOUT_EJECT, cmd("eject", &["-i", "off", &dev]));
    if have_cmd("udisksctl") {
        if run_deadline(TIMEOUT_EJECT, cmd("udisksctl", &["eject", "-b", &dev])).unwrap_or(1) == 0 {
            rt.enforce_log_bound();
            return true;
        }
    }
    for args in [["-F", dev.as_str()], ["-r", &dev], ["-s", &dev]] {
        if run_deadline(TIMEOUT_EJECT, cmd("eject", &args)).unwrap_or(1) == 0 {
            rt.enforce_log_bound();
            return true;
        }
    }
    rt.enforce_log_bound();
    false
}

pub fn eject(raw: &str, argv: &[String]) -> i32 {
    let dev = resolve_dev(raw);
    if let Some(d) = &dev {
        if let Some(rc) = maybe_newgrp_wrap(d, argv) {
            return rc;
        }
    }
    let Some(dev) = dev else {
        return fail("eject-failed");
    };
    let Ok(rt) = Runtime::init() else {
        return fail("eject-failed");
    };
    if try_eject(&dev, &rt) {
        emit("RESULT:OK:ejected");
        0
    } else {
        fail("eject-failed")
    }
}

pub fn blank_verdict(raw: &str, iso: &str) -> String {
    let Some(dev) = resolve_dev(raw) else {
        return "BLANK:NONE".into();
    };
    let iso_size = if !iso.is_empty() {
        iso_size_of(Path::new(iso))
    } else {
        None
    };
    let rt = Runtime::init().ok();
    let Some(dev) = require_optical_dev(&dev, None) else {
        return "BLANK:NONE".into();
    };
    let props = capture_limited(5, cmd("udevadm", &["info", "--query=property", &dev]));
    if !props.is_empty() {
        let verdict = classify_udev_props(&props, iso_size);
        if let Some(rt) = &rt {
            rt.append_log(&format!("UDEV:{verdict}"));
        }
        if matches!(verdict, "BLANK:YES" | "BLANK:NO" | "BLANK:TOO_SMALL") {
            return verdict.into();
        }
    }
    let info = capture_limited(TIMEOUT_MEDIAINFO, cmd("dvd+rw-mediainfo", &[&dev]));
    if let Some(rt) = &rt {
        rt.append_log(&info);
    }
    classify_blank(&info, iso_size).into()
}

pub fn check_blank(raw: &str, iso: &str) -> i32 {
    emit(&blank_verdict(raw, iso));
    0
}

pub fn burn(iso: &str, raw_dev: &str, argv: &[String]) -> i32 {
    let mut dev = resolve_dev(raw_dev);
    if let Some(d) = &dev {
        if let Some(rc) = maybe_newgrp_wrap(d, argv) {
            return rc;
        }
    }
    become_session_leader();
    if dev.is_none() {
        dev = resolve_dev("");
    }
    let iso_path = Path::new(iso);
    if iso_path.is_symlink() || !iso_path.is_file() {
        return fail("iso-not-found");
    }
    if !iso_is_safe_output(iso_path) {
        return fail("iso-unsafe-path");
    }
    let Some(dev) = dev else {
        return fail("no-dvd-drive");
    };
    let Some(dev) = require_optical_dev(&dev, None) else {
        return fail("invalid-device");
    };
    let Some(iso_fp) = iso_fingerprint(iso_path) else {
        return fail("iso-unsafe-path");
    };
    let Some(dev_ident) = optical_dev_identity(&dev) else {
        return fail("invalid-device");
    };

    let rt = match Runtime::init() {
        Ok(rt) => rt,
        Err(_) => return fail("runtime-state"),
    };
    if rt.setup_job().is_err() {
        return fail("runtime-state");
    }
    if let Err(err) = rt.claim_job(Phase::Burn, "", iso, &dev) {
        rt.clear_pgid();
        return fail(err);
    }
    rt.append_log(&format!("=== oma-dvd burn ===\niso={iso}\ndev={dev}\npgid={}", std::process::id()));

    emit("PROGRESS:BURN:start");
    let _ = run_deadline(5, cmd("udevadm", &["settle", "--timeout=5"]));
    std::thread::sleep(Duration::from_secs(2));

    let Some(dev) = require_optical_dev(&dev, Some(&dev_ident)) else {
        rt.clear_pgid();
        return fail("invalid-device");
    };

    let mut grow = Command::new("growisofs");
    grow.args(["-use-the-force-luke=tty", "-dvd-compat", "-Z", &format!("{dev}={iso}")]);
    grow.stdout(Stdio::null()).stderr(Stdio::piped());
    let rc = match grow.spawn() {
        Ok(mut child) => {
            let stderr = child.stderr.take();
            let deadline = Instant::now() + Duration::from_secs(TIMEOUT_GROWISOFS);
            let mut retained = String::new();
            if let Some(s) = stderr {
                pump_growisofs_stderr(s, &rt, &mut retained, &mut child, deadline);
            }
            if Instant::now() > deadline {
                124
            } else if CANCELLED.load(std::sync::atomic::Ordering::Relaxed) {
                143
            } else {
                let code = child.wait().ok().and_then(|s| s.code()).unwrap_or(1);
                if retained.to_ascii_lowercase().contains("no media mounted")
                    || retained.to_ascii_lowercase().contains("unable to open")
                {
                    1
                } else {
                    code
                }
            }
        }
        Err(_) => 1,
    };

    if rc == 124 || rc == 137 {
        rt.job_fail("timeout");
        rt.clear_pgid();
        return fail("timeout");
    }
    if rc == 143 {
        rt.job_fail("cancelled");
        rt.clear_pgid();
        return fail("cancelled");
    }
    if rc != 0 {
        rt.job_fail("burn-failed");
        rt.clear_pgid();
        return fail("burn-failed");
    }
    let _ = try_eject(&dev, &rt);
    let _ = safe_unlink_iso(iso_path, Some(&iso_fp));
    rt.job_done();
    rt.clear_pgid();
    crate::setup::play_event_sound("complete");
    emit(&format!("RESULT:BURNED:{iso}"));
    0
}

fn note_burn_line(rt: &Runtime, retained: &mut String, line: &str) {
    rt.append_log(line);
    if retained.len() < 65_536 {
        retained.push_str(line);
        retained.push('\n');
    }
    emit(&format!("PROGRESS:BURN:{line}"));
    if let Some(pct) = burn_percent(line) {
        rt.job_progress(pct, "burning");
    }
}

fn pump_growisofs_stderr(
    mut stream: std::process::ChildStderr,
    rt: &Runtime,
    retained: &mut String,
    child: &mut std::process::Child,
    deadline: Instant,
) {
    let mut buf = [0u8; 512];
    let mut line = Vec::new();
    loop {
        if CANCELLED.load(std::sync::atomic::Ordering::Relaxed) || Instant::now() > deadline {
            let _ = child.kill();
            kill_group_children();
            break;
        }
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                for text in take_progress_lines(&buf[..n], &mut line) {
                    note_burn_line(rt, retained, &text);
                }
            }
            Err(_) => break,
        }
    }
    if let Some(text) = finish_progress_line(&mut line) {
        note_burn_line(rt, retained, &text);
    }
}

/// Flush complete growisofs progress frames. Updates often use `\r` (TTY overwrite);
/// some builds use `\n` only. Splitting on just one of those left the bar at 0%
/// until the burn finished.
fn take_progress_lines(chunk: &[u8], pending: &mut Vec<u8>) -> Vec<String> {
    let mut out = Vec::new();
    for &b in chunk {
        if b == b'\r' || b == b'\n' {
            if let Some(text) = finish_progress_line(pending) {
                out.push(text);
            }
        } else if pending.len() < 4096 {
            pending.push(b);
        }
    }
    out
}

fn finish_progress_line(pending: &mut Vec<u8>) -> Option<String> {
    if pending.is_empty() {
        return None;
    }
    let text = String::from_utf8_lossy(pending).trim().to_string();
    pending.clear();
    if text.is_empty() {
        None
    } else {
        Some(text)
    }
}

fn percent_from_float(p: f32) -> i32 {
    let mut n = p.round().clamp(0.0, 100.0) as i32;
    if p > 0.0 && n == 0 {
        n = 1;
    }
    n
}

fn burn_percent(line: &str) -> Option<i32> {
    if let Some(start) = line.find('(') {
        if let Some(end) = line[start + 1..].find('%') {
            if let Ok(p) = line[start + 1..start + 1 + end].trim().parse::<f32>() {
                return Some(percent_from_float(p));
            }
        }
    }
    let bytes = line.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i > 0 {
            let mut j = i;
            while j > 0 && bytes[j - 1].is_ascii_whitespace() {
                j -= 1;
            }
            let end = j;
            while j > 0 && (bytes[j - 1].is_ascii_digit() || bytes[j - 1] == b'.') {
                j -= 1;
            }
            if j < end {
                if let Ok(p) = line[j..end].parse::<f32>() {
                    return Some(percent_from_float(p));
                }
            }
        }
        i += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn burn_percent_paren() {
        assert_eq!(
            burn_percent("4194304/2297888768 ( 5.2%) @0.5x, remaining 12:34"),
            Some(5)
        );
        assert_eq!(burn_percent("4194304/100 ( 0.2%) @0.5x"), Some(1));
        assert_eq!(burn_percent("PROGRESS:BURN:start"), None);
    }

    #[test]
    fn burn_percent_plain() {
        assert_eq!(burn_percent("Track 01 progress:  45%"), Some(45));
        assert_eq!(burn_percent("98.7% done"), Some(99));
    }

    fn percents_from(chunk: &[u8], pending: &mut Vec<u8>) -> Vec<i32> {
        take_progress_lines(chunk, pending)
            .iter()
            .filter_map(|line| burn_percent(line))
            .collect()
    }

    #[test]
    fn burn_progress_moves_on_newlines_before_eof() {
        // growisofs sometimes prints `\n` only. Waiting for `\r` (or EOF) kept
        // job.progress at 0% for the whole burn.
        let mut pending = Vec::new();
        let percents = percents_from(
            b"4194304/2297888768 ( 5.2%) @0.5x, remaining 12:34\n\
              4194304/2297888768 ( 12.0%) @0.5x, remaining 10:01\n",
            &mut pending,
        );
        assert_eq!(percents, vec![5, 12]);
        assert!(pending.is_empty());
        assert!(finish_progress_line(&mut pending).is_none());
    }

    #[test]
    fn burn_progress_moves_on_carriage_returns() {
        let mut pending = Vec::new();
        let percents = percents_from(
            b"4194304/100 ( 0.2%) @0.5x\r4194304/100 ( 40.0%) @0.5x\r",
            &mut pending,
        );
        assert_eq!(percents, vec![1, 40]);
    }

    #[test]
    fn burn_progress_moves_when_percent_splits_across_reads() {
        let mut pending = Vec::new();
        assert!(percents_from(b"4194304/100 ( 8.1%", &mut pending).is_empty());
        assert_eq!(percents_from(b"%) @0.5x\n", &mut pending), vec![8]);
    }
}

