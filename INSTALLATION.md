# Installation

1. Download the `material-osc.zip`
2. Unzip it, and paste it into the scripts folder.

The usual mpv configuration directories are:

- Linux and macOS: `~/.config/mpv/`
- Windows: `%APPDATA%\\mpv\\`

The resulting layout should look like this:

```text
mpv/
├── mpv.conf (optional)
└── scripts/
    ├── material-osc.lua
    └── material-osc/
        ├── GoogleSansFlex.ttf
        └── MaterialSymbolsRoundedUnfilled.ttf
```

For smoother rendering, add this to `mpv.conf`:

```conf
video-sync=display-resample
force-window=yes
```
