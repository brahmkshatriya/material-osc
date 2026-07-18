# material-osc

A Material-style on-screen controller for mpv.

Opening a local media file automatically adds the other video and audio files
in the same directory to the playlist, ordered newest-modified first. An
existing multi-item playlist is left unchanged. To disable this behavior or
reverse the order, use `script-opts/material-osc.conf`:

```conf
directory_playlist=no
directory_playlist_sort=oldest
```

## Recommended mpv configuration

For a smoother UI, add the following options to your `mpv.conf`:

```conf
video-sync=display-resample
force-window=yes
```

The script disables automatic window resizing and starts the window at 66% of
the screen height. Its width is calculated from the video's aspect ratio.

On Windows, thumbnail previews use `%TEMP%\material-osc` and native mpv named
pipes. If the helper process cannot find `mpv.exe`, set this in
`script-opts/material-osc.conf`:

```conf
thumbnail_mpv_path=C:\path\to\mpv.exe
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
