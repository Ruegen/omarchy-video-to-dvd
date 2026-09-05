use std::fs;
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::classify::{
    eta_status, iso_need_bytes, parse_ffmpeg_speed, parse_ffmpeg_time_seconds, DVD_BYTES,
};
use crate::protocol::{emit, fail, progress};
use crate::security::{
    become_session_leader, capture_limited, cmd, have_cmd, install_iso_output, iso_is_safe_output,
    kill_group_children, run_deadline_logged, Runtime, CANCELLED, TIMEOUT_DVDAUTHOR, TIMEOUT_FFMPEG,
    TIMEOUT_FFPROBE, TIMEOUT_GENISO,
};

const AUDIO_KBPS: f64 = 192.0;
const OVERHEAD: f64 = 0.94;
const ABS_MIN_VBITRATE: i64 = 500;
const MAX_VBITRATE: i64 = 8000;

fn tv_standard() -> &'static str {
    match std::env::var("VIDEO_TO_DVD_STANDARD")
        .unwrap_or_else(|_| "PAL".into())
        .to_ascii_uppercase()
        .as_str()
    {
        "NTSC" => "NTSC",
        _ => "PAL",
    }
}

fn file_ext(path: &str) -> String {
    Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
}

fn supported(ext: &str) -> bool {
    matches!(
        ext,
        "mp4" | "mkv" | "mov" | "avi" | "webm" | "m4v" | "ts" | "mts" | "m2ts" | "wmv" | "flv"
    )
}

fn space_ok(target: &Path) -> bool {
    let dir = if target.is_dir() {
        target
    } else {
        target.parent().unwrap_or(target)
    };
    if !dir.is_dir() {
        return false;
    }
    let out = capture_limited(
        5,
        cmd("df", &["-B1", "--output=avail", &dir.display().to_string()]),
    );
    let avail = out
        .lines()
        .nth(1)
        .unwrap_or("")
        .chars()
        .filter(|c| c.is_ascii_digit())
        .collect::<String>();
    avail.parse::<u64>().is_ok_and(|n| n >= iso_need_bytes())
}

fn ffprobe_field(input: &str, args: &[&str], rt: &Runtime) -> String {
    let mut c = Command::new("ffprobe");
    c.args(args).arg(input);
    let s = capture_limited(TIMEOUT_FFPROBE, c);
    rt.append_log(&s);
    s.lines().next().unwrap_or("").trim().to_string()
}

fn choose_layout(tv: &str, src_ar: f64) -> (&'static str, &'static str, &'static str, &'static str, &'static str) {
    let d169 = (src_ar - 16.0 / 9.0).abs();
    let d43 = (src_ar - 4.0 / 3.0).abs();
    let wide = d169 <= d43;
    if tv == "NTSC" {
        if wide {
            (
                "ntsc-dvd",
                "30000/1001",
                "16:9",
                "ntsc+16:9",
                "scale=853:480:force_original_aspect_ratio=decrease,pad=853:480:(ow-iw)/2:(oh-ih)/2:black,scale=720:480,setdar=16/9,setsar=32/27",
            )
        } else {
            (
                "ntsc-dvd",
                "30000/1001",
                "4:3",
                "ntsc+4:3",
                "scale=640:480:force_original_aspect_ratio=decrease,pad=640:480:(ow-iw)/2:(oh-ih)/2:black,scale=720:480,setdar=4/3,setsar=8/9",
            )
        }
    } else if wide {
        (
            "pal-dvd",
            "25",
            "16:9",
            "pal+16:9",
            "scale=1024:576:force_original_aspect_ratio=decrease,pad=1024:576:(ow-iw)/2:(oh-ih)/2:black,scale=720:576,setdar=16/9,setsar=64/45",
        )
    } else {
        (
            "pal-dvd",
            "25",
            "4:3",
            "pal+4:3",
            "scale=768:576:force_original_aspect_ratio=decrease,pad=768:576:(ow-iw)/2:(oh-ih)/2:black,scale=720:576,setdar=4/3,setsar=12/11",
        )
    }
}

fn amf_available() -> bool {
    capture_limited(15, cmd("ffmpeg", &["-hide_banner", "-encoders"])).contains("mpeg2_amf")
}

pub fn space_check(target: &str) -> i32 {
    if space_ok(Path::new(target)) {
        emit("SPACE:ok:1");
        0
    } else {
        fail("not-enough-space")
    }
}

pub fn convert(input: &str, output_iso: &str) -> i32 {
    become_session_leader();
    let tv = tv_standard();
    let rt = match Runtime::init() {
        Ok(rt) => rt,
        Err(_) => return fail("runtime-state"),
    };
    if rt.setup_job().is_err() {
        return fail("runtime-state");
    }

    let ext = file_ext(input);
    if !supported(&ext) {
        progress(0, &format!("unsupported-format|.{ext}"));
        rt.clear_pgid();
        return fail("unsupported-format");
    }
    if !Path::new(input).is_file() {
        rt.clear_pgid();
        return fail("input-not-found");
    }
    let out = Path::new(output_iso);
    if !iso_is_safe_output(out) {
        rt.clear_pgid();
        return fail("iso-unsafe-path");
    }
    if !space_ok(out) {
        rt.clear_pgid();
        return fail("not-enough-space");
    }

    let work = match tempfile::tempdir() {
        Ok(w) => w,
        Err(_) => {
            rt.clear_pgid();
            return fail("runtime-state");
        }
    };
    rt.append_log(&format!(
        "=== oma-dvd convert ===\ninput={input}\noutput={output_iso}\nwork={}\npgid={}",
        work.path().display(),
        std::process::id()
    ));

    let dur = ffprobe_field(
        input,
        &["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0"],
        &rt,
    );
    let dur_i = dur
        .split('.')
        .next()
        .and_then(|s| s.parse::<i64>().ok())
        .unwrap_or(0);
    let have_dur = dur_i >= 1;

    let src_w = ffprobe_field(
        input,
        &["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width", "-of", "csv=p=0"],
        &rt,
    );
    let src_h = ffprobe_field(
        input,
        &["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=height", "-of", "csv=p=0"],
        &rt,
    );
    let dar_raw = ffprobe_field(
        input,
        &[
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=display_aspect_ratio",
            "-of",
            "csv=p=0",
        ],
        &rt,
    );

    let src_ar = if let Some((a, b)) = dar_raw.split_once(':') {
        let a: f64 = a.parse().unwrap_or(0.0);
        let b: f64 = b.parse().unwrap_or(0.0);
        if a > 0.0 && b > 0.0 {
            a / b
        } else {
            16.0 / 9.0
        }
    } else if let (Ok(w), Ok(h)) = (src_w.parse::<f64>(), src_h.parse::<f64>()) {
        if h > 0.0 {
            w / h
        } else {
            16.0 / 9.0
        }
    } else {
        16.0 / 9.0
    };

    let (target_arg, fps_val, aspect, vopts, scale) = choose_layout(tv, src_ar);

    let mut vbitrate = 4000i64;
    if have_dur {
        let target_bits = DVD_BYTES as f64 * 8.0 * OVERHEAD;
        let audio_bits = AUDIO_KBPS * 1000.0 * dur_i as f64;
        let video_bits = target_bits - audio_bits;
        vbitrate = if video_bits > 0.0 {
            (video_bits / dur_i as f64 / 1000.0) as i64
        } else {
            ABS_MIN_VBITRATE
        };
        vbitrate = vbitrate.clamp(ABS_MIN_VBITRATE, MAX_VBITRATE);
    }

    rt.append_log(&format!(
        "src={src_w}x{src_h} dar_raw={dar_raw} src_ar={src_ar}\naspect={aspect} vopts={vopts} vbitrate={vbitrate}k\nvf={scale}"
    ));

    let vcodec = if have_cmd("ffmpeg") && amf_available() {
        "mpeg2_amf"
    } else {
        "mpeg2video"
    };

    let dim = if src_w.is_empty() { "?" } else { &src_w };
    let him = if src_h.is_empty() { "?" } else { &src_h };
    progress(1, &format!("analyzing|{dim}x{him}|{aspect}|{tv}"));

    let mpg = work.path().join("video.mpg");
    let mut ff = Command::new("ffmpeg");
    ff.args([
        "-nostdin",
        "-y",
        "-i",
        input,
        "-target",
        target_arg,
        "-vf",
        scale,
        "-pix_fmt",
        "yuv420p",
        "-r",
        fps_val,
        "-c:v",
        vcodec,
        "-aspect",
        aspect,
        "-b:v",
        &format!("{vbitrate}k"),
        "-maxrate",
        "9000k",
        "-minrate",
        "0",
        "-bufsize",
        "1835008",
        "-g",
        "15",
        "-bf",
        "2",
        "-c:a",
        "ac3",
        "-b:a",
        &format!("{AUDIO_KBPS}k"),
        "-ac",
        "2",
        "-ar",
        "48000",
        "-f",
        "dvd",
        &mpg.display().to_string(),
    ]);
    ff.stdout(Stdio::null()).stderr(Stdio::piped());

    let encode_rc = match ff.spawn() {
        Ok(mut child) => {
            let stderr = child.stderr.take();
            let deadline = Instant::now() + Duration::from_secs(TIMEOUT_FFMPEG);
            let start = Instant::now();
            let mut last_key = String::new();
            if let Some(err) = stderr {
                let reader = BufReader::new(err);
                let mut leftover = String::new();
                for chunk in reader.split(b'\r') {
                    let Ok(bytes) = chunk else { break };
                    leftover.push_str(&String::from_utf8_lossy(&bytes));
                    for line in leftover.split('\n') {
                        let line = line.trim();
                        if line.is_empty() {
                            continue;
                        }
                        rt.append_log(line);
                        if let Some(elapsed) = parse_ffmpeg_time_seconds(line) {
                            if have_dur {
                                let mut pct = elapsed * 70 / dur_i;
                                pct = pct.clamp(1, 70);
                                let mut pct_v = elapsed * 100 / dur_i;
                                pct_v = pct_v.clamp(0, 99);
                                let speed = parse_ffmpeg_speed(line);
                                let wall = start.elapsed().as_secs() as i64;
                                let token = eta_status(dur_i, elapsed, wall, speed, pct_v);
                                let key = format!("{pct}:{token}");
                                if key != last_key {
                                    progress(pct as i32, &token);
                                    last_key = key;
                                }
                            } else {
                                progress(1, "encoding");
                            }
                        }
                    }
                    leftover.clear();
                    if CANCELLED.load(std::sync::atomic::Ordering::Relaxed) || Instant::now() > deadline {
                        let _ = child.kill();
                        kill_group_children();
                        break;
                    }
                }
            }
            if Instant::now() > deadline {
                124
            } else if CANCELLED.load(std::sync::atomic::Ordering::Relaxed) {
                143
            } else {
                child.wait().ok().and_then(|s| s.code()).unwrap_or(1)
            }
        }
        Err(_) => 1,
    };

    if encode_rc == 124 || encode_rc == 137 {
        rt.clear_pgid();
        return fail("timeout");
    }
    if encode_rc == 143 {
        rt.clear_pgid();
        return fail("cancelled");
    }
    if encode_rc != 0 || fs::metadata(&mpg).map(|m| m.len() == 0).unwrap_or(true) {
        rt.clear_pgid();
        return fail("ffmpeg-encode-failed");
    }

    progress(75, "authoring");
    std::env::set_var("VIDEO_FORMAT", tv);
    let dvd_dir = work.path().join("dvd");
    let da1 = run_deadline_logged(
        TIMEOUT_DVDAUTHOR,
        {
            let mut c = Command::new("dvdauthor");
            c.args(["-o", &dvd_dir.display().to_string(), "-t", "-v", vopts, &mpg.display().to_string()]);
            c
        },
        &rt,
    )
    .unwrap_or(1);
    if da1 == 124 || da1 == 137 {
        rt.clear_pgid();
        return fail("timeout");
    }
    let da2 = if da1 == 0 {
        run_deadline_logged(
            TIMEOUT_DVDAUTHOR,
            {
                let mut c = Command::new("dvdauthor");
                c.args(["-o", &dvd_dir.display().to_string(), "-T"]);
                c
            },
            &rt,
        )
        .unwrap_or(1)
    } else {
        1
    };
    if da2 == 124 || da2 == 137 {
        rt.clear_pgid();
        return fail("timeout");
    }
    if da1 != 0 || da2 != 0 || !dvd_dir.join("VIDEO_TS/VIDEO_TS.IFO").is_file() {
        rt.clear_pgid();
        return fail("dvdauthor-failed");
    }

    progress(90, "iso");
    if !iso_is_safe_output(out) {
        rt.clear_pgid();
        return fail("iso-unsafe-path");
    }
    let parent = out.parent().unwrap_or(Path::new("."));
    let tmp = match tempfile::Builder::new()
        .prefix(".v2dvd-")
        .suffix(".iso")
        .tempfile_in(parent)
    {
        Ok(t) => t,
        Err(_) => {
            rt.clear_pgid();
            return fail("iso-build-failed");
        }
    };
    let tmp_path = tmp.path().to_path_buf();
    let iso_bin = if have_cmd("genisoimage") {
        "genisoimage"
    } else {
        "mkisofs"
    };
    let iso_rc = run_deadline_logged(
        TIMEOUT_GENISO,
        {
            let mut c = Command::new(iso_bin);
            c.args([
                "-dvd-video",
                "-V",
                "DVD_VIDEO",
                "-o",
                &tmp_path.display().to_string(),
                &dvd_dir.display().to_string(),
            ]);
            c
        },
        &rt,
    )
    .unwrap_or(1);
    if iso_rc == 124 || iso_rc == 137 {
        rt.clear_pgid();
        return fail("timeout");
    }
    if iso_rc != 0 || fs::metadata(&tmp_path).map(|m| m.len() == 0).unwrap_or(true) {
        rt.clear_pgid();
        return fail("iso-build-failed");
    }
    let persist = tmp.into_temp_path();
    if install_iso_output(&tmp_path, out).is_err() {
        let _ = persist;
        rt.clear_pgid();
        return fail("iso-unsafe-path");
    }
    let _ = persist;
    rt.clear_pgid();
    progress(100, "done");
    emit(&format!("RESULT:OK:{output_iso}"));
    0
}
