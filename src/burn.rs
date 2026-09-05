use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::classify::{classify_blank, classify_udev_props, iso_size_of};
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

pub fn check_blank(raw: &str, iso: &str) -> i32 {
    let Some(dev) = resolve_dev(raw) else {
        emit("BLANK:NONE");
        return 0;
    };
    let iso_size = if !iso.is_empty() {
        iso_size_of(Path::new(iso))
    } else {
        None
    };
    let rt = Runtime::init().ok();
    let Some(dev) = require_optical_dev(&dev, None) else {
        emit("BLANK:NONE");
        return 0;
    };
    let props = capture_limited(5, cmd("udevadm", &["info", "--query=property", &dev]));
    if !props.is_empty() {
        let verdict = classify_udev_props(&props, iso_size);
        if let Some(rt) = &rt {
            rt.append_log(&format!("UDEV:{verdict}"));
        }
        if matches!(verdict, "BLANK:YES" | "BLANK:NO" | "BLANK:TOO_SMALL") {
            emit(verdict);
            return 0;
        }
    }
    let info = capture_limited(TIMEOUT_MEDIAINFO, cmd("dvd+rw-mediainfo", &[&dev]));
    if let Some(rt) = &rt {
        rt.append_log(&info);
    }
    emit(classify_blank(&info, iso_size));
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
    grow.stdout(Stdio::piped()).stderr(Stdio::piped());
    let rc = match grow.spawn() {
        Ok(mut child) => {
            let stderr = child.stderr.take();
            let stdout = child.stdout.take();
            let deadline = Instant::now() + Duration::from_secs(TIMEOUT_GROWISOFS);
            let mut retained = String::new();
            let mut pump = |stream: Option<std::process::ChildStderr>| {
                if let Some(s) = stream {
                    let reader = BufReader::new(s);
                    for chunk in reader.split(b'\r') {
                        let Ok(b) = chunk else { break };
                        for line in String::from_utf8_lossy(&b).split('\n') {
                            let line = line.trim();
                            if line.is_empty() {
                                continue;
                            }
                            rt.append_log(line);
                            if retained.len() < 65_536 {
                                retained.push_str(line);
                                retained.push('\n');
                            }
                            emit(&format!("PROGRESS:BURN:{line}"));
                        }
                        if CANCELLED.load(std::sync::atomic::Ordering::Relaxed) || Instant::now() > deadline {
                            let _ = child.kill();
                            kill_group_children();
                            break;
                        }
                    }
                }
            };
            // growisofs writes progress on stderr
            let _ = stdout;
            pump(stderr);
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
        rt.clear_pgid();
        return fail("timeout");
    }
    if rc == 143 {
        rt.clear_pgid();
        return fail("cancelled");
    }
    if rc != 0 {
        rt.clear_pgid();
        return fail("burn-failed");
    }
    let _ = try_eject(&dev, &rt);
    let _ = safe_unlink_iso(iso_path, Some(&iso_fp));
    rt.clear_pgid();
    crate::setup::play_event_sound("complete");
    emit(&format!("RESULT:BURNED:{iso}"));
    0
}

