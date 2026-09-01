# Video to DVD

Omarchy bar widget: pick a video → PAL or NTSC DVD-Video ISO → wait for a blank disc → burn → eject.

Uses AMD AMF hardware encoding (`mpeg2_amf`) when available. The bar icon is a monochrome disc glyph, so it follows the current theme.

![Preview](preview.png)

## Usage

1. Click the disc icon on the bar.
2. Select video and standard (PAL / NTSC).
3. Make DVD.
4. Insert a blank disc when asked. Cancel anytime.

Missing packages show an Install button. After a successful burn the ISO is deleted. A long filename is elided in the panel.

## Packages

Official Arch repos. The panel can install missing ones with `omarchy-pkg-add`:

- ffmpeg
- dvdauthor
- cdrtools (genisoimage / mkisofs, cdrecord)
- dvd+rw-tools (growisofs, dvd+rw-mediainfo)
- bc

`eject` comes from util-linux (already on Arch).

## Install

Repo: `~/apps/omarchy-video-to-dvd`. Drop-in under `~/.config/omarchy/plugins/io.github.ruegen.video-to-dvd/`, or `omarchy plugin add`. Reload the Omarchy shell after copying files.

## Translations

UI strings live in `i18n/*.json` (BCP-47 / ISO 639 tags). `en.json` is the source and fallback.

To add a language, copy `i18n/en.json` to `i18n/fr.json` (or `xx.json`) and translate the values. Keys must stay identical.

The panel picks a file from the desktop locale (`Qt.locale()`, then `LANG` / `LANGUAGE`): `de_DE.json`, then `de.json`, then `en.json`.

## License

MIT. You can use, copy, and modify this plugin, including commercially.

The Arch packages this plugin runs keep their own licenses (GPL, LGPL, CDDL).

You are responsible for only converting and burning content you have the right to copy.
