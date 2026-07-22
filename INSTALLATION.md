# Installation

1. Download `material-osc.zip` and
   [`thumbfast.lua`](https://github.com/po5/thumbfast).
2. Unzip `material-osc.zip` into your mpv configuration directory, then place
   `thumbfast.lua` beside `material-osc.lua` in the `scripts` directory.

The usual mpv configuration directories are:

- Linux and macOS: `~/.config/mpv/`
- Windows: `%APPDATA%\mpv\`

The resulting layout should look like this:

```text
📁 mpv
├── mpv.conf (optional)
├── 📁 fonts
│   ├── material-osc_icons.otf
│   └── material-osc_google_sans_flex.ttf
├── 📁 scripts
│   ├── material-osc.lua
│   └── thumbfast.lua
└── 📁 script-opts (optional)
    ├── material-osc.conf
    └── thumbfast.conf
```

For smoother experience, add this to `mpv.conf`:

```conf
video-sync=display-resample
force-window=yes
```
