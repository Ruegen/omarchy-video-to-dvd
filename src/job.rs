use std::io::Read;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::protocol::{emit, fail, printable};
use crate::security::{current_uid, open_nofollow, safe_create_file, write_nofollow, OpenMode, Runtime};

pub const MAX_JOB_BYTES: usize = 4096;
const HEARTBEAT_SECS: u64 = 15;
const FIELD_MAX: usize = 240;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Idle,
    Convert,
    Converted,
    Wait,
    Burn,
    Done,
    Cancelled,
    Error,
}

impl Phase {
    fn as_str(self) -> &'static str {
        match self {
            Phase::Idle => "idle",
            Phase::Convert => "convert",
            Phase::Converted => "converted",
            Phase::Wait => "wait",
            Phase::Burn => "burn",
            Phase::Done => "done",
            Phase::Cancelled => "cancelled",
            Phase::Error => "error",
        }
    }

    fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "idle" => Phase::Idle,
            "convert" => Phase::Convert,
            "converted" => Phase::Converted,
            "wait" => Phase::Wait,
            "burn" => Phase::Burn,
            "done" => Phase::Done,
            "cancelled" => Phase::Cancelled,
            "error" => Phase::Error,
            _ => return None,
        })
    }

    fn is_active(self) -> bool {
        matches!(self, Phase::Convert | Phase::Wait | Phase::Burn)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Job {
    pub phase: Phase,
    pub source: String,
    pub pid: u32,
    pub pgid: u32,
    pub progress: u8,
    pub status: String,
    pub name: String,
    pub input: String,
    pub iso: String,
    pub device: String,
    pub error: String,
    pub updated: u64,
}

impl Job {
    fn blank() -> Self {
        Self {
            phase: Phase::Idle,
            source: String::new(),
            pid: 0,
            pgid: 0,
            progress: 0,
            status: String::new(),
            name: String::new(),
            input: String::new(),
            iso: String::new(),
            device: String::new(),
            error: String::new(),
            updated: now_secs(),
        }
    }
}

pub fn sanitize_field(s: &str, max: usize) -> String {
    printable(s).chars().take(max).collect()
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn source_from_env() -> String {
    match std::env::var("VIDEO_TO_DVD_SOURCE") {
        Ok(s) if s.eq_ignore_ascii_case("panel") => "panel".into(),
        _ => "cli".into(),
    }
}

fn display_name(path: &str) -> String {
    Path::new(path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(path)
        .into()
}

pub fn encode(job: &Job) -> String {
    format!(
        "phase={}\nsource={}\npid={}\npgid={}\nprogress={}\nstatus={}\nname={}\ninput={}\niso={}\ndevice={}\nerror={}\nupdated={}\n",
        job.phase.as_str(),
        sanitize_field(&job.source, 16),
        job.pid,
        job.pgid,
        job.progress.min(100),
        sanitize_field(&job.status, FIELD_MAX),
        sanitize_field(&job.name, FIELD_MAX),
        sanitize_field(&job.input, FIELD_MAX),
        sanitize_field(&job.iso, FIELD_MAX),
        sanitize_field(&job.device, 32),
        sanitize_field(&job.error, 64),
        job.updated,
    )
}

pub fn decode(text: &str) -> Option<Job> {
    if text.len() > MAX_JOB_BYTES {
        return None;
    }
    let mut job = Job::blank();
    let mut saw_phase = false;
    for line in text.lines() {
        if line.len() > FIELD_MAX + 16 {
            return None;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        match k {
            "phase" => {
                job.phase = Phase::parse(v)?;
                saw_phase = true;
            }
            "source" => job.source = sanitize_field(v, 16),
            "pid" => job.pid = v.parse().ok()?,
            "pgid" => job.pgid = v.parse().ok()?,
            "progress" => job.progress = v.parse::<u8>().ok()?.min(100),
            "status" => job.status = sanitize_field(v, FIELD_MAX),
            "name" => job.name = sanitize_field(v, FIELD_MAX),
            "input" => job.input = sanitize_field(v, FIELD_MAX),
            "iso" => job.iso = sanitize_field(v, FIELD_MAX),
            "device" => job.device = sanitize_field(v, 32),
            "error" => job.error = sanitize_field(v, 64),
            "updated" => job.updated = v.parse().ok()?,
            _ => {}
        }
    }
    saw_phase.then_some(job)
}

fn helper_comm(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    let path = PathBuf::from(format!("/proc/{pid}/comm"));
    let Ok(mut f) = open_nofollow(&path, OpenMode::Read) else {
        return false;
    };
    let mut buf = [0u8; 32];
    let Ok(n) = f.read(&mut buf) else {
        return false;
    };
    let name = String::from_utf8_lossy(&buf[..n]);
    name.trim() == "oma-dvd"
}

fn pid_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

pub fn helper_running(pid: u32) -> bool {
    pid_alive(pid) && (pid == std::process::id() || helper_comm(pid))
}

pub fn blocks_new_job(job: &Job) -> bool {
    if !job.phase.is_active() {
        return false;
    }
    if helper_running(job.pid) {
        return true;
    }
    job.phase == Phase::Wait && now_secs().saturating_sub(job.updated) <= HEARTBEAT_SECS
}

fn read_job_file(path: &Path) -> Option<Job> {
    if path.is_symlink() {
        return None;
    }
    let f = open_nofollow(path, OpenMode::Read).ok()?;
    let meta = f.metadata().ok()?;
    if !meta.is_file() || meta.uid() != current_uid() || meta.len() > MAX_JOB_BYTES as u64 {
        return None;
    }
    let mut buf = Vec::new();
    f.take(MAX_JOB_BYTES as u64 + 1).read_to_end(&mut buf).ok()?;
    if buf.len() > MAX_JOB_BYTES {
        return None;
    }
    decode(&String::from_utf8_lossy(&buf))
}

fn write_job_file(path: &Path, job: &Job) -> std::io::Result<()> {
    let mut job = job.clone();
    job.updated = now_secs();
    let bytes = encode(&job);
    if bytes.len() > MAX_JOB_BYTES {
        return Err(std::io::Error::other("job too large"));
    }
    safe_create_file(path)?;
    write_nofollow(path, bytes.as_bytes())
}

impl Runtime {
    pub fn read_job(&self) -> Option<Job> {
        read_job_file(&self.state)
    }

    pub fn write_job(&self, job: &Job) -> std::io::Result<()> {
        write_job_file(&self.state, job)
    }

    pub fn clear_job(&self) {
        let idle = Job::blank();
        let _ = self.write_job(&idle);
    }

    pub fn patch_job<F: FnOnce(&mut Job)>(&self, f: F) {
        let mut job = self.read_job().unwrap_or_else(Job::blank);
        f(&mut job);
        let _ = self.write_job(&job);
    }

    pub fn claim_job(&self, phase: Phase, input: &str, iso: &str, device: &str) -> Result<Job, &'static str> {
        if let Some(existing) = self.read_job() {
            if existing.pid != std::process::id() && blocks_new_job(&existing) {
                return Err("job-busy");
            }
        }
        let pid = std::process::id();
        let mut name = sanitize_field(&display_name(input), FIELD_MAX);
        let mut input_s = sanitize_field(input, FIELD_MAX);
        if input.is_empty() {
            if let Some(ex) = self.read_job() {
                if !ex.name.is_empty() {
                    name = ex.name;
                }
                if !ex.input.is_empty() {
                    input_s = ex.input;
                }
            }
        }
        let job = Job {
            phase,
            source: source_from_env(),
            pid,
            pgid: pid,
            progress: 0,
            status: String::new(),
            name,
            input: input_s,
            iso: sanitize_field(iso, FIELD_MAX),
            device: sanitize_field(device, 32),
            error: String::new(),
            updated: now_secs(),
        };
        self.write_job(&job).map_err(|_| "runtime-state")?;
        Ok(job)
    }

    pub fn job_progress(&self, pct: i32, payload: &str) {
        self.patch_job(|j| {
            if payload == "burning" {
                j.phase = Phase::Burn;
            } else if j.phase == Phase::Idle {
                j.phase = Phase::Convert;
            }
            j.progress = pct.clamp(0, 100) as u8;
            j.status = sanitize_field(payload, FIELD_MAX);
            j.pid = std::process::id();
            j.pgid = j.pid;
        });
    }

    pub fn job_fail(&self, err: &str) {
        self.patch_job(|j| {
            j.phase = Phase::Error;
            j.error = sanitize_field(err, 64);
            j.status = sanitize_field(err, FIELD_MAX);
        });
    }

    pub fn job_converted(&self) {
        self.patch_job(|j| {
            j.phase = Phase::Converted;
            j.progress = 100;
            j.status = "done".into();
            j.pid = 0;
            j.pgid = 0;
        });
    }

    pub fn job_done(&self) {
        self.patch_job(|j| {
            j.phase = Phase::Done;
            j.progress = 100;
            j.status = "done".into();
            j.pid = 0;
            j.pgid = 0;
        });
    }
}

pub fn status_cmd() -> i32 {
    let Ok(rt) = Runtime::init() else {
        emit("JOB:IDLE");
        return 0;
    };
    let Some(job) = rt.read_job() else {
        emit("JOB:IDLE");
        return 0;
    };
    if job.phase == Phase::Idle {
        emit("JOB:IDLE");
        return 0;
    }
    if job.phase == Phase::Wait && !helper_running(job.pid) && now_secs().saturating_sub(job.updated) > HEARTBEAT_SECS
    {
        emit("JOB:IDLE");
        return 0;
    }
    emit("JOB:BEGIN");
    for line in encode(&job).lines() {
        emit(line);
    }
    emit("JOB:END");
    0
}

pub fn cancelled(rt: &Runtime) -> bool {
    rt.read_job()
        .is_some_and(|j| j.phase == Phase::Cancelled)
        || crate::security::CANCELLED.load(std::sync::atomic::Ordering::Relaxed)
}

fn kill_job(job: &Job) {
    let target = if job.pgid > 1 { job.pgid } else { job.pid };
    if target > 1 && pid_alive(target) {
        unsafe {
            libc::kill(-(target as i32), libc::SIGTERM);
        }
    }
}

pub fn cancel_cmd() -> i32 {
    let Ok(rt) = Runtime::init() else {
        return fail("runtime-state");
    };
    let Some(mut job) = rt.read_job() else {
        emit("RESULT:OK:cancelled");
        return 0;
    };
    kill_job(&job);
    job.phase = Phase::Cancelled;
    job.status = "cancelled".into();
    job.pid = 0;
    job.pgid = 0;
    let _ = rt.write_job(&job);
    emit("RESULT:OK:cancelled");
    0
}

pub fn update_cmd(args: &[String]) -> i32 {
    let Some(phase) = args.first().map(String::as_str) else {
        return fail("runtime-state");
    };
    let Ok(rt) = Runtime::init() else {
        return fail("runtime-state");
    };
    if phase == "clear" {
        rt.clear_job();
        emit("RESULT:OK:cleared");
        return 0;
    }
    if phase == "heartbeat" {
        if let Some(job) = rt.read_job() {
            if job.phase.is_active() || job.phase == Phase::Converted {
                let _ = rt.write_job(&job);
            }
        }
        emit("RESULT:OK:heartbeat");
        return 0;
    }
    let Some(parsed) = Phase::parse(phase) else {
        return fail("runtime-state");
    };
    let iso = args.get(1).map(String::as_str).unwrap_or("");
    let name = args.get(2).map(String::as_str).unwrap_or("");
    let device = args.get(3).map(String::as_str).unwrap_or("");
    let input = args.get(4).map(String::as_str).unwrap_or("");
    rt.patch_job(|j| {
        j.phase = parsed;
        if !iso.is_empty() {
            j.iso = sanitize_field(iso, FIELD_MAX);
        }
        if !name.is_empty() {
            j.name = sanitize_field(name, FIELD_MAX);
        }
        if !device.is_empty() {
            j.device = sanitize_field(device, 32);
        }
        if !input.is_empty() {
            j.input = sanitize_field(input, FIELD_MAX);
            if j.name.is_empty() {
                j.name = sanitize_field(&display_name(input), FIELD_MAX);
            }
        }
        if parsed == Phase::Wait {
            j.status = "insert-blank".into();
            j.progress = 0;
        }
        if parsed == Phase::Done {
            j.progress = 100;
            j.status = "done".into();
            j.pid = 0;
            j.pgid = 0;
        }
        j.source = source_from_env();
    });
    emit(&format!("RESULT:OK:{phase}"));
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let job = Job {
            phase: Phase::Wait,
            source: "cli".into(),
            pid: 9,
            pgid: 9,
            progress: 40,
            status: "encoding-pct|12".into(),
            name: "film.mp4".into(),
            input: "/home/a/film.mp4".into(),
            iso: "/home/a/film.iso".into(),
            device: "/dev/sr0".into(),
            error: String::new(),
            updated: 1,
        };
        let back = decode(&encode(&job)).unwrap();
        assert_eq!(back.phase, Phase::Wait);
        assert_eq!(back.name, "film.mp4");
        assert_eq!(back.device, "/dev/sr0");
        assert_eq!(back.progress, 40);
    }

    #[test]
    fn rejects_huge() {
        let huge = "phase=wait\nname=".to_string() + &"x".repeat(MAX_JOB_BYTES);
        assert!(decode(&huge).is_none());
    }

    #[test]
    fn strips_control_chars() {
        let text = "phase=burn\nname=hi\u{0007}there\nupdated=1\n";
        let job = decode(text).unwrap();
        assert_eq!(job.name, "hithere");
    }

    #[test]
    fn done_does_not_block() {
        let job = Job {
            phase: Phase::Done,
            pid: 1,
            updated: now_secs(),
            ..Job::blank()
        };
        assert!(!blocks_new_job(&job));
    }

    #[test]
    fn fresh_wait_without_pid_blocks() {
        let job = Job {
            phase: Phase::Wait,
            pid: 0,
            updated: now_secs(),
            ..Job::blank()
        };
        assert!(blocks_new_job(&job));
    }

    #[test]
    fn stale_wait_without_pid_does_not_block() {
        let job = Job {
            phase: Phase::Wait,
            pid: 0,
            updated: 1,
            ..Job::blank()
        };
        assert!(!blocks_new_job(&job));
    }
}
