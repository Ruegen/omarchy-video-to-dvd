use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use crate::burn::{blank_verdict, burn, eject};
use crate::convert::{self, convert};
use crate::job::{self, Phase};
use crate::protocol::{emit, fail, printable};
use crate::security::{have_cmd, Runtime, CANCELLED};

const VIDEO_EXTS: &str = "mp4 mkv mov avi webm m4v ts mts m2ts wmv flv";
const PICK_TIMEOUT_SECS: u64 = 610;
const PATH_MAX: usize = 4096;

pub fn help() -> i32 {
    emit(
        "\
Video to DVD — convert a video and burn a DVD-Video disc.

Usage:
  oma-dvd make [video] [--standard PAL|NTSC] [--device /dev/sr0]
  oma-dvd pick
  oma-dvd status
  oma-dvd cancel
  oma-dvd --help

make     Convert, wait for a blank disc, burn, then eject.
         Omit the video to open the same file chooser as the bar.
pick     Open the file chooser and print the selected video path.
status   Show the current job (the bar panel shows the same job).
cancel   Stop the current job. Same as Cancel in the panel.

When make asks you to insert a disc, put a blank DVD in and close the tray.
You can cancel from the panel or with oma-dvd cancel — both stop the same job.

Examples:
  oma-dvd make
  oma-dvd make ~/Videos/film.mp4
  oma-dvd pick
  oma-dvd make ~/Videos/film.mp4 --standard NTSC
",
    );
    0
}

fn arg_eq(a: &str, flag: &str) -> bool {
    a == flag
}

pub fn pick() -> i32 {
    match pick_video() {
        Ok(path) => {
            emit(&path);
            0
        }
        Err(rc) => rc,
    }
}

pub fn make(args: &[String]) -> i32 {
    crate::security::install_cancel_flag();
    std::env::set_var("VIDEO_TO_DVD_SOURCE", "cli");

    let mut video = String::new();
    let mut standard = String::new();
    let mut device = String::new();
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if arg_eq(a, "--standard") {
            i += 1;
            if i >= args.len() {
                return fail("input-not-found");
            }
            standard = args[i].clone();
        } else if arg_eq(a, "--device") {
            i += 1;
            if i >= args.len() {
                return fail("invalid-device");
            }
            device = args[i].clone();
        } else if a.starts_with('-') {
            return fail("input-not-found");
        } else if video.is_empty() {
            video = a.clone();
        } else {
            return fail("input-not-found");
        }
        i += 1;
    }
    if video.is_empty() {
        emit("MESSAGE:Pick a video in the file chooser.");
        match pick_video() {
            Ok(path) => video = path,
            Err(rc) => return rc,
        }
    } else {
        video = expand_home(&video);
    }
    if !standard.is_empty() {
        std::env::set_var("VIDEO_TO_DVD_STANDARD", standard);
    }

    let mut wrap_args = vec!["make".into()];
    wrap_args.extend(args.iter().cloned());
    if let Some(dev) = crate::security::resolve_dev(&device) {
        if let Some(rc) = crate::security::maybe_newgrp_wrap(&dev, &wrap_args) {
            return rc;
        }
    }
    std::env::set_var("VIDEO_TO_DVD_NEWGRP", "1");

    let iso = derived_iso(&video);
    emit(&format!("MAKE:convert:{video}"));
    let rc = convert(&video, &iso);
    if rc != 0 {
        return rc;
    }
    if job_cancelled() {
        return fail("cancelled");
    }

    let Ok(rt) = Runtime::init() else {
        return fail("runtime-state");
    };
    rt.patch_job(|j| {
        j.phase = Phase::Wait;
        j.status = "insert-blank".into();
        j.progress = 0;
        j.iso = iso.clone();
        j.input = video.clone();
        j.device = device.clone();
        j.pid = std::process::id();
        j.pgid = std::process::id();
        j.source = "cli".into();
    });

    let eject_args = vec!["eject".into(), device.clone()];
    let _ = eject(&device, &eject_args);
    emit("HINT:insert-blank-dvd");
    emit("MESSAGE:Insert a blank DVD, then close the tray.");

    let deadline = Instant::now() + Duration::from_secs(7200);
    loop {
        if job_cancelled() {
            rt.patch_job(|j| {
                j.phase = Phase::Cancelled;
                j.status = "cancelled".into();
            });
            return fail("cancelled");
        }
        if Instant::now() > deadline {
            rt.job_fail("timeout");
            return fail("timeout");
        }
        let verdict = blank_verdict(&device, &iso);
        emit(&verdict);
        match verdict.as_str() {
            "BLANK:YES" => break,
            "BLANK:TOO_SMALL" => emit("MESSAGE:That disc is too small. Insert a higher-capacity blank DVD."),
            "BLANK:NO" => emit("MESSAGE:That disc is not blank. Insert a blank DVD."),
            _ => emit("MESSAGE:Insert a blank DVD, then close the tray."),
        }
        thread::sleep(Duration::from_secs(3));
        rt.patch_job(|_| {});
    }

    if job_cancelled() {
        return fail("cancelled");
    }
    emit("MAKE:burn");
    let burn_args = vec!["burn".into(), iso.clone(), device.clone()];
    let rc = burn(&iso, &device, &burn_args);
    if rc == 0 {
        if let Ok(rt) = Runtime::init() {
            rt.job_done();
        }
    }
    rc
}

fn pick_video() -> Result<String, i32> {
    if !have_cmd("omarchy-file-select") {
        return Err(fail("picker-failed"));
    }
    let mut cmd = Command::new("omarchy-file-select");
    cmd.args(["--title", "Select video", "--extensions", VIDEO_EXTS]);
    cmd.stdout(Stdio::piped()).stderr(Stdio::null());
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(_) => return Err(fail("picker-failed")),
    };
    let stdout = child.stdout.take();
    let started = Instant::now();
    loop {
        if let Ok(Some(status)) = child.try_wait() {
            let raw = if let Some(out) = stdout {
                let mut first = String::new();
                let _ = BufReader::new(out).read_line(&mut first);
                first
            } else {
                String::new()
            };
            if !status.success() {
                return Err(fail("input-not-found"));
            }
            return accept_picked(&raw);
        }
        if started.elapsed() >= Duration::from_secs(PICK_TIMEOUT_SECS) {
            let _ = child.kill();
            let _ = child.wait();
            return Err(fail("timeout"));
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn accept_picked(raw: &str) -> Result<String, i32> {
    let path = parse_picked_path(raw);
    if path.is_empty() || path.len() > PATH_MAX {
        return Err(fail("input-not-found"));
    }
    let p = Path::new(&path);
    if p.is_symlink() || !p.is_file() || !convert::is_supported_input(&path) {
        return Err(fail("unsupported-format"));
    }
    Ok(path)
}

pub(crate) fn parse_picked_path(raw: &str) -> String {
    let mut s = printable(raw).trim().to_string();
    if s.len() > PATH_MAX {
        s.truncate(PATH_MAX);
    }
    if let Some(rest) = s.strip_prefix("file://") {
        s = rest.to_string();
        if let Some(rest) = s.strip_prefix("localhost") {
            s = rest.to_string();
        }
        if let Ok(decoded) = percent_decode(&s) {
            s = decoded;
        }
    }
    expand_home(&s)
}

fn percent_decode(s: &str) -> Result<String, ()> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hi = from_hex(bytes[i + 1])?;
            let lo = from_hex(bytes[i + 2])?;
            out.push((hi << 4) | lo);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).map_err(|_| ())
}

fn from_hex(b: u8) -> Result<u8, ()> {
    match b {
        b'0'..=b'9' => Ok(b - b'0'),
        b'a'..=b'f' => Ok(b - b'a' + 10),
        b'A'..=b'F' => Ok(b - b'A' + 10),
        _ => Err(()),
    }
}

fn expand_home(path: &str) -> String {
    if path == "~" || path.starts_with("~/") {
        if let Ok(home) = std::env::var("HOME") {
            if path == "~" {
                return home;
            }
            return format!("{home}{}", &path[1..]);
        }
    }
    path.to_string()
}

fn derived_iso(video: &str) -> String {
    let path = Path::new(video);
    match path.extension() {
        Some(_) => path.with_extension("iso").display().to_string(),
        None => format!("{video}.iso"),
    }
}

fn job_cancelled() -> bool {
    if CANCELLED.load(std::sync::atomic::Ordering::Relaxed) {
        return true;
    }
    Runtime::init().ok().is_some_and(|rt| job::cancelled(&rt))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_file_uri() {
        assert_eq!(
            parse_picked_path("file:///home/ruegen/Videos/film.mp4\n"),
            "/home/ruegen/Videos/film.mp4"
        );
    }

    #[test]
    fn percent_decodes_spaces() {
        assert_eq!(
            parse_picked_path("file:///home/a/My%20Film.mkv"),
            "/home/a/My Film.mkv"
        );
    }

    #[test]
    fn drops_control_chars() {
        assert_eq!(parse_picked_path("/tmp/hi\u{0007}.mp4"), "/tmp/hi.mp4");
    }
}
