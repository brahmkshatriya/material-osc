local options = require "mp.options"
local opts = {
  timeout = 2,
  always_visible = false,
  thumbnails = true,
  network_thumbnails = true,
  thumbnail_mpv_path = "mpv",
  directory_playlist = true,
  directory_playlist_sort = "newest",
  tooltip = true,
  dpi_scale = "auto",
  accent_color = "#00bbff",
  volume_max = 150
}
options.read_options(opts, "material-osc")

local assdraw = require "mp.assdraw"
local msg = require "mp.msg"
local utils = require "mp.utils"

local script_source = debug.getinfo(1, "S").source
if script_source:sub(1, 1) == "@" then script_source = script_source:sub(2) end
local script_dir = script_source:match("^(.*)[/\\][^/\\]-$") or "."
package.path = utils.join_path(script_dir, "../?.lua") .. ";" ..
  utils.join_path(script_dir, "?.lua") .. ";" .. package.path

local animation = require "src.core.animation"
local animation_coordinator_module = require "src.core.animation_coordinator"
local application_state = require "src.core.application_state"
local frame_runtime = require "src.core.frame_runtime"
local controller_module = require "src.core.controller"
local navigation_module = require "src.core.navigation"
local mpv_runtime_module = require "src.core.mpv_runtime"

local compose_module = require "src.ui.compose"
local playback_indicator_module = require "src.ui.components.playback_indicator"
local seekbar_renderer_module = require "src.ui.components.seekbar_renderer"
local loading_indicator = require "src.ui.loading_indicator"
local ui_renderer_module = require "src.ui.renderer"
local text_metrics_module = require "src.ui.text_metrics"
local tooltip_service_module = require "src.ui.tooltip_service"

local snapshot_module = require "src.services.snapshot"
local assets = require "src.services.assets"
local player_module = require "src.services.player"
local directory_playlist_module = require "src.services.directory_playlist"
local stream_quality_module = require "src.services.stream_quality"
local subtitle_loader_module = require "src.services.subtitle_loader"
local thumbnail_module = require "src.services.thumbnail_service"

mp.set_property("osc", "no")
mp.set_property_bool("auto-window-resize", false)

local controls_module = require "src.ui.components.controls"
local popups_module = require "src.ui.components.popups"
local playlist_module = require "src.ui.components.playlist"

local function create_app(services)
  local state, ui = services.state, services.ui
  local controls, popups = controls_module.new(services), popups_module.new(services)
  local node = {no_video_since = nil, no_video_opacity = 0}
  node.video = controls.VideoSurface()
  node.playlist_controls = playlist_module.new(services)
  node.seekbar = controls.SeekBar()
  node.controls = controls.ControlsRow()
  node.controller = ui.Column({
    modifier = ui.Modifier():fillMaxWidth():padding({all = ui.dp(12)}):align({
      horizontal = "starting", vertical = "bottom"
    }):pointerArea({name = "controller-area"}),
    children = {node.playlist_controls, node.seekbar, node.controls}
  })
  node.tooltip = controls.TooltipHost()
  node.chapter = popups.ChapterDialogHost()
  node.settings = popups.SettingsDialogHost()

  function node:update(snapshot)
    if snapshot.video_present or state.media.loading then
      self.no_video_since = nil
      self.no_video_opacity = 0
    else
      self.no_video_since = self.no_video_since or mp.get_time()
      local elapsed = mp.get_time() - self.no_video_since
      self.no_video_opacity = ui.clamp((elapsed - 0.12) / 0.28, 0, 1) * 0.66
    end
    self.controls:update(snapshot)
    self.playlist_controls:update(snapshot)
    local modal = state.playlist.open or state.playlist.animation:is_running() or
      state.chapter.open or state.chapter.animation.value > 0.001 or
      state.settings.open or state.settings.animation.value > 0.001
    self.tooltip:set_suppressed(state.controller.opacity.value <= 0 or modal)
    self.chapter:update(snapshot)
    self.settings:update(snapshot)
  end

  function node:draw(ass, root)
    ui.draw_node(self.video, ass, root)
    if self.no_video_opacity > 0 then
      local icon_size = math.min(root.w, root.h) * 0.34 / ui.dp(1)
      services.ui.draw_icon(ass, root.x + root.w / 2, root.y + root.h / 2,
        "music_note", "#FFFFFF", icon_size,
        services.ui.alpha(self.no_video_opacity), true)
    end
    if state.snapshot.buffering then services.loading.draw(ass) end
    services.playback_indicator:draw(ass, root)

    local playlist_visible = state.playlist.open or state.playlist.animation:is_running()
    local chapter_visible = state.chapter.open or state.chapter.animation.value > 0.001
    local settings_visible = state.settings.open or state.settings.animation.value > 0.001
    local pointer_x, pointer_y = state.pointer.x, state.pointer.y
    if playlist_visible or chapter_visible or settings_visible then
      state.pointer.x, state.pointer.y = -1, -1
    end
    if state.controller.opacity.value > 0 then
      state.controller.bounds = ui.draw_node(self.controller, ass, root)
    else
      state.controller.bounds = nil
      state.volume.popup_bounds, state.volume.button_bounds = nil, nil
    end
    state.pointer.x, state.pointer.y = pointer_x, pointer_y

    ui.draw_node(self.tooltip, ass, root)
    if playlist_visible then self.playlist_controls:draw_expanded(ass, root)
    elseif chapter_visible then ui.draw_node(self.chapter, ass, root)
    elseif settings_visible then ui.draw_node(self.settings, ass, root) end
  end

  return node
end

local asset_paths = assets.initialize({script_dir = script_dir, utils = utils, msg = msg})

local osd = mp.create_osd_overlay("ass-events")
local render

local runtime = application_state.new({
  opts = opts,
  animation = animation,
  now_ms = function() return mp.get_time() * 1000 end
})

local thumbnail_service
local draw_thumbnail_preview

local effects = frame_runtime.effects.new({runtime = runtime, msg = msg})
local enqueue_effect = function(...) return effects:enqueue(...) end

local lerp = animation.lerp
local smooth_step = animation.smooth_step
local ui_renderer = ui_renderer_module.new({runtime = runtime, opts = opts})
local clamp = function(value, minimum, maximum)
  return ui_renderer:clamp(value, minimum, maximum)
end
local dp = function(value) return ui_renderer:dp(value) end
mp.set_property("geometry", "x66%")

local text_metrics = text_metrics_module.new({dp = dp, default_size = 24})
local truncate_utf8 = text_metrics.truncate
local text_intrinsic_width = text_metrics.width
local truncate_utf8_to_width = text_metrics.truncate_to_width

local configured_volume_max = math.max(100, tonumber(opts.volume_max) or 150)
mp.set_property_number("volume-max", configured_volume_max)

local ass_color = function(hex) return ui_renderer:ass_color(hex) end
local ass_alpha_for_opacity = function(opacity) return ui_renderer:alpha(opacity) end

local pointer = frame_runtime.pointer.new(runtime)
local mouse_in = function(box) return pointer:contains(box) end
local hitbox_at_cursor = function() return pointer:hitbox_at_cursor() end

local player = player_module.new({
  runtime = runtime, mp = mp, clamp = clamp,
  render = function() render() end
})
local format_time = function(value) return player:format_time(value) end
local chapter_name_at = function(value) return player:chapter_at(value) end
local seek_pos_from_mouse = function(box) return player:seek_position(box) end
local seek_to_pos = function(value) return player:seek(value) end

local navigation = navigation_module.new({
  runtime = runtime, mp = mp, dp = dp,
  render = function() if render then render() end end
})
local function set_chapter_dialog_open(open) navigation:set_dialog_open("chapter", open) end
local function set_playlist_dialog_open(open) navigation:set_dialog_open("playlist", open) end
local function set_subtitle_dialog_open(open) navigation:set_dialog_open("subtitle", open) end
local function set_audio_dialog_open(open) navigation:set_dialog_open("audio", open) end
local function set_settings_dialog_open(open) navigation:set_dialog_open("settings", open) end
local function set_settings_page(page) navigation:set_settings_page(page) end
local function toggle_subtitles() navigation:toggle_subtitles() end
local function cycle_subtitle(direction) navigation:cycle_subtitle(direction) end

local subtitle_loader = subtitle_loader_module.new({
  render = function(...) return render(...) end
})
local open_subtitle_file_picker = subtitle_loader.open_file_picker
local open_subtitle_link_picker = subtitle_loader.open_link_picker

local stream_quality = stream_quality_module.new({
  runtime = runtime, utils = utils,
  render = function(...) return render(...) end,
  set_settings_page = set_settings_page
})
local directory_playlist = directory_playlist_module.new({
  mp = mp, utils = utils, opts = opts
})
local function select_stream_quality(item) stream_quality:select(item) end
local function attach_ytdl_caption(item) stream_quality:attach_caption(item) end


local is_buffering = function() return player:is_buffering() end
local preview_seek_to_mouse = function(box) return player:preview_seek(box) end

local draw_box = function(...) return ui_renderer:draw_box(...) end
local draw_round_box = function(...) return ui_renderer:draw_round_box(...) end
local draw_rect = function(...) return ui_renderer:draw_rect(...) end
local draw_text = function(...) return ui_renderer:draw_text(...) end
local draw_shadowed_text = function(...) return ui_renderer:draw_shadowed_text(...) end
local draw_icon = function(...) return ui_renderer:draw_icon(...) end

local draw_loading_shape_morph = loading_indicator.new({
  started_ms = function() return runtime.loading.started_ms end,
  viewport = function() return runtime.viewport end,
  dp = dp,
  color = function() return ass_color(opts.accent_color) end,
  alpha = ass_alpha_for_opacity
})

local draw_seekbar

local default_text_font = ui_renderer.default_text_font
local icon_text_size = ui_renderer.icon_text_size
local normal_text_size = ui_renderer.normal_text_size

thumbnail_service, draw_thumbnail_preview = thumbnail_module.new({
  thumbnail_state = runtime.thumbnail, viewport = runtime.viewport,
  get_snapshot = function() return runtime.snapshot end,
  opts = opts, utils = utils, msg = msg, dp = dp, clamp = clamp,
  format_time = format_time, chapter_name_at = chapter_name_at,
  enqueue_effect = enqueue_effect,
  render = function(...) return render(...) end,
  draw_box = function(...) return draw_box(...) end,
  draw_text = function(...) return draw_text(...) end,
  draw_loading_shape_morph = draw_loading_shape_morph,
  text_intrinsic_width = text_intrinsic_width,
  truncate_utf8_to_width = truncate_utf8_to_width
})
draw_seekbar = seekbar_renderer_module.new({
  runtime = runtime, opts = opts, dp = dp, clamp = clamp,
  mouse_in = mouse_in, draw_rect = draw_rect, draw_box = draw_box,
  seek_pos_from_mouse = seek_pos_from_mouse,
  draw_thumbnail_preview = draw_thumbnail_preview,
  enqueue_effect = enqueue_effect, thumbnail_service = thumbnail_service
})

local tooltip_service = tooltip_service_module.new({
  runtime = runtime, dp = dp, clamp = clamp,
  enabled = function() return opts.tooltip end,
  text_width = text_intrinsic_width
})
local function request_tooltip(...) return tooltip_service:request(...) end
local compose = compose_module.new({
  runtime = runtime, dp = dp, mouse_in = mouse_in,
  draw_box = draw_box, draw_icon = draw_icon, draw_text = draw_text,
  text_intrinsic_width = text_intrinsic_width,
  request_tooltip = request_tooltip,
  default_text_font = default_text_font,
  icon_text_size = icon_text_size, normal_text_size = normal_text_size
})
local Rect, Modifier = compose.Rect, compose.Modifier
local apply_modifier_size, measure_node = compose.apply_modifier_size, compose.measure_node
local draw_node = compose.draw_node
local IconButton, TextItem = compose.IconButton, compose.TextItem
local Visibility, Row, Column, Pill = compose.Visibility, compose.Row, compose.Column, compose.Pill
local services = {
  state = runtime,
  config = {
    opts = opts, tooltip_delay = tooltip_service.delay,
    tooltip_slide_distance = tooltip_service.slide_distance,
    volume_max = configured_volume_max
  },
  platform = {msg = msg, utils = utils},
  effects = {
    render = function(...) return render(...) end,
    enqueue = enqueue_effect
  },
  ui = {
    dp = dp, clamp = clamp, smooth_step = smooth_step, lerp = lerp,
    alpha = ass_alpha_for_opacity, draw_rect = draw_rect, draw_box = draw_box,
    draw_round_box = draw_round_box,
    draw_icon = draw_icon, draw_text = draw_text, draw_seekbar = draw_seekbar,
    draw_shadowed_text = draw_shadowed_text,
    draw_loading = draw_loading_shape_morph, mouse_in = mouse_in,
    truncate_utf8 = truncate_utf8, format_time = format_time,
    text_width = text_intrinsic_width,
    default_text_font = default_text_font, Modifier = Modifier, Rect = Rect,
    apply_modifier_size = apply_modifier_size, measure_node = measure_node,
    draw_node = draw_node, IconButton = IconButton, TextItem = TextItem,
    Visibility = Visibility, Row = Row, Column = Column, Pill = Pill
  },
  player = {
    snapshot = function() return runtime.snapshot end,
    preview_seek_to_mouse = preview_seek_to_mouse,
    seek_pos_from_mouse = seek_pos_from_mouse, seek_to_pos = seek_to_pos,
    select_stream_quality = select_stream_quality,
    open_subtitle_file_picker = open_subtitle_file_picker,
    open_subtitle_link_picker = open_subtitle_link_picker,
    attach_ytdl_caption = attach_ytdl_caption
  },
  navigation = {
    set_playlist_open = set_playlist_dialog_open,
    set_chapter_open = set_chapter_dialog_open,
    set_subtitle_open = set_subtitle_dialog_open,
    set_audio_open = set_audio_dialog_open,
    set_settings_open = set_settings_dialog_open,
    set_settings_page = set_settings_page,
    toggle_subtitles = toggle_subtitles, cycle_subtitle = cycle_subtitle
  }
}
local playback_indicator = playback_indicator_module.new({
  state = runtime.playback_indicator, mp = mp, ui = services.ui,
  render = function() render() end
})
services.playback_indicator = playback_indicator
services.loading = {draw = draw_loading_shape_morph}
local app = create_app(services)

local read_player_snapshot = snapshot_module.reader({
  runtime = runtime, format_time = format_time,
  friendly_quality_label = stream_quality_module.quality_label,
  configured_volume_max = configured_volume_max, is_buffering = is_buffering
})
local animation_coordinator = animation_coordinator_module.new({
  runtime = runtime, mouse_in = mouse_in, tooltip = tooltip_service
})
local function update_animation_targets(now)
  animation_coordinator:update(now)
end

local controller
local runtime_host = mpv_runtime_module.new({
  state = runtime, mp = mp, navigation = navigation,
  playback_indicator = playback_indicator,
  thumbnail = thumbnail_service, stream_quality = stream_quality,
  directory_playlist = directory_playlist,
  controller = function() return controller end,
  render = function() render() end
})
local function handle_snapshot(snapshot, now)
  playback_indicator:observe(snapshot, now)
  if #snapshot.chapters == 0 then runtime.chapter.open = false end
  if #snapshot.audio_items < 2 then runtime.audio.open = false end
  if snapshot.playlist_count == 0 then runtime.playlist.open = false end
end

local renderer = frame_runtime.renderer.new({
  runtime = runtime,
  navigation = navigation,
  now = function() return mp.get_time() end,
  read_snapshot = read_player_snapshot,
  on_snapshot = handle_snapshot,
  update_animations = update_animation_targets,
  tooltip = tooltip_service,
  effects = effects,
  begin_frame = function(viewport)
    osd.res_x, osd.res_y = viewport.w, viewport.h
    return assdraw.ass_new()
  end,
  app = function() return app end,
  root_bounds = function(viewport)
    return Rect({x = 0, y = 0, w = viewport.w, h = viewport.h})
  end,
  disable_dialog = function(binding) mp.disable_key_bindings(binding) end,
  present = function(ass) osd.data = ass.text; osd:update() end,
  update_mouse_area = function() runtime_host:update_mouse_area() end
})
render = function() renderer:render() end

local function recreate_app() app = create_app(services) end
controller = controller_module.new({
  runtime = runtime, mp = mp, opts = opts, navigation = navigation,
  thumbnail = thumbnail_service, mouse_in = mouse_in,
  hitbox_at_cursor = hitbox_at_cursor,
  render = function() render() end, recreate_app = recreate_app
})

runtime_host:start()
