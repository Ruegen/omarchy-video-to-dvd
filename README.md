# Video to DVD

Omarchy bar widget: select video → PAL/NTSC DVD-Video ISO → burn → eject. Uses AMD AMF hardware encoding (`mpeg2_amf`) automatically when available.

## Usage

1. Click 💿 on bar.
2. Select video and standard (PAL / NTSC).
3. Make DVD.
4. Insert blank disc when prompted.

## Packages

Required Arch packages:
- `ffmpeg`
- `dvdauthor`
- `cdrtools` (`genisoimage`)
- `dvd+rw-tools` (`growisofs`)
- `bc`
- `util-linux` (`eject`)

## License

MIT.
