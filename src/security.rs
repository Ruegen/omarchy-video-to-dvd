use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use libc::{O_NOFOLLOW, S_IFBLK, S_IFMT};

use crate::protocol::{emit, printable};

pub const MAX_LOG_BYTES: u64 = 1_048_576;
pub const MAX_CAPTURE_BYTES: usize = 65_536;
pub const TIMEOUT_FFPROBE: u64 = 30;
pub const TIMEOUT_FFMPEG: u64 = 28_800;
pub const TIMEOUT_DVDAUTHOR: u64 = 1_800;
pub const TIMEOUT_GENISO: u64 = 1_800;
pub const TIMEOUT_GROWISOFS: u64 = 7_200;
pub const TIMEOUT_EJECT: u64 = 30;
pub const TIMEOUT_MEDIAINFO: u64 = 8;

pub static CANCELLED: AtomicBool = AtomicBool::new(false);

pub fn current_uid() -> u32 {
    unsafe { libc::geteuid() }
}

pub fn install_cancel_flag() {
    let flag = Arc::new(AtomicBool::new(false));
    let _ = signal_hook::flag::register(signal_hook::consts::SIGTERM, Arc::clone(&flag));
    let _ = signal_hook::flag::register(signal_hook::consts::SIGINT, Arc::clone(&flag));
    let _ = signal_hook::flag::register(signal_hook::consts::SIGHUP, Arc::clone(&flag));
    thread::spawn(move || loop {
        if flag.load(Ordering::Relaxed) {
            CANCELLED.store(true, Ordering::Relaxed);
            kill_group_children();
            break;
        }
        thread::sleep(Duration::from_millis(50));
    });
}

pub fn become_session_leader() {
    if std::env::var_os("VIDEO_TO_DVD_SESSION").is_some() {
        return;
    }
    unsafe {
        if libc::setsid() < 0 {
            let _ = libc::setpgid(0, 0);
        }
    }
    std::env::set_var("VIDEO_TO_DVD_SESSION", "1");
}

pub fn kill_group_children() {
    let me = std::process::id();
    let out = Command::new("pgrep").args(["-g", &me.to_string()]).output();
    let Ok(out) = out else { return };
    for pid in String::from_utf8_lossy(&out.stdout).lines() {
        if let Ok(p) = pid.trim().parse::<i32>() {
            if p as u32 != me {
                unsafe {
                    libc::kill(p, libc::SIGTERM);
                }
            }
        }
    }
    thread::sleep(Duration::from_millis(150));
    let out = Command::new("pgrep").args(["-g", &me.to_string()]).output();
    if let Ok(out) = out {
        for pid in String::from_utf8_lossy(&out.stdout).lines() {
            if let Ok(p) = pid.trim().parse::<i32>() {
                if p as u32 != me {
                    unsafe {
                        libc::kill(p, libc::SIGKILL);
                    }
                }
            }
        }
    }
}

pub struct Runtime {
    pub dir: PathBuf,
    pub log: PathBuf,
    pub pgid: PathBuf,
}

impl Runtime {
    pub fn init() -> io::Result<Self> {
        let candidate = if let Ok(dir) = std::env::var("VIDEO_TO_DVD_RUNTIME_DIR") {
            Some(PathBuf::from(dir))
        } else if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
            let xdg = PathBuf::from(xdg);
            if xdg.is_dir() && !xdg.is_symlink() {
                Some(xdg.join("video-to-dvd"))
            } else {
                None
            }
        } else {
            None
        };

        let dir = match candidate {
            Some(c) => prepare_runtime_dir(&c).or_else(|_| random_runtime_dir())?,
            None => random_runtime_dir()?,
        };
        let log = env_or_inside("VIDEO_TO_DVD_LOG", &dir, "convert.log");
        let pgid = env_or_inside("VIDEO_TO_DVD_PGID_FILE", &dir, "job.pgid");
        safe_create_file(&log)?;
        safe_create_file(&pgid)?;
        Ok(Self { dir, log, pgid })
    }

    pub fn setup_job(&self) -> io::Result<()> {
        write_nofollow(&self.pgid, format!("{}\n", std::process::id()).as_bytes())?;
        emit(&format!("PGID:{}", std::process::id()));
        Ok(())
    }

    pub fn append_log(&self, text: &str) {
        append_log_path(&self.log, text);
        self.enforce_log_bound();
    }

    pub fn enforce_log_bound(&self) {
        if self.log.is_symlink() {
            return;
        }
        let Ok(mut f) = open_nofollow(&self.log, OpenMode::Read) else { return };
        let mut data = Vec::new();
        if f.read_to_end(&mut data).is_err() {
            return;
        }
        if (data.len() as u64) <= MAX_LOG_BYTES {
            return;
        }
        let keep = (MAX_LOG_BYTES / 2) as usize;
        let start = data.len().saturating_sub(keep);
        let tmp = self.dir.join(".convert.log.trim");
        if tmp.is_symlink() {
            let _ = fs::remove_file(&tmp);
        }
        let _ = fs::remove_file(&tmp);
        if safe_create_file(&tmp).is_err() {
            return;
        }
        if write_nofollow(&tmp, &data[start..]).is_err() {
            let _ = fs::remove_file(&tmp);
            return;
        }
        if tmp.is_symlink() || self.log.is_symlink() {
            let _ = fs::remove_file(&tmp);
            return;
        }
        let _ = fs::rename(&tmp, &self.log);
        let _ = fs::set_permissions(&self.log, fs::Permissions::from_mode(0o600));
    }

    pub fn clear_pgid(&self) {
        let _ = fs::remove_file(&self.pgid);
    }
}

enum OpenMode {
    Read,
    Append,
    WriteTrunc,
}

fn open_nofollow(path: &Path, mode: OpenMode) -> io::Result<fs::File> {
    if path.is_symlink() {
        return Err(io::Error::other("symlink"));
    }
    let mut opts = OpenOptions::new();
    opts.create(false).custom_flags(O_NOFOLLOW);
    match mode {
        OpenMode::Read => {
            opts.read(true);
        }
        OpenMode::Append => {
            opts.write(true).append(true);
        }
        OpenMode::WriteTrunc => {
            opts.write(true).truncate(true);
        }
    }
    opts.open(path)
}

fn write_nofollow(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut f = open_nofollow(path, OpenMode::WriteTrunc)?;
    f.write_all(bytes)
}

fn append_log_path(log: &Path, text: &str) {
    if log.is_symlink() {
        return;
    }
    let Ok(meta) = fs::metadata(log) else { return };
    if !meta.is_file() || meta.len() >= MAX_LOG_BYTES {
        return;
    }
    let Ok(mut f) = open_nofollow(log, OpenMode::Append) else { return };
    let _ = f.write_all(text.as_bytes());
    if !text.ends_with('\n') {
        let _ = f.write_all(b"\n");
    }
}

fn random_runtime_dir() -> io::Result<PathBuf> {
    let dir = tempfile::Builder::new().prefix("oma-dvd.").tempdir()?.keep();
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
    if runtime_dir_ok(&dir) {
        Ok(dir)
    } else {
        Err(io::Error::other("runtime dir unsafe"))
    }
}

fn env_or_inside(var: &str, dir: &Path, name: &str) -> PathBuf {
    if let Ok(p) = std::env::var(var) {
        let p = PathBuf::from(p);
        if p.starts_with(dir) {
            return p;
        }
    }
    dir.join(name)
}

fn runtime_dir_ok(dir: &Path) -> bool {
    if !dir.is_dir() || dir.is_symlink() {
        return false;
    }
    let Ok(meta) = fs::metadata(dir) else { return false };
    meta.uid() == current_uid() && meta.mode() & 0o777 == 0o700
}

fn prepare_runtime_dir(candidate: &Path) -> io::Result<PathBuf> {
    if candidate.is_symlink() || candidate.parent().is_none_or(|p| !p.is_dir()) {
        let dir = tempfile::Builder::new().prefix("video-to-dvd.").tempdir()?.keep();
        let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));
        return if runtime_dir_ok(&dir) {
            Ok(dir)
        } else {
            Err(io::Error::other("runtime dir unsafe"))
        };
    }
    if !candidate.exists() {
        if let Err(e) = fs::create_dir(candidate) {
            let dir = tempfile::Builder::new().prefix("video-to-dvd.").tempdir()?.keep();
            let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));
            return if runtime_dir_ok(&dir) {
                Ok(dir)
            } else {
                Err(e)
            };
        }
        let _ = fs::set_permissions(candidate, fs::Permissions::from_mode(0o700));
    }
    if runtime_dir_ok(candidate) {
        Ok(candidate.to_path_buf())
    } else {
        Err(io::Error::other("runtime dir unsafe"))
    }
}

pub fn safe_create_file(path: &Path) -> io::Result<()> {
    if path.is_symlink() {
        fs::remove_file(path)?;
    }
    if path.exists() {
        let meta = fs::metadata(path)?;
        if !meta.is_file() || path.is_symlink() {
            return Err(io::Error::other("not a regular file"));
        }
        if meta.uid() != current_uid() {
            return Err(io::Error::other("wrong owner"));
        }
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
        return Ok(());
    }
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(O_NOFOLLOW)
        .open(path);
    match file {
        Ok(_) => Ok(()),
        Err(e) => Err(e),
    }
}

pub fn optical_dev_path_ok(path: &str) -> bool {
    let rest = match path.strip_prefix("/dev/sr") {
        Some(r) => r,
        None => return false,
    };
    !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit())
}

pub fn lsblk_kv(line: &str, key: &str) -> String {
    let needle = format!("{key}=\"");
    if let Some(i) = line.find(&needle) {
        let rest = &line[i + needle.len()..];
        if let Some(end) = rest.find('"') {
            return rest[..end].to_string();
        }
    }
    String::new()
}

fn is_block(path: &Path) -> bool {
    fs::metadata(path)
        .map(|m| m.mode() & S_IFMT == S_IFBLK)
        .unwrap_or(false)
}

pub fn optical_dev_identity(dev: &str) -> Option<String> {
    if !optical_dev_path_ok(dev) || !is_block(Path::new(dev)) {
        return None;
    }
    let meta = fs::metadata(dev).ok()?;
    let majmin = format!("{}:{}", libc_major(meta.rdev()), libc_minor(meta.rdev()));
    if majmin == "0:0" {
        return None;
    }
    let props = capture_limited(5, cmd("udevadm", &["info", "--query=property", dev]));
    let devpath = props
        .lines()
        .find_map(|l| l.strip_prefix("DEVPATH="))
        .unwrap_or("")
        .to_string();
    Some(format!("{majmin}\t{devpath}"))
}

fn libc_major(dev: u64) -> u32 {
    ((dev >> 8) & 0xfff) as u32 | (((dev >> 32) & 0xfffff000) as u32)
}

fn libc_minor(dev: u64) -> u32 {
    (dev & 0xff) as u32 | (((dev >> 12) & 0xffffff00) as u32)
}

pub fn validate_optical_dev(raw: &str) -> Option<String> {
    if !optical_dev_path_ok(raw) {
        return None;
    }
    let mut path = raw.to_string();
    let p = Path::new(&path);
    if p.is_symlink() {
        let canon = fs::canonicalize(p).ok()?;
        let s = canon.to_string_lossy().into_owned();
        if !optical_dev_path_ok(&s) {
            return None;
        }
        path = s;
    }
    let p = Path::new(&path);
    if !is_block(p) || p.is_symlink() {
        return None;
    }
    let line = capture_limited(5, cmd("lsblk", &["-d", "-n", "-P", "-o", "NAME,TYPE", &path]));
    if line.trim().is_empty() {
        return None;
    }
    let typ = lsblk_kv(line.trim(), "TYPE");
    let name = lsblk_kv(line.trim(), "NAME");
    if typ != "rom" || !name.starts_with("sr") || !name[2..].chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    if format!("/dev/{name}") != path {
        return None;
    }
    let props = capture_limited(5, cmd("udevadm", &["info", "--query=property", &path]));
    if !udev_says_optical(&props) {
        return None;
    }
    Some(path)
}

pub fn udev_says_optical(props: &str) -> bool {
    !props.is_empty()
        && (props.lines().any(|l| l == "ID_CDROM=1") || props.lines().any(|l| l == "ID_TYPE=cd"))
}

pub fn require_optical_dev(raw: &str, expected: Option<&str>) -> Option<String> {
    let got = validate_optical_dev(raw)?;
    if let Some(exp) = expected {
        let ident = optical_dev_identity(&got)?;
        if ident != exp {
            return None;
        }
    }
    Some(got)
}

pub fn iso_is_safe_output(path: &Path) -> bool {
    if path.as_os_str().is_empty() || path == Path::new("-") {
        return false;
    }
    if path.is_symlink() || path.is_dir() {
        return false;
    }
    if path.exists() {
        let Ok(meta) = fs::metadata(path) else { return false };
        if !meta.is_file() || meta.uid() != current_uid() {
            return false;
        }
    }
    path.parent().is_some_and(|p| p.is_dir())
}

pub fn iso_fingerprint(path: &Path) -> Option<String> {
    if path.is_symlink() || !path.is_file() {
        return None;
    }
    let meta = fs::metadata(path).ok()?;
    if meta.uid() != current_uid() {
        return None;
    }
    Some(format!("{}:{}:{}", meta.dev(), meta.ino(), meta.uid()))
}

pub fn install_iso_output(src: &Path, dest: &Path) -> io::Result<()> {
    if src.is_symlink() || !src.is_file() {
        return Err(io::Error::other("src unsafe"));
    }
    if fs::metadata(src)?.uid() != current_uid() {
        return Err(io::Error::other("src owner"));
    }
    if !iso_is_safe_output(dest) || dest.is_symlink() {
        return Err(io::Error::other("dest unsafe"));
    }
    if dest.exists() {
        let meta = fs::metadata(dest)?;
        if !meta.is_file() || meta.uid() != current_uid() {
            return Err(io::Error::other("dest unsafe"));
        }
        fs::remove_file(dest)?;
        if dest.exists() || dest.is_symlink() {
            return Err(io::Error::other("dest reappeared"));
        }
    }
    fs::rename(src, dest)?;
    if dest.is_symlink() || !dest.is_file() {
        return Err(io::Error::other("rename followed"));
    }
    Ok(())
}

pub fn safe_unlink_iso(path: &Path, expected: Option<&str>) -> io::Result<()> {
    if path.is_symlink() || !path.is_file() {
        return Err(io::Error::other("not a regular file"));
    }
    let meta = fs::metadata(path)?;
    if meta.uid() != current_uid() {
        return Err(io::Error::other("wrong owner"));
    }
    let fp = format!("{}:{}:{}", meta.dev(), meta.ino(), meta.uid());
    if let Some(exp) = expected {
        if fp != exp {
            return Err(io::Error::other("fingerprint mismatch"));
        }
    }
    fs::remove_file(path)
}

pub fn cmd(bin: &str, args: &[&str]) -> Command {
    let mut c = Command::new(bin);
    c.args(args);
    c
}

fn wait_deadline(child: &mut std::process::Child, secs: u64) -> io::Result<i32> {
    let start = Instant::now();
    loop {
        if CANCELLED.load(Ordering::Relaxed) {
            let _ = child.kill();
            kill_group_children();
            return Ok(143);
        }
        match child.try_wait()? {
            Some(st) => return Ok(st.code().unwrap_or(1)),
            None => {
                if start.elapsed() >= Duration::from_secs(secs) {
                    let _ = child.kill();
                    kill_group_children();
                    return Ok(124);
                }
                thread::sleep(Duration::from_millis(50));
            }
        }
    }
}

pub fn run_deadline(secs: u64, mut cmd: Command) -> io::Result<i32> {
    let mut child = cmd.spawn()?;
    wait_deadline(&mut child, secs)
}

fn drain_limited(
    pipe: Option<impl Read + Send + 'static>,
    log: PathBuf,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let Some(pipe) = pipe else { return };
        let mut n = 0usize;
        let mut reader = BufReader::new(pipe);
        let mut buf = String::new();
        while reader.read_line(&mut buf).ok().is_some_and(|k| k > 0) {
            if n < MAX_CAPTURE_BYTES {
                append_log_path(&log, buf.trim_end());
                n = n.saturating_add(buf.len());
            }
            buf.clear();
        }
    })
}

/// Run a job with a deadline and retain at most MAX_CAPTURE_BYTES of output in the log.
pub fn run_deadline_logged(secs: u64, mut cmd: Command, rt: &Runtime) -> io::Result<i32> {
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn()?;
    let log = rt.log.clone();
    let t_out = drain_limited(child.stdout.take(), log.clone());
    let t_err = drain_limited(child.stderr.take(), log);
    let rc = wait_deadline(&mut child, secs);
    let _ = t_out.join();
    let _ = t_err.join();
    rt.enforce_log_bound();
    rc
}

pub fn capture_limited(secs: u64, mut cmd: Command) -> String {
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(_) => return String::new(),
    };
    let mut stdout = child.stdout.take();
    let mut stderr = child.stderr.take();
    let reader = thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(ref mut s) = stdout {
            let _ = s.read_to_end(&mut buf);
        }
        if let Some(ref mut s) = stderr {
            let _ = s.read_to_end(&mut buf);
        }
        if buf.len() > MAX_CAPTURE_BYTES {
            buf.truncate(MAX_CAPTURE_BYTES);
        }
        buf
    });
    let start = Instant::now();
    loop {
        if let Ok(Some(_)) = child.try_wait() {
            break;
        }
        if start.elapsed() >= Duration::from_secs(secs) {
            let _ = child.kill();
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    String::from_utf8_lossy(&reader.join().unwrap_or_default()).into_owned()
}

pub fn have_cmd(name: &str) -> bool {
    Command::new("which")
        .arg(name)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

pub fn pacman_has(pkg: &str) -> bool {
    Command::new("pacman")
        .args(["-Q", pkg])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

pub fn drive_is_writable(dev: &str) -> bool {
    optical_dev_path_ok(dev) && is_block(Path::new(dev)) && {
        OpenOptions::new().write(true).custom_flags(O_NOFOLLOW).open(dev).is_ok()
    }
}

pub fn in_optical_group() -> bool {
    let user = std::env::var("USER").unwrap_or_else(|_| whoami());
    let out = Command::new("getent").args(["group", "optical"]).output();
    let Ok(out) = out else { return false };
    let line = String::from_utf8_lossy(&out.stdout);
    line.split(':').nth(3).is_some_and(|members| {
        members
            .trim()
            .split(',')
            .any(|m| m.trim() == user)
    })
}

pub fn whoami() -> String {
    String::from_utf8_lossy(
        &Command::new("id")
            .arg("-un")
            .output()
            .map(|o| o.stdout)
            .unwrap_or_default(),
    )
    .trim()
    .to_string()
}

pub fn maybe_newgrp_wrap(dev: &str, args: &[String]) -> Option<i32> {
    if std::env::var_os("VIDEO_TO_DVD_NEWGRP").is_some() {
        return None;
    }
    if !optical_dev_path_ok(dev) || !Path::new(dev).exists() {
        return None;
    }
    if drive_is_writable(dev) || !in_optical_group() {
        return None;
    }
    std::env::set_var("VIDEO_TO_DVD_NEWGRP", "1");
    let exe = std::env::current_exe().ok()?;
    let mut quoted = format!("{} ", shell_quote(&exe.display().to_string()));
    for a in args {
        quoted.push_str(&shell_quote(a));
        quoted.push(' ');
    }
    if have_cmd("sg") {
        let err = Command::new("sg").args(["optical", "-c", &quoted]).exec();
        return Some(io::Error::from(err).raw_os_error().unwrap_or(1));
    }
    if have_cmd("newgrp") {
        let err = Command::new("newgrp").args(["optical", "-c", &quoted]).exec();
        return Some(io::Error::from(err).raw_os_error().unwrap_or(1));
    }
    None
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

#[derive(Clone)]
pub struct Drive {
    pub path: String,
    pub label: String,
}

pub fn drive_human_label(tran: &str, model: &str) -> String {
    let m = model.trim();
    let t = tran.to_ascii_lowercase();
    match m {
        "" | "Mass Storage Device" | "USB Mass Storage Device" | "USB Mass Storage" => {
            if t == "usb" {
                "drive.usb".into()
            } else {
                "drive.internal".into()
            }
        }
        _ => m.to_string(),
    }
}

pub fn list_optical_drives() -> Vec<Drive> {
    let mut drives = Vec::new();
    let blob = capture_limited(5, cmd("lsblk", &["-d", "-n", "-P", "-o", "NAME,TYPE,TRAN,MODEL"]));
    for line in blob.lines() {
        if lsblk_kv(line, "TYPE") != "rom" {
            continue;
        }
        let name = lsblk_kv(line, "NAME");
        let path = format!("/dev/{name}");
        if !optical_dev_path_ok(&path) || !is_block(Path::new(&path)) {
            continue;
        }
        let label = printable(&drive_human_label(&lsblk_kv(line, "TRAN"), &lsblk_kv(line, "MODEL")));
        drives.push(Drive { path, label });
    }
    if let Ok(rd) = fs::read_dir("/dev") {
        for ent in rd.flatten() {
            let name = ent.file_name().to_string_lossy().into_owned();
            if !name.starts_with("sr") || !name[2..].chars().all(|c| c.is_ascii_digit()) {
                continue;
            }
            let path = format!("/dev/{name}");
            if drives.iter().any(|d| d.path == path) || !is_block(Path::new(&path)) {
                continue;
            }
            let line = capture_limited(5, cmd("lsblk", &["-d", "-n", "-P", "-o", "NAME,TYPE,TRAN,MODEL", &path]));
            let label = printable(&drive_human_label(&lsblk_kv(&line, "TRAN"), &lsblk_kv(&line, "MODEL")));
            drives.push(Drive { path, label });
        }
    }
    let labels: Vec<String> = drives.iter().map(|d| d.label.clone()).collect();
    for i in 0..drives.len() {
        if labels.iter().filter(|l| **l == labels[i]).count() > 1 {
            let base = drives[i].path.rsplit('/').next().unwrap_or("sr").to_string();
            drives[i].label = format!("{} ({base})", drives[i].label);
        }
    }
    drives
}

pub fn first_dvd_dev() -> Option<String> {
    list_optical_drives()
        .into_iter()
        .find_map(|d| validate_optical_dev(&d.path))
}

pub fn resolve_dev(raw: &str) -> Option<String> {
    if !raw.is_empty() {
        validate_optical_dev(raw)
    } else {
        first_dvd_dev()
    }
}

pub fn emit_drives() {
    for d in list_optical_drives() {
        emit(&format!("DEV:{}|{}", d.path, d.label));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn udev_optical_required() {
        assert!(!udev_says_optical(""));
        assert!(!udev_says_optical("DEVNAME=/dev/sr0\n"));
        assert!(udev_says_optical("ID_CDROM=1\n"));
        assert!(udev_says_optical("ID_TYPE=cd\n"));
        assert!(!udev_says_optical("ID_CDROM=0\nID_TYPE=disk\n"));
    }

    #[test]
    fn optical_paths() {
        assert!(optical_dev_path_ok("/dev/sr0"));
        assert!(optical_dev_path_ok("/dev/sr12"));
        assert!(!optical_dev_path_ok("/dev/sda"));
        assert!(!optical_dev_path_ok("/dev/nvme0n1"));
        assert!(!optical_dev_path_ok("/dev/sr0foo"));
        assert!(!optical_dev_path_ok("/tmp/sr0"));
        assert!(!optical_dev_path_ok("/dev/../sr0"));
        assert!(!optical_dev_path_ok(""));
    }

    #[test]
    fn iso_safety() {
        let dir = tempfile::tempdir().unwrap();
        let ok = dir.path().join("ok.iso");
        fs::write(&ok, b"payload").unwrap();
        assert!(iso_is_safe_output(&ok));
        assert!(iso_is_safe_output(&dir.path().join("new.iso")));

        let link = dir.path().join("link.iso");
        symlink("/etc/passwd", &link).unwrap();
        assert!(!iso_is_safe_output(&link));

        let victim = dir.path().join("victim");
        fs::write(&victim, b"secret").unwrap();
        let dest = dir.path().join("dest.iso");
        symlink(&victim, &dest).unwrap();
        let src = dir.path().join("src.iso");
        fs::write(&src, b"data").unwrap();
        assert!(install_iso_output(&src, &dest).is_err());
        assert_eq!(fs::read_to_string(&victim).unwrap(), "secret");
        assert!(dest.is_symlink());

        let src2 = dir.path().join("src2.iso");
        fs::write(&src2, b"data2").unwrap();
        let fresh = dir.path().join("fresh.iso");
        assert!(install_iso_output(&src2, &fresh).is_ok());
        assert!(fresh.is_file() && !fresh.is_symlink());

        let fp = iso_fingerprint(&fresh).unwrap();
        assert!(safe_unlink_iso(&link, None).is_err());
        assert!(link.is_symlink());

        fs::remove_file(&fresh).unwrap();
        fs::write(&fresh, b"replaced").unwrap();
        assert!(safe_unlink_iso(&fresh, Some(&fp)).is_err());
        let fp2 = iso_fingerprint(&fresh).unwrap();
        assert!(safe_unlink_iso(&fresh, Some(&fp2)).is_ok());
        assert!(!fresh.exists());
    }

    #[test]
    fn runtime_and_log_bound() {
        let dir = tempfile::tempdir().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        std::env::set_var("VIDEO_TO_DVD_RUNTIME_DIR", dir.path());
        let rt = Runtime::init().unwrap();
        assert!(rt.log.is_file() && !rt.log.is_symlink());
        assert_eq!(fs::metadata(&rt.log).unwrap().mode() & 0o777, 0o600);

        let evil = dir.path().join("evil.log");
        symlink("/etc/passwd", &evil).unwrap();
        assert!(safe_create_file(&evil).is_ok());
        assert!(evil.is_file() && !evil.is_symlink());
        assert!(Path::new("/etc/passwd").is_file());

        let fifo = dir.path().join("fifo.log");
        unsafe {
            let c = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
            libc::mkfifo(c.as_ptr(), 0o600);
        }
        assert!(safe_create_file(&fifo).is_err());
    }
}
