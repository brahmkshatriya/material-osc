# material-osc

A quality-of-life upgrade for mpv that keeps the player lightweight while
making everyday controls easier to reach and nicer to use. material-osc brings
a polished Material-style interface, smooth animated feedback, automatic
directory playlists, precise thumbnail previews, quick audio and subtitle
selection, and convenient playback-speed controls—all without replacing mpv.

## Showcase

https://github.com/user-attachments/assets/65046da7-7d9e-4492-9e93-47650b8fc484

## Configuration

material-osc can be customized with a `material-osc.conf` file in mpv's
`script-opts` directory. On Linux, create it with:

```bash
mkdir -p ~/.config/mpv/script-opts
$EDITOR ~/.config/mpv/script-opts/material-osc.conf
```

For example, the following configuration uses a fixed 1x UI scale and a
pastel-red accent color:

```conf
dpi_scale=1
accent_color=#FF6961
```

`dpi_scale` controls the size of the interface. Its default value, `auto`, uses
the display's reported scale; a number from `0.5` to `4` sets it explicitly.
`accent_color` controls highlighted UI elements and accepts a six-digit RGB hex
color. Set `context_menu=no` to disable the right-click context menu. Restart
mpv after changing the file. `mouse_timeout` controls how many seconds the
controls remain visible after pointer activity. `seek_step_seconds` controls
how many seconds the left and right edge actions seek backward or forward.
With `always_visible=yes`, pointer activity anywhere reveals the controls; they
still hide after `mouse_timeout` when the pointer is outside the controller.

On other platforms, place the same file at
`<mpv config directory>/script-opts/material-osc.conf`.

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
The generated archive places renamed fonts under `fonts/` and the bundled Lua
script under `scripts/`, ready to extract into the mpv configuration directory.

```bash
python -m venv .venv
.venv/bin/pip install -r requirements-build.txt
.venv/bin/python bundle.py 1.0.0
```
