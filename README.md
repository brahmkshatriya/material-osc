# material-osc

A quality-of-life upgrade for mpv that keeps the player lightweight while
making everyday controls easier to reach and nicer to use. material-osc brings
a polished Material-style interface, smooth animated feedback, automatic
directory playlists, precise thumbnail previews, quick audio and subtitle
selection, and convenient playback-speed controls—all without replacing mpv.

## Showcase

[Watch the material-osc showcase (MP4)](assets/showcase.mp4)

## Directory playlists

Opening a local media file automatically adds the other video and audio files
in the same directory to the playlist, ordered by filename. An existing
multi-item playlist is left unchanged. To disable this behavior or sort by
modification time instead, use `script-opts/material-osc.conf`:

```conf
directory_playlist=no
directory_playlist_sort=newest
```

`directory_playlist_sort` accepts `name` (the default), `newest`, or `oldest`.

## Recommended mpv configuration

For a smoother UI, add the following options to your `mpv.conf`:

```conf
video-sync=display-resample
force-window=yes
```

The script disables automatic window resizing and starts the window at 66% of
the screen height. Its width is calculated from the video's aspect ratio.

Thumbnail previews require [Thumbfast](https://github.com/po5/thumbfast). Install
`thumbfast.lua` in mpv's `scripts` directory alongside material-osc. Thumbnail
behavior, including support for network media, is configured through Thumbfast:

```conf
# script-opts/thumbfast.conf
network=yes
```

## Building

The repository keeps the complete Material Symbols Rounded TTF for development.
Release builds automatically subset it to the icons referenced by the Lua sources.
The generated fonts are placed directly under `material-osc/`, alongside the
bundled `material-osc.lua` script directory.

```bash
python -m venv .venv
.venv/bin/pip install -r requirements-build.txt
.venv/bin/python bundle.py 1.0.0
```
