<p align="center">
  <img src="assets/logo.svg" alt="material-osc logo" width="128">
</p>

# material-osc

A quality-of-life upgrade for mpv that keeps the player lightweight while
making everyday controls easier to reach and nicer to use. material-osc brings
a polished Material-style interface, smooth animated feedback, automatic
directory playlists and much more.

I would say, you should fuck around and find out!

## Showcase

https://github.com/user-attachments/assets/65046da7-7d9e-4492-9e93-47650b8fc484

## Configuration

material-osc can be customized with a `material-osc.conf` file in mpv's
`script-opts` directory. You can also open file from **Right-click → Configurations**.

<details>
<summary>Appearance and controls</summary>

| Option | Default | Accepted values | Description |
| --- | --- | --- | --- |
| `dpi_scale` | `auto` | `auto` or `0.5`–`4` | Uses the display scale automatically or applies a fixed UI scale. |
| `vidscale` | `no` | `no`, `shrink`, `yes` | Scales the interface with the window height. `shrink` scales it down in windows shorter than `vidscale_reference`, `yes` also scales it up, and `no` keeps a fixed size. |
| `vidscale_reference` | `720` | Pixels, `100` or more | Window height at which the interface is shown at its normal size. |
| `vidscale_min` | `0.35` | `0.1`–`1` | Smallest scale factor `vidscale` can reach. |
| `accent_color` | `"#00bbff"` | Quoted six-digit RGB color | Sets the seekbar, selections, toggles, and other highlighted elements. |
| `context_menu` | `yes` | `yes`, `no` | Enables the material-osc context menu. When disabled, right-click and menu-key bindings remain available to mpv and other scripts. |
| `tooltip` | `yes` | `yes`, `no` | Enables tooltips for controls. |
| `show_mini_seekbar` | `no` | `yes`, `no` | Keeps a 1dp playback-progress line at the bottom while the main controls are hidden. |
| `show_empty_screen` | `yes` | `yes`, `no` | Shows the material-osc welcome screen when the playlist is empty. Set to `no` to leave the empty player unobstructed. |
| `screenshot_button` | `yes` | `yes`, `no` | Shows or hides the screenshot button in the playback controls. |
| `pip_button` | `yes` | `yes`, `no` | Shows or hides the Picture-in-Picture button in the playback controls. |
| `ontop_button` | `no` | `yes`, `no` | Shows a pin button in the playback controls that toggles always-on-top. It stays highlighted while pinned. |
| `info_button` | `no` | `yes`, `no` | Shows an info button in the playback controls that runs `info_mbtn_left_command`. |
| `info_mbtn_left_command` | `"script-binding stats/display-page-1-toggle"` | Any mpv input command | Command run by the info button. The default toggles the stats overlay. |
| `prev_next_beside_play` | `no` | `yes`, `no` | Shows previous and next in their own pill beside play/pause instead of in the playlist pill. |
| `window_controls` | `auto` | `auto`, `yes`, `no` | Shows window controls automatically for borderless and fullscreen windows, always, or never. |

##### Window controls

With `window_controls=auto`, material-osc provides minimize, maximize/restore,
and close buttons when mpv runs without native window decorations (`border=no`
in `mpv.conf`) or enters fullscreen.

Unless `geometry`/`autofit` is already set in `mpv.conf`, the script starts the
window at 66% of the screen height, with width calculated from the video's
aspect ratio, and disables automatic window resizing between files; see
`force_geometry` and `force_disable_auto_resize` below.

</details>

<details>
<summary>Playback and interaction</summary>

| Option | Default | Accepted values | Description |
| --- | --- | --- | --- |
| `mouse_timeout` | `2` | Seconds; `0` disables timeout | Controls how long the UI remains visible after pointer activity. |
| `show_on_mouse_move` | `no` | `yes`, `no` | With `yes`, movement anywhere reveals the UI. With `no`, use the bottom edge for playback controls or the top edge for window controls. |
| `single_click_actions_enabled` | `yes` | `yes`, `no` | Enables single-click play/pause and left/right edge seeking. Double-click fullscreen remains available when disabled. |
| `drag_border` | `16` | Pixels; `0` disables the band | Width of the band along the window edges that drags the window, also over controls. Elsewhere the window drags from empty space and the video, but not from buttons, sliders or open menus. |
| `seeking_zone_percentage` | `15` | `0`–`50` | Sets each fast-seek zone's width as a percentage of the window. |
| `seek_step_seconds` | `5` | Seconds; minimum `1` | Sets how far edge clicks and edge scrolling seek backward or forward. |
| `live_edge_offset_seconds` | `2` | Non-negative seconds or `-1` | After a live stream resumes from pausing or buffering, seeks this far behind the live edge. Set to `-1` to disable automatic catch-up. |
| `temporary_speed` | `2` | Playback rate greater than `0` | Sets the speed used while the `hold-double-speed` binding is held. |
| `show_remaining_time` | `no` | `yes`, `no` | Shows remaining time instead of elapsed time by default. The time display remains clickable to toggle modes. |
| `adjust_time_with_speed` | `yes` | `yes`, `no` | Adjusts elapsed, remaining, and total displayed time for the current playback speed. |
| `adjust_subtitle_position` | `yes` | `yes`, `no` | Moves bottom-aligned subtitles above the OSC while it is visible. Set to `no` to preserve mpv's configured `sub-pos`. |
| `max_volume_percentage` | `150` | Percentage; minimum `100` | Sets mpv's upper volume limit and the OSC volume range. Left at its default, material-osc preserves mpv's configured `volume-max` instead; set this explicitly to override it. |

</details>

<details>
<summary>Intro and outro chapter skipping</summary>

| Option | Default | Accepted values | Description |
| --- | --- | --- | --- |
| `skip_intro_outro_chapters` | `ask` | `yes`, `no`, `ask` | Controls detected local-media intro and outro chapters. |
| `skip_intro_detection_texts` | `intro,introduction,opening,op,opening theme` | Comma-separated text | Chapter-title text detected as an intro. |
| `skip_outro_detection_texts` | `outro,ending,end credits,credits,closing,ed` | Comma-separated text | Chapter-title text detected as an outro. |

Detection is case-insensitive. Each entry matches an exact chapter title or a
title prefix followed by whitespace, a colon, a hyphen, an en dash, or an em
dash. An empty list disables detection for that chapter type.

</details>

<details>
<summary>mpv behavior</summary>

| Option | Default | Accepted values | Description |
| --- | --- | --- | --- |
| `force_hwdec` | `no` | `yes`, `no` | With `no`, preserves mpv's configured `hwdec` value. Set to `yes` to opt into `hwdec=auto`; this may be unstable with some live streams and hybrid-GPU systems. |
| `force_display_resample` | `auto` | `auto`, `yes`, `no` | With `auto`, sets `video-sync=display-resample` unless you've already configured `video-sync` in `mpv.conf`. `yes` always sets it; `no` never does, always preserving mpv's configured value. |
| `force_force_window` | `auto` | `auto`, `yes`, `no` | With `auto`, sets `force-window=yes` (keeping an mpv window open even before a file is loaded) unless you've already configured `force-window` in `mpv.conf`. `yes` always sets it; `no` never does. |
| `force_geometry` | `auto` | `auto`, `yes`, `no` | With `auto`, applies material-osc's 66%-of-screen-height default window size unless you've already configured `geometry`/`autofit` in `mpv.conf`. `yes` always applies it; `no` never does. |
| `force_disable_auto_resize` | `auto` | `auto`, `yes`, `no` | With `auto`, sets `auto-window-resize=no` (keeping the window size when the next file has a different size or aspect ratio) unless you've already configured `geometry`/`autofit` in `mpv.conf`. `yes` always sets it; `no` never does, preserving mpv's configured `auto-window-resize`. |

</details>

<details>
<summary>Playlist</summary>

| Option | Default | Accepted values | Description |
| --- | --- | --- | --- |
| `directory_playlist` | `yes` | `yes`, `no` | Adds nearby video and audio files when opening a local file, unless a multi-item playlist already exists. |
| `directory_playlist_sort` | `name` | `name`, `newest`, `oldest` | Selects how automatically discovered directory entries are ordered. |

</details>

<details>
<summary>YouTube</summary>

| Option | Default | Accepted values | Description |
| --- | --- | --- | --- |
| `youtube_quality` | `auto` | `auto` or a vertical resolution such as `1080` | Sets the maximum quality used when initially loading YouTube videos. `auto` preserves mpv's configured `ytdl-format`. |

YouTube watch links containing a `list` parameter load the full playlist and
start at the linked video. To keep mpv's single-video behavior, explicitly set
`ytdl-raw-options=no-playlist=` in `mpv.conf`.

</details>

<details>
<summary>SponsorBlock</summary>

| Option | Default | Accepted values | Description |
| --- | --- | --- | --- |
| `sponsorblock_should_use` | `yes` | `yes`, `no` | Enables SponsorBlock loading, skipping, prompts, markers, voting, and submission for YouTube videos. |
| `sponsorblock_auto_skip_categories` | `...` | Comma-separated category IDs | Categories that are skipped automatically. |
| `sponsorblock_ignore_categories` | `...` | Comma-separated category IDs | Categories that are not loaded or acted upon. Ignore takes precedence when a category is also listed for auto-skip. |
| `sponsorblock_multicolored_segments` | `yes` | `yes`, `no` | Colors seekbar segments by category. When disabled, all segments use yellow. |
| `sponsorblock_show_submit` | `yes` | `yes`, `no` | Shows SponsorBlock segment marking, category, and submission controls. |
| `sponsorblock_show_voting` | `yes` | `yes`, `no` | Shows upvote and downvote controls after skipping a submitted SponsorBlock segment. |

SponsorBlock category lists accept `sponsor`, `selfpromo`, `exclusive_access`,
`interaction`, `intro`, `outro`, `preview`, `hook`, `music_offtopic`,
`poi_highlight`, and `filler`. Any supported category absent from both lists
defaults to Ask and shows persistent Skip/Dismiss controls.

SponsorBlock skip prompts are rendered beside the playlist and media title.
Their active skip button remains available after the rest of the controller
fades. Voting and Undo appear in the same inline row after a skip, while marking
and submission controls appear in the bottom-right control row. These actions
are also exposed as script bindings:

```conf
g script-binding material_osc/sponsorblock-set-segment
G script-binding material_osc/sponsorblock-submit-segment
h script-binding material_osc/sponsorblock-upvote
H script-binding material_osc/sponsorblock-downvote
```

</details>

### Video crop and aspect override

Open **Settings → Crop** for display modes and centered crop presets. The
aspect-ratio button in the Crop header opens fixed display-aspect overrides
such as 16:9, 21:9, and 4:3. Aspect overrides stretch the complete frame
without cropping; choosing a crop preset clears the override.

### Thumbnail previews

Thumbnail previews require [Thumbfast](https://github.com/po5/thumbfast). Install
`thumbfast.lua` in mpv's `scripts` directory alongside material-osc. Thumbnail
behavior, including support for network media, is configured through Thumbfast:

```conf
# script-opts/thumbfast.conf
network=yes
```

### Optional media-title parsing

If the Python [`guessit`](https://github.com/guessit-io/guessit) package is
installed, material-osc automatically uses it to clean local movie and episode
filenames. When `guessit` is unavailable, mpv's normal media title is used with
no additional setup or error message. Explicit `force-media-title` values are
always preserved.

## Building

The repository keeps the complete Material Symbols Rounded TTF for development.
Release builds automatically subset it to the icons referenced by the Lua sources.
The generated archive places renamed fonts under `fonts/` and the minified,
bundled Lua script under `scripts/`. The brand mark is implemented as a bundled
ASS drawing, so the archive is ready to extract into the mpv configuration
directory.

```bash
python -m venv .venv
.venv/bin/pip install -r requirements-build.txt
.venv/bin/python bundle.py 1.0.0
```
