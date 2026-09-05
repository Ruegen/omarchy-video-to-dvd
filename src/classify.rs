use std::path::Path;

pub const DVD_BYTES: u64 = 4_700_372_992;

pub fn parse_ffmpeg_time_seconds(line: &str) -> Option<i64> {
    let rest = line.split("time=").nth(1)?;
    let tok = rest.split_whitespace().next()?;
    let mut parts = tok.split(':');
    let h: i64 = parts.next()?.parse().ok()?;
    let m: i64 = parts.next()?.parse().ok()?;
    let s = parts.next()?.split('.').next()?;
    let s: i64 = s.parse().ok()?;
    Some(h * 3600 + m * 60 + s)
}

pub fn parse_ffmpeg_speed(line: &str) -> Option<f64> {
    let rest = line.split("speed=").nth(1)?;
    let tok = rest.split('x').next()?;
    tok.parse().ok()
}

pub fn eta_status(dur_i: i64, elapsed: i64, wall: i64, speed: Option<f64>, pct_v: i64) -> String {
    let left_media = (dur_i - elapsed).max(0);

    let left_wall = if let Some(sp) = speed {
        if sp > 0.2 {
            Some((left_media as f64 / sp) as i64)
        } else if wall >= 5 && elapsed >= 3 {
            Some(left_media * wall / elapsed)
        } else {
            None
        }
    } else if wall >= 5 && elapsed >= 3 {
        Some(left_media * wall / elapsed)
    } else {
        None
    };

    match left_wall {
        None => format!("encoding-pct|{pct_v}"),
        Some(w) if w > 10800 => format!("encoding-pct|{pct_v}"),
        Some(w) if w < 45 => format!("encoding-finishing|{pct_v}"),
        Some(w) if w < 90 => format!("encoding-eta|1|{pct_v}"),
        Some(w) => format!("encoding-eta|{}|{pct_v}", (w + 30) / 60),
    }
}

pub fn classify_blank(info: &str, iso_size: Option<u64>) -> &'static str {
    let low = info.to_ascii_lowercase();
    if [
        "medium not present",
        "no medium",
        "not ready",
        "cannot load",
        "unable to read",
        "unable to open",
        "no disc",
        "no media",
        "asc=3ah",
        "device not ready",
    ]
    .iter()
    .any(|k| low.contains(k))
    {
        return "BLANK:NONE";
    }

    let mut is_blank = false;
    let has_status = info.lines().any(|l| l.to_ascii_lowercase().contains("disc status:"));
    if info.lines().any(|l| {
        let l = l.to_ascii_lowercase();
        l.contains("disc status:") && l.contains("blank")
    }) {
        is_blank = true;
    } else if has_status {
        let complete = info.lines().any(|l| {
            let l = l.to_ascii_lowercase();
            l.contains("disc status:") && l.contains("complete")
        });
        if !complete {
            is_blank = true;
        }
    } else if info.to_ascii_lowercase().contains("mounted media:") {
        return "BLANK:NO";
    }

    if is_blank {
        if let Some(iso_size) = iso_size {
            if let Some(free) = free_blocks(info) {
                let free_bytes = free.saturating_mul(2048);
                if free_bytes < iso_size {
                    return "BLANK:TOO_SMALL";
                }
            }
        }
        return "BLANK:YES";
    }
    "BLANK:NO"
}

fn free_blocks(info: &str) -> Option<u64> {
    for line in info.lines() {
        let l = line.to_ascii_lowercase();
        if l.contains("free blocks") || l.contains("free space") {
            let digits: String = line.chars().filter(|c| c.is_ascii_digit()).collect();
            if !digits.is_empty() {
                return digits.parse().ok();
            }
        }
    }
    None
}

pub fn classify_udev_props(props: &str, iso_size: Option<u64>) -> &'static str {
    let media = props
        .lines()
        .filter_map(|l| l.strip_prefix("ID_CDROM_MEDIA="))
        .next_back()
        .unwrap_or("");
    if media != "1" {
        return "BLANK:NONE";
    }
    let state = props
        .lines()
        .filter_map(|l| l.strip_prefix("ID_CDROM_MEDIA_STATE="))
        .next_back()
        .unwrap_or("");
    let fstype = props
        .lines()
        .filter_map(|l| l.strip_prefix("ID_FS_TYPE="))
        .next_back()
        .unwrap_or("");
    if state == "blank" {
        if iso_size.is_some_and(|s| s > DVD_BYTES) {
            return "BLANK:TOO_SMALL";
        }
        return "BLANK:YES";
    }
    if !fstype.is_empty() {
        return "BLANK:NO";
    }
    "BLANK:NO"
}

pub fn iso_size_of(path: &Path) -> Option<u64> {
    if path.is_symlink() || !path.is_file() {
        return None;
    }
    std::fs::metadata(path).ok().map(|m| m.len())
}

pub fn iso_need_bytes() -> u64 {
    DVD_BYTES + 536_870_912
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eta_wall_clock() {
        assert_eq!(eta_status(6420, 80, 10, Some(8.0), 1), "encoding-eta|13|1");
        assert_eq!(eta_status(6420, 80, 10, None, 1), "encoding-eta|13|1");
        assert_eq!(eta_status(6420, 2, 2, None, 0), "encoding-pct|0");
        assert_eq!(eta_status(6420, 6380, 800, Some(8.0), 99), "encoding-finishing|99");
        assert_eq!(eta_status(6420, 5900, 740, Some(8.0), 91), "encoding-eta|1|91");
        assert_eq!(eta_status(6420, 2, 2, Some(0.05), 0), "encoding-pct|0");
        assert_eq!(eta_status(20000, 1, 5, Some(0.3), 0), "encoding-pct|0");
        assert!(!eta_status(6420, 80, 10, Some(8.0), 1).contains("|107"));
    }

    #[test]
    fn ffmpeg_parse() {
        let line = "frame=  123 fps= 45 q=2.0 size=    1234kB time=01:47:00.12 bitrate=2053.4kbits/s speed=8.04x";
        assert_eq!(parse_ffmpeg_time_seconds(line), Some(6420));
        assert_eq!(parse_ffmpeg_speed(line), Some(8.04));
        assert_eq!(parse_ffmpeg_time_seconds("frame=1 fps=0"), None);
        assert_eq!(parse_ffmpeg_speed("frame=1 time=00:00:01.00"), None);
    }

    #[test]
    fn udev_props() {
        assert_eq!(classify_udev_props("ID_CDROM=1\n", None), "BLANK:NONE");
        assert_eq!(
            classify_udev_props("ID_CDROM_MEDIA=1\nID_CDROM_MEDIA_STATE=blank\n", None),
            "BLANK:YES"
        );
        assert_eq!(
            classify_udev_props("ID_CDROM_MEDIA=1\nID_CDROM_MEDIA_STATE=blank\n", Some(5_000_000_000)),
            "BLANK:TOO_SMALL"
        );
        assert_eq!(
            classify_udev_props("ID_CDROM_MEDIA=1\nID_FS_TYPE=iso9660\n", None),
            "BLANK:NO"
        );
    }

    #[test]
    fn blank_fixtures() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
        let load = |n: &str| std::fs::read_to_string(root.join(n)).unwrap();
        assert_eq!(classify_blank(&load("mediainfo-blank.txt"), None), "BLANK:YES");
        assert_eq!(classify_blank(&load("mediainfo-complete.txt"), None), "BLANK:NO");
        assert_eq!(classify_blank(&load("mediainfo-empty-tray.txt"), None), "BLANK:NONE");
        assert_eq!(classify_blank(&load("mediainfo-appendable.txt"), None), "BLANK:YES");
        assert_eq!(
            classify_blank(&load("mediainfo-too-small.txt"), Some(1_048_576)),
            "BLANK:TOO_SMALL"
        );
        assert_eq!(classify_blank("", None), "BLANK:NO");
    }

    #[test]
    fn need_bytes() {
        assert_eq!(iso_need_bytes(), 5_237_243_904);
    }
}
