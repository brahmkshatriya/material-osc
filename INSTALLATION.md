# Installation

1. Download `material-osc.zip` and
   [`thumbfast.lua`](https://github.com/po5/thumbfast).
2. Unzip material-osc into the scripts folder and place `thumbfast.lua` beside
   `material-osc.lua`.

The usual mpv configuration directories are:

- Linux and macOS: `~/.config/mpv/`
- Windows: `%APPDATA%\\mpv\\`

The resulting layout should look like this:

```text
mpv/
├── mpv.conf (optional)
└── scripts/
    ├── material-osc.lua
    ├── thumbfast.lua
    └── material-osc/
        ├── GoogleSansFlex.ttf
        └── MaterialSymbolsRoundedUnfilled.ttf
```

For smoother rendering, add this to `mpv.conf`:

```conf
video-sync=display-resample
force-window=yes
```
