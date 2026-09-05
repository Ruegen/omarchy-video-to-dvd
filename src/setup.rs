use std::process::{Command, Stdio};

use crate::protocol::{emit, fail};
use crate::security::{
    drive_is_writable, emit_drives, first_dvd_dev, have_cmd, in_optical_group, list_optical_drives,
    pacman_has, whoami,
};

pub fn play_event_sound(id: &str) {
    if have_cmd("canberra-gtk-play") {
        if Command::new("canberra-gtk-play")
            .args(["-i", id])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
        {
            return;
        }
    }
    let file = format!("/usr/share/sounds/freedesktop/stereo/{id}.oga");
    if !std::path::Path::new(&file).is_file() {
        return;
    }
    for (bin, args) in [
        ("mpv", vec!["--no-video", "--really-quiet", file.as_str()]),
        ("paplay", vec![file.as_str()]),
        ("pw-play", vec![file.as_str()]),
    ] {
        if have_cmd(bin)
            && Command::new(bin)
                .args(args)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false)
        {
            return;
        }
    }
}

pub fn notify(title: &str, body: &str, sound: &str) -> i32 {
    if title.is_empty() {
        return 0;
    }
    if have_cmd("omarchy-notification-send") {
        let _ = Command::new("omarchy-notification-send")
            .args(["--app-name", "Video to DVD", "-u", "normal", title, body])
            .status();
    } else if have_cmd("notify-send") {
        let _ = Command::new("notify-send")
            .args(["--app-name", "Video to DVD", "-u", "normal", title, body])
            .status();
    }
    if !sound.is_empty() {
        play_event_sound(sound);
    }
    0
}

fn pkg_missing() -> Vec<&'static str> {
    let mut missing = Vec::new();
    if !have_cmd("ffmpeg") && !pacman_has("ffmpeg") {
        missing.push("ffmpeg");
    }
    if !have_cmd("dvdauthor") && !pacman_has("dvdauthor") {
        missing.push("dvdauthor");
    }
    if !have_cmd("genisoimage") && !have_cmd("mkisofs") && !pacman_has("cdrtools") {
        missing.push("cdrtools");
    }
    if !have_cmd("growisofs") && !pacman_has("dvd+rw-tools") {
        missing.push("dvd+rw-tools");
    }
    if !have_cmd("eject") && !pacman_has("util-linux") {
        missing.push("util-linux");
    }
    missing
}

fn drive_access_status() -> &'static str {
    let drives = list_optical_drives();
    if drives.is_empty() {
        return "none";
    }
    if drive_is_writable(&drives[0].path) || in_optical_group() {
        "ok"
    } else {
        "need-permission"
    }
}

pub fn check_setup() -> i32 {
    emit(&format!("MISSING:{}", pkg_missing().join(",")));
    emit_drives();
    emit(&format!("DRIVE:{}", drive_access_status()));
    0
}

pub fn list_drives() -> i32 {
    emit_drives();
    0
}

fn launch_setup_terminal(cmd: &str) {
    let presentation = format!(
        "omarchy-show-logo; {cmd}; if (( $? != 130 )); then omarchy-show-done; fi"
    );
    emit(&format!("SETUP:CMD:{cmd}"));
    if std::env::var("VIDEO_TO_DVD_DRY_RUN").ok().as_deref() == Some("1") {
        emit(&format!("DRY-RUN: xdg-terminal-exec --app-id=org.omarchy.terminal --title=Omarchy -e bash -c {presentation}"));
        return;
    }
    let _ = Command::new("xdg-terminal-exec")
        .args([
            "--app-id=org.omarchy.terminal",
            "--title=Omarchy",
            "-e",
            "bash",
            "-c",
            &presentation,
        ])
        .status();
}

pub fn install_packages() -> i32 {
    let missing = pkg_missing();
    if missing.is_empty() {
        emit("SETUP:OK:packages-present");
        return 0;
    }
    let pkgs = missing.join(" ");
    emit(&format!("SETUP:INSTALLING:{pkgs}"));
    launch_setup_terminal(&format!("echo 'Installing packages...'; omarchy-pkg-add {pkgs}"));
    emit("SETUP:DONE");
    0
}

pub fn add_optical() -> i32 {
    let user = whoami();
    if !user
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
    {
        return fail("invalid-user");
    }
    if let Some(dev) = first_dvd_dev() {
        if drive_is_writable(&dev) || in_optical_group() {
            emit("SETUP:OK:drive-ready");
            return 0;
        }
    } else if in_optical_group() {
        emit("SETUP:OK:drive-ready");
        return 0;
    }
    emit(&format!("SETUP:DRIVE:{user}"));
    launch_setup_terminal(&format!(
        "echo 'Allowing this account to use the DVD drive...'; sudo usermod -aG optical {user}"
    ));
    emit("SETUP:DONE");
    0
}
