local options = require "mp.options"
local opts = {
  mouse_timeout = 2,
  show_on_mouse_move = false,
  single_click_actions_enabled = true,
  seeking_zone_percentage = 15,
  show_mini_seekbar = false,
  window_controls = "auto",
  youtube_quality = "auto",
  force_hwdec = true,
  directory_playlist = true,
  directory_playlist_sort = "name",
  context_menu = true,
  tooltip = true,
  seek_step_seconds = 5,
  dpi_scale = "auto",
  accent_color = "#00bbff",
  max_volume_percentage = 150
}
local option_defaults = {}
for name, value in pairs(opts) do option_defaults[name] = value end
local options_update_handler
local config_watcher
local function normalize_option_values(values)
  for name, default in pairs(option_defaults) do
    local value = values[name]
    if type(default) == "string" and type(value) == "string" then
      local quote = value:sub(1, 1)
      if (quote == '"' or quote == "'") and value:sub(-1) == quote then
        values[name] = value:sub(2, -2)
      end
    end
  end
  values.seeking_zone_percentage = math.max(0,
    math.min(50, tonumber(values.seeking_zone_percentage) or 15))
  values.max_volume_percentage = math.max(100,
    tonumber(values.max_volume_percentage) or 150)
  values.window_controls = tostring(values.window_controls or "auto"):lower()
  if values.window_controls ~= "yes" and values.window_controls ~= "no" and
    values.window_controls ~= "auto" then
    values.window_controls = "auto"
  end
  local youtube_quality = tostring(values.youtube_quality or "auto"):lower()
  local height = youtube_quality:match("^(%d+)p?$")
  values.youtube_quality = height and tostring(math.max(1,
    math.floor(tonumber(height)))) or "auto"
  return values
end
options.read_options(opts, "material-osc", function(changed)
  normalize_option_values(opts)
  if config_watcher then config_watcher:preserve(changed) end
  if options_update_handler then options_update_handler(changed) end
end)
normalize_option_values(opts)

local configured_hwdec = mp.get_property("hwdec", "no") or "no"
local function apply_force_hwdec()
  mp.set_property("hwdec", opts.force_hwdec and "auto" or configured_hwdec)
end
apply_force_hwdec()

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
local config_watcher_module = require "src.services.config_watcher"

local compose_module = require "src.ui.compose"
local context_menu_module = require "src.ui.components.context_menu"
local media_information_close_module =
  require "src.ui.components.media_information_close"
local update_dialog_module = require "src.ui.components.update_dialog"
local playback_indicator_module = require "src.ui.components.playback_indicator"
local edge_seek_module = require "src.ui.components.edge_seek"
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
local shader_loader_module = require "src.services.shader_loader"
local thumbnail_module = require "src.services.thumbnail_service"
local bookmark_service_module = require "src.services.bookmark_service"
local context_actions_module = require "src.services.context_actions"
local update_service_module = require "src.services.update_service"

local manual_stream_quality_reload = false
-- Run before mpv's built-in ytdl hook, which uses priority 10.
mp.add_hook("on_load", 5, function()
  if manual_stream_quality_reload then
    manual_stream_quality_reload = false
    return
  end
  if opts.youtube_quality == "auto" then return end
  local path = mp.get_property("stream-open-filename", "") or
    mp.get_property("path", "") or ""
  if not stream_quality_module.supports_youtube(path) then return end
  local quality = opts.youtube_quality
  local format = "bestvideo[height<=" .. quality ..
    "]+bestaudio/best[height<=" .. quality .. "]"
  mp.set_property("file-local-options/ytdl-format", format)
end)

mp.set_property("osc", "no")
mp.set_property_bool("auto-window-resize", false)

local controls_module = require "src.ui.components.controls"
local popups_module = require "src.ui.components.popups"
local playlist_module = require "src.ui.components.playlist"

local function create_app(services)
  local state, ui = services.state, services.ui
  local controls, popups = controls_module.new(services), popups_module.new(services)
  local node = {
    no_video_since = nil,
    no_video_opacity = 0,
    snapshot_revision = nil
  }
  node.video = controls.VideoSurface()
  node.playlist_controls = playlist_module.new(services)
  node.seekbar = controls.SeekBar()
  node.controls = controls.ControlsRow()
  node.window_drag_area = controls.WindowDragArea()
  node.window_controls = controls.WindowControls()
  node.controller = ui.Column({
    modifier = ui.Modifier():fillMaxWidth():padding({all = ui.dp(12)}):align({
      horizontal = "starting", vertical = "bottom"
    }):pointerArea({name = "controller-area"}),
    children = {node.playlist_controls, node.seekbar, node.controls}
  })
  node.tooltip = controls.TooltipHost()
  node.chapter = popups.ChapterDialogHost()
  node.settings = popups.SettingsDialogHost()
  node.context_menu = context_menu_module.new(services)
  node.media_information_close = media_information_close_module.new(services)
  node.update_dialog = update_dialog_module.new(services)
  node.edge_seek = edge_seek_module.new(services)
  local visibility

  function node:update(snapshot)
    local static_changed = self.snapshot_revision ~= snapshot._revision
    self.snapshot_revision = snapshot._revision
    self:update_video_presence(snapshot)
    self.controls:update(snapshot, static_changed)
    if static_changed then self.window_controls:update(snapshot) end
    if static_changed or state.playlist.open or
      state.playlist.animation:is_running() or
      state.playlist.width_animation:is_running() or
      state.playlist.height_animation:is_running() then
      self.playlist_controls:update(snapshot)
    end
    local context_visible = state.context_menu.open or
      state.context_menu.pending_x ~= nil or
      state.context_menu.animation:is_running() or
      state.context_menu.animation.value > 0.001 or
      state.context_menu.width_animation:is_running() or
      state.context_menu.height_animation:is_running()
    local modal = state.update.open or context_visible or state.playlist.open or
      state.playlist.animation:is_running() or
      state.chapter.open or state.chapter.animation.value > 0.001 or
      state.settings.open or state.settings.animation.value > 0.001
    self.tooltip:set_suppressed(state.controller.opacity.value <= 0 or modal)
    self.chapter:update(snapshot)
    self.settings:update(snapshot)
    if context_visible then self.context_menu:update(snapshot) end
    self.media_information_close:update()
    if state.update.open then self.update_dialog:update(snapshot) end
  end

  function node:update_video_presence(snapshot)
    if snapshot.video_present or state.media.loading then
      self.no_video_since = nil
      self.no_video_opacity = 0
    else
      self.no_video_since = self.no_video_since or mp.get_time()
      local elapsed = mp.get_time() - self.no_video_since
      self.no_video_opacity = ui.clamp((elapsed - 0.12) / 0.28, 0, 1) * 0.66
    end
  end

  function node:update_dynamic(snapshot)
    self:update_video_presence(snapshot)
    self.controls:update(snapshot, false)
  end

  function node:update_interaction(snapshot)
    self:update_dynamic(snapshot)
    local playlist_visible, chapter_visible, settings_visible, context_visible =
      visibility()
    if playlist_visible or state.playlist.width_animation:is_running() or
      state.playlist.height_animation:is_running() then
      self.playlist_controls:update(snapshot)
    end
    if chapter_visible then self.chapter:update(snapshot) end
    if settings_visible then self.settings:update(snapshot) end
    if context_visible then self.context_menu:update(snapshot, false) end
    local modal = state.update.open or playlist_visible or chapter_visible or
      settings_visible or context_visible
    self.tooltip:set_suppressed(state.controller.opacity.value <= 0 or modal)
    if state.update.open then self.update_dialog:update(snapshot) end
  end

  visibility = function()
    local playlist_visible =
      state.playlist.open or state.playlist.animation:is_running()
    local chapter_visible =
      state.chapter.open or state.chapter.animation.value > 0.001
    local settings_visible =
      state.settings.open or state.settings.animation.value > 0.001
    local context_visible = state.context_menu.open or
      state.context_menu.pending_x ~= nil or
      state.context_menu.animation:is_running() or
      state.context_menu.animation.value > 0.001 or
      state.context_menu.width_animation:is_running() or
      state.context_menu.height_animation:is_running()
    return playlist_visible, chapter_visible, settings_visible, context_visible
  end

  local function modal_is_open()
    if state.update.open or state.context_menu.open or
      state.context_menu.pending_x ~= nil then
      return true
    end
    for _, name in ipairs({
      "playlist", "chapter", "subtitle", "audio", "settings"
    }) do
      if state[name].open then return true end
    end
    return false
  end

  function node:draw_base(ass, root)
    ui.draw_node(self.video, ass, root)
    local playlist_visible, chapter_visible, settings_visible, context_visible =
      visibility()
    local pointer_x, pointer_y = state.pointer.x, state.pointer.y
    if playlist_visible or chapter_visible or settings_visible or
      context_visible then
      state.pointer.x, state.pointer.y = -1, -1
    end

    if state.controller.opacity.value > 0 then
      state.controller.bounds = ui.draw_node(self.controller, ass, root)
    else
      local size = ui.measure_node(self.controller, root)
      state.controller.bounds = ui.Rect({
        x = root.x, y = root.y2 - size.h, w = size.w, h = size.h
      })
      state.volume.popup_bounds, state.volume.button_bounds = nil, nil
    end

    local show_window_controls = opts.window_controls == "yes" or
      (opts.window_controls == "auto" and
        (not state.snapshot.window_border or not state.snapshot.title_bar or state.snapshot.fullscreen))
    if show_window_controls then
      local controls_size = ui.measure_node(self.window_controls, root)
      ui.draw_node(self.window_drag_area, ass, root)
      state.window_controls.reveal_bounds = ui.Rect({
        x = root.x, y = root.y, w = root.w, h = controls_size.h
      })
      if state.controller.opacity.value > 0 then
        state.window_controls.bounds =
          ui.draw_node(self.window_controls, ass, root)
      else
        state.window_controls.bounds = ui.Rect({
          x = root.x2 - controls_size.w,
          y = root.y,
          w = controls_size.w,
          h = controls_size.h
        })
      end
    else
      state.window_controls.bounds, state.window_controls.reveal_bounds = nil, nil
    end
    state.pointer.x, state.pointer.y = pointer_x, pointer_y
  end

  function node:draw_dynamic(ass, root)
    if opts.show_mini_seekbar then
      local duration = state.snapshot.duration or 0
      local opacity = 1 - ui.clamp(state.controller.opacity.value, 0, 1)
      if duration > 0 and opacity > 0.001 then
        local height = ui.dp(1)
        local progress = ui.clamp(
          (state.snapshot.position or 0) / duration, 0, 1)
        services.ui.draw_box(ass, root.x, root.y2 - height,
          root.x2, root.y2, 0, "#282828", services.ui.alpha(opacity * 0.7), true)
        services.ui.draw_box(ass, root.x, root.y2 - height,
          root.x + root.w * progress, root.y2, 0, opts.accent_color,
          services.ui.alpha(opacity), true)
      end
    end
    if state.controller.opacity.value > 0 then
      if self.seekbar.bounds then self.seekbar:draw(ass, self.seekbar.bounds) end
      self.controls:draw_dynamic(ass)
    end
  end

  function node:draw_interaction(ass, root)
    local pointer_x, pointer_y = state.pointer.x, state.pointer.y
    -- A closing spring can cross zero and rebound before settling. Visual
    -- visibility follows that motion, but hover ownership must not: once a
    -- popup starts closing, immediately hand hover back to the controls below
    -- it and keep it there throughout the spring tail.
    if modal_is_open() then
      state.pointer.x, state.pointer.y = -1, -1
    end
    if state.controller.opacity.value > 0 then
      ui.draw_node(self.controller, ass, root)
    end
    state.pointer.x, state.pointer.y = pointer_x, pointer_y

    if self.no_video_opacity > 0 then
      local icon_size = math.min(root.w, root.h) * 0.34 / ui.dp(1)
      services.ui.draw_icon(ass, root.x + root.w / 2, root.y + root.h / 2,
        "music_note_2", "#FFFFFF", icon_size,
        services.ui.alpha(self.no_video_opacity), true)
    end
    if state.snapshot.buffering then services.loading.draw(ass) end
    services.playback_indicator:draw(ass, root)
    self.edge_seek:draw(ass, root)
    ui.draw_node(self.tooltip, ass, root)
    ui.draw_node(self.media_information_close, ass, root)
  end

  function node:draw_modal(ass, root)
    local playlist_visible, chapter_visible, settings_visible, context_visible =
      visibility()
    if playlist_visible then self.playlist_controls:draw_expanded(ass, root)
    elseif chapter_visible then ui.draw_node(self.chapter, ass, root)
    elseif settings_visible then ui.draw_node(self.settings, ass, root) end
    if context_visible then ui.draw_node(self.context_menu, ass, root) end
    if state.update.open then ui.draw_node(self.update_dialog, ass, root) end
  end

  function node:draw_layer(layer, ass, root)
    if layer == "base" then return self:draw_base(ass, root) end
    if layer == "dynamic" then return self:draw_dynamic(ass, root) end
    if layer == "interaction" then return self:draw_interaction(ass, root) end
    if layer == "modal" then return self:draw_modal(ass, root) end
  end

  function node:needs_continuous_render()
    return self.no_video_since ~= nil and self.no_video_opacity < 0.66
  end

  function node:has_visible_overlay()
    if opts.show_mini_seekbar and (state.snapshot.duration or 0) > 0 and
      state.controller.opacity.value < 0.999 then
      return true
    end
    if state.snapshot.buffering or self.no_video_opacity > 0 or
      state.controller.opacity.value > 0.001 or
      state.playback_indicator.opacity.value > 0.001 or
      state.edge_seek.left.opacity.value > 0.001 or
      state.edge_seek.right.opacity.value > 0.001 or
      state.tooltip.opacity.value > 0.001 or state.update.open or
      self.media_information_close.visible then
      return true
    end
    if state.context_menu.open or state.context_menu.pending_x ~= nil or
      state.context_menu.animation.value > 0.001 then
      return true
    end
    for _, name in ipairs({"playlist", "chapter", "subtitle", "audio", "settings"}) do
      if state[name].open or state[name].animation.value > 0.001 then return true end
    end
    return false
  end

  return node
end

local asset_paths = assets.initialize({script_dir = script_dir, utils = utils, msg = msg})

local overlay_layers = {}
local performance = os.getenv("MATERIAL_OSC_PROFILE") and {
  full_frames = 0,
  visual_frames = 0,
  dynamic_frames = 0,
  interaction_frames = 0,
  overlay_updates = 0,
  bytes = 0
} or nil
for index, name in ipairs({"base", "dynamic", "interaction", "modal"}) do
  local overlay = mp.create_osd_overlay("ass-events")
  overlay.z = 1000 + index
  overlay_layers[name] = {
    overlay = overlay,
    active = false,
    presented_res_x = nil,
    presented_res_y = nil
  }
end
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
local edge_seek_top_inset = function() return dp(64) end
mp.set_property("geometry", "x66%")

local text_metrics = text_metrics_module.new({
  dp = dp,
  scale_font = function(value) return ui_renderer:scale_font(value) end,
  default_size = 24
})
local truncate_utf8 = text_metrics.truncate
local text_intrinsic_width = text_metrics.width
local truncate_utf8_to_width = text_metrics.truncate_to_width

local max_volume_percentage = math.max(
  100, tonumber(opts.max_volume_percentage) or 150)
mp.set_property_number("volume-max", max_volume_percentage)

local ass_color = function(hex) return ui_renderer:ass_color(hex) end
local ass_alpha_for_opacity = function(opacity) return ui_renderer:alpha(opacity) end

local pointer = frame_runtime.pointer.new(runtime)
local mouse_in = function(box) return pointer:contains(box) end
local hitbox_at_cursor = function() return pointer:hitbox_at_cursor() end

local player = player_module.new({
  runtime = runtime, mp = mp, clamp = clamp,
  render = function() render(false, "dynamic") end
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

local function set_context_close_anchor(click_x, click_y)
  local bounds = runtime.context_menu.bounds
  if bounds and click_x and click_y then
    runtime.context_menu.close_x = clamp(click_x, bounds.x1, bounds.x2)
    runtime.context_menu.close_y = clamp(click_y, bounds.y1, bounds.y2)
  else
    runtime.context_menu.close_x, runtime.context_menu.close_y = nil, nil
  end
end

local function close_context_menu(click_x, click_y)
  if not runtime.context_menu.open and
    not runtime.context_menu.pending_x then return end
  local was_switching = runtime.context_menu.pending_x ~= nil
  runtime.context_menu.pending_x, runtime.context_menu.pending_y = nil, nil
  if click_x and click_y then
    set_context_close_anchor(click_x, click_y)
  elseif not was_switching then
    set_context_close_anchor(nil, nil)
  end
  runtime.context_menu.open = false
  mp.disable_key_bindings("material-osc-context-menu")
  if render then render() end
end

local function open_context_menu(x, y)
  if not opts.context_menu then return end
  if runtime.update.open then return end
  if runtime.context_menu.open or runtime.context_menu.pending_x then
    runtime.context_menu.pending_x, runtime.context_menu.pending_y = x, y
    set_context_close_anchor(x, y)
    runtime.context_menu.open = false
    runtime.context_menu.animation:set_target(0, mp.get_time(), 0.10)
    mp.enable_key_bindings("material-osc-context-menu")
    if render then render() end
    return
  end
  navigation:close_others(nil)
  navigation:cancel_pointer_gestures()
  runtime.context_menu.open = true
  runtime.context_menu.x, runtime.context_menu.y = x, y
  runtime.context_menu.pending_x, runtime.context_menu.pending_y = nil, nil
  runtime.context_menu.close_x, runtime.context_menu.close_y = nil, nil
  mp.enable_key_bindings("material-osc-context-menu")
  if render then render() end
end

local subtitle_loader = subtitle_loader_module.new({
  render = function(...) return render(...) end
})
local open_subtitle_file_picker = subtitle_loader.open_file_picker
local open_subtitle_link_picker = subtitle_loader.open_link_picker
local open_secondary_subtitle_file_picker = subtitle_loader.open_secondary_file_picker
local open_secondary_subtitle_link_picker = subtitle_loader.open_secondary_link_picker
local shader_loader = shader_loader_module.new({
  mp = mp, utils = utils, msg = msg,
  render = function(...) return render(...) end
})

local controller
local bookmark_service = bookmark_service_module.new({
  mp = mp, utils = utils, format_time = format_time,
  render = function(...) return render(...) end,
  set_input_active = function(active)
    runtime.controller.input_suppressed = active
    if runtime.timers.hide then
      runtime.timers.hide:kill()
      runtime.timers.hide = nil
    end
    if controller then
      if active then controller:animate_visibility(false)
      else controller:show() end
    elseif render then
      runtime.controller.visible = not active
      runtime.controller.opacity:set_target(active and 0 or 1, mp.get_time(), 0.18)
      render()
    end
  end
})
local context_actions = context_actions_module.new({
  mp = mp, utils = utils, format_time = format_time,
  bookmarks = bookmark_service, opts = opts, properties = runtime.properties,
  render = function(...) return render(...) end
})

local stream_quality = stream_quality_module.new({
  runtime = runtime, utils = utils,
  render = function(...) return render(...) end,
  set_settings_page = set_settings_page,
  before_quality_reload = function()
    manual_stream_quality_reload = true
  end
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
local draw_boxes = function(...) return ui_renderer:draw_boxes(...) end
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
  utils = utils, msg = msg, dp = dp, clamp = clamp,
  format_time = format_time, chapter_name_at = chapter_name_at,
  enqueue_effect = enqueue_effect,
  render = function(...) return render(...) end,
  draw_box = function(...) return draw_box(...) end,
  draw_text = function(...) return draw_text(...) end,
  text_intrinsic_width = text_intrinsic_width,
  truncate_utf8_to_width = truncate_utf8_to_width
})
draw_seekbar = seekbar_renderer_module.new({
  runtime = runtime, opts = opts, dp = dp, clamp = clamp,
  mouse_in = mouse_in, draw_rect = draw_rect, draw_box = draw_box,
  draw_boxes = draw_boxes,
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
local content_bounds = compose.content_bounds
local draw_node = compose.draw_node
local set_render_pass, is_render_pass =
  compose.set_render_pass, compose.is_render_pass
local IconButton, TextItem = compose.IconButton, compose.TextItem
local Visibility, Row, Column, Pill = compose.Visibility, compose.Row, compose.Column, compose.Pill
local updater = update_service_module.new({
  state = runtime, mp = mp, utils = utils, msg = msg,
  script_path = script_source, font_dir = asset_paths.release_font_dir,
  render = function() if render then render() end end
})
local services = {
  state = runtime,
  updater = updater,
  bookmarks = bookmark_service,
  context_actions = context_actions,
  close_context_menu = close_context_menu,
  config = {
    opts = opts, tooltip_delay = tooltip_service.delay,
    tooltip_slide_distance = tooltip_service.slide_distance,
    max_volume_percentage = max_volume_percentage
  },
  platform = {msg = msg, utils = utils},
  effects = {
    render = function() return render(false, "interaction") end,
    enqueue = enqueue_effect
  },
  ui = {
    dp = dp, clamp = clamp, smooth_step = smooth_step, lerp = lerp,
    dpi_scale = function() return ui_renderer:dpi_scale() end,
    edge_seek_top_inset = edge_seek_top_inset,
    alpha = ass_alpha_for_opacity, draw_rect = draw_rect, draw_box = draw_box,
    draw_round_box = draw_round_box,
    draw_icon = draw_icon, draw_text = draw_text, draw_seekbar = draw_seekbar,
    draw_shadowed_text = draw_shadowed_text,
    push_clip = function(bounds) ui_renderer:push_clip(bounds) end,
    pop_clip = function() ui_renderer:pop_clip() end,
    draw_loading = draw_loading_shape_morph, mouse_in = mouse_in,
    truncate_utf8 = truncate_utf8,
    truncate_to_width = truncate_utf8_to_width, format_time = format_time,
    text_width = text_intrinsic_width,
    default_text_font = default_text_font, Modifier = Modifier, Rect = Rect,
    apply_modifier_size = apply_modifier_size, measure_node = measure_node,
    content_bounds = content_bounds,
    draw_node = draw_node, IconButton = IconButton, TextItem = TextItem,
    Visibility = Visibility, Row = Row, Column = Column, Pill = Pill,
    request_tooltip = request_tooltip,
    set_render_pass = set_render_pass,
    is_render_pass = is_render_pass
  },
  player = {
    snapshot = function() return runtime.snapshot end,
    preview_seek_to_mouse = preview_seek_to_mouse,
    seek_pos_from_mouse = seek_pos_from_mouse, seek_to_pos = seek_to_pos,
    select_stream_quality = select_stream_quality,
    open_subtitle_file_picker = open_subtitle_file_picker,
    open_subtitle_link_picker = open_subtitle_link_picker,
    open_secondary_subtitle_file_picker = open_secondary_subtitle_file_picker,
    open_secondary_subtitle_link_picker = open_secondary_subtitle_link_picker,
    open_shader_file_picker = shader_loader.open_file_picker,
    open_shader_link_picker = shader_loader.open_link_picker,
    remove_shader = shader_loader.remove,
    clear_shaders = shader_loader.clear,
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

local snapshot_reader = snapshot_module.cached_reader({
  runtime = runtime, format_time = format_time,
  friendly_quality_label = stream_quality_module.quality_label,
  max_volume_percentage = max_volume_percentage, is_buffering = is_buffering,
  properties = runtime.properties
})
local function read_player_snapshot() return snapshot_reader:read() end
local runtime_host
local animation_coordinator = animation_coordinator_module.new({
  runtime = runtime, mouse_in = mouse_in, tooltip = tooltip_service,
  single_click_actions_enabled = function()
    return opts.single_click_actions_enabled
  end,
  seeking_zone_fraction = function()
    return opts.seeking_zone_percentage / 100
  end,
  edge_seek_top_inset = edge_seek_top_inset,
  hide_cursor = function() runtime_host:set_cursor_autohide("always") end
})
local function update_animation_targets(now)
  animation_coordinator:update(now)
end

runtime_host = mpv_runtime_module.new({
  state = runtime, mp = mp, navigation = navigation,
  playback_indicator = playback_indicator,
  stream_quality = stream_quality,
  directory_playlist = directory_playlist,
  bookmarks = bookmark_service,
  close_context_menu = close_context_menu,
  controller = function() return controller end,
  render = function() render() end,
  render_cached = function() render(false) end,
  render_dynamic = function() render(false, "dynamic") end,
  render_continuous = function()
    render(false, animation_coordinator:render_mode())
  end,
  animation_interval = function(base)
    return animation_coordinator:recommended_interval(base)
  end,
  update_cached_property = function(name, value)
    snapshot_reader:update(name, value)
  end,
  property_changed = performance and function(name)
    local key = "property_" .. name
    performance[key] = (performance[key] or 0) + 1
  end or nil,
  needs_continuous_render = function()
    local animation_running = animation_coordinator:is_running()
    local tooltip_running = tooltip_service:needs_frames(mp.get_time())
    local app_running = app:needs_continuous_render()
    local buffering = runtime.snapshot.buffering
    local captions = runtime.ytdl.caption_loading_id ~= nil
    if performance then
      local reason = animation_running and "animation" or
        (tooltip_running and "tooltip") or (app_running and "app") or
        (buffering and "buffering") or (captions and "captions")
      if reason then
        local key = "continuous_" .. reason
        performance[key] = (performance[key] or 0) + 1
      end
    end
    return animation_running or tooltip_running or app_running or buffering or captions
  end,
  hidden_playback_progress_visible = function()
    return opts.show_mini_seekbar
  end
})
local function handle_snapshot(snapshot, now, full)
  if not full then return end
  playback_indicator:observe(snapshot, now)
  if #snapshot.chapters == 0 then runtime.chapter.open = false end
  if #snapshot.audio_items < 2 then runtime.audio.open = false end
  if snapshot.playlist_count == 0 then runtime.playlist.open = false end
end

local function present_layer(name, ass)
  local state = overlay_layers[name]
  local overlay = state.overlay
  if ass.text ~= "" then
    if not state.active or overlay.data ~= ass.text or
      state.presented_res_x ~= overlay.res_x or
      state.presented_res_y ~= overlay.res_y then
      overlay.data = ass.text
      overlay:update()
      if performance then
        performance.overlay_updates = performance.overlay_updates + 1
        performance.bytes = performance.bytes + #ass.text
      end
      state.presented_res_x, state.presented_res_y =
        overlay.res_x, overlay.res_y
    end
    state.active = true
  elseif state.active then
    overlay:remove()
    state.active = false
    state.presented_res_x, state.presented_res_y = nil, nil
  end
end

local function draw_overlay_layer(name, default_pass, register_interactions)
  local layer = overlay_layers[name]
  local overlay = layer.overlay
  overlay.res_x, overlay.res_y = runtime.viewport.w, runtime.viewport.h
  set_render_pass(name, default_pass, register_interactions)
  local ass = assdraw.ass_new()
  app:draw_layer(name, ass,
    Rect({x = 0, y = 0, w = runtime.viewport.w, h = runtime.viewport.h}))
  present_layer(name, ass)
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
  app = function() return app end,
  draw_layers = function(mode)
    ui_renderer:begin_frame()
    local full = mode == "full"
    if full or mode == "visual" then
      draw_overlay_layer("base", "base", full)
    end
    draw_overlay_layer("dynamic", "base", true)
    if mode ~= "dynamic" then
      draw_overlay_layer("interaction", "base", false)
      draw_overlay_layer("modal", "modal", true)
    end
  end,
  on_frame = performance and function(mode)
    if mode == "full" then
      performance.full_frames = performance.full_frames + 1
    elseif mode == "visual" then
      performance.visual_frames = performance.visual_frames + 1
    elseif mode == "interaction" then
      performance.interaction_frames = performance.interaction_frames + 1
    else
      performance.dynamic_frames = performance.dynamic_frames + 1
    end
  end or nil,
  on_profile_phase = performance and function(name, elapsed)
    performance[name] = (performance[name] or 0) + elapsed
  end or nil,
  disable_dialog = function(binding) mp.disable_key_bindings(binding) end,
  update_mouse_area = function() runtime_host:update_mouse_area() end,
  schedule = function(delay, callback) return mp.add_timeout(delay, callback) end,
  on_rendered = function() runtime_host:update_frame_timer() end
})
render = function(refresh_snapshot, layer)
  if refresh_snapshot ~= false then snapshot_reader:invalidate() end
  renderer:request_render(layer)
  runtime_host:update_frame_timer()
end

local function recreate_app() app = create_app(services) end
controller = controller_module.new({
  runtime = runtime, mp = mp, opts = opts, navigation = navigation,
  thumbnail = thumbnail_service, mouse_in = mouse_in,
  edge_seek_top_inset = edge_seek_top_inset,
  hitbox_at_cursor = hitbox_at_cursor,
  open_context_menu = open_context_menu,
  set_cursor_autohide = function(value)
    runtime_host:set_cursor_autohide(value)
  end,
  pointer_feedback_changed = function()
    return animation_coordinator:pointer_feedback_changed()
  end,
  -- At 240 Hz, redrawing a pixel-sensitive seek preview on every hardware
  -- mouse sample costs more than the rest of the visible OSC. A 120 Hz cap
  -- still gives an 8.3 ms response while popup springs remain display-paced.
  pointer_interval = function()
    return math.max(runtime.timers.frame_interval, 1 / 120)
  end,
  render = function() render(false, "interaction") end,
  render_dynamic = function() render(false, "dynamic") end,
  render_visibility = function() render(false) end,
  recreate_app = recreate_app
})

options_update_handler = function(changed)
  if changed.max_volume_percentage then
    max_volume_percentage = opts.max_volume_percentage
    services.config.max_volume_percentage = max_volume_percentage
    mp.set_property_number("volume-max", max_volume_percentage)
  end
  if changed.context_menu and not opts.context_menu then
    close_context_menu()
  end
  if changed.force_hwdec then apply_force_hwdec() end
  if changed.dpi_scale or changed.single_click_actions_enabled or
    changed.seeking_zone_percentage or changed.seek_step_seconds or
    changed.max_volume_percentage then
    recreate_app()
  end
  if changed.show_on_mouse_move then
    if opts.show_on_mouse_move then controller:show()
    else controller:sync_visibility_with_pointer() end
  elseif changed.mouse_timeout and runtime.controller.visible then
    controller:show()
  end
  render()
end

local config_path = mp.find_config_file("script-opts/material-osc.conf") or
  mp.command_native({"expand-path", "~~/script-opts/material-osc.conf"})
config_watcher = config_watcher_module.new({
  mp = mp,
  utils = utils,
  path = config_path,
  directory = select(1, utils.split_path(config_path)),
  options = opts,
  defaults = option_defaults,
  normalize = normalize_option_values,
  on_update = function(changed)
    normalize_option_values(opts)
    options_update_handler(changed)
  end,
  on_error = function(error)
    msg.warn("live material-osc configuration reload is unavailable: " ..
      tostring(error or ""))
  end
})
mp.register_event("shutdown", function() config_watcher:stop() end)
if performance then
  mp.register_event("shutdown", function()
    msg.warn(string.format(
      "profile full=%d visual=%d interaction=%d dynamic=%d " ..
        "overlay_updates=%d bytes=%d " ..
        "full(state=%.4f update=%.4f draw=%.4f) " ..
        "visual(state=%.4f update=%.4f draw=%.4f) " ..
        "interaction(state=%.4f update=%.4f draw=%.4f) " ..
        "dynamic(state=%.4f update=%.4f draw=%.4f)",
      performance.full_frames, performance.visual_frames,
      performance.interaction_frames,
      performance.dynamic_frames,
      performance.overlay_updates, performance.bytes,
      performance.full_state or 0, performance.full_update or 0,
      performance.full_draw or 0,
      performance.visual_state or 0, performance.visual_update or 0,
      performance.visual_draw or 0,
      performance.interaction_state or 0, performance.interaction_update or 0,
      performance.interaction_draw or 0,
      performance.dynamic_state or 0,
      performance.dynamic_update or 0, performance.dynamic_draw or 0))
    local property_counts = {}
    for name, count in pairs(performance) do
      local property_name = name:match("^property_(.+)$")
      if property_name then
        property_counts[#property_counts + 1] =
          property_name .. "=" .. tostring(count)
      end
    end
    table.sort(property_counts)
    msg.warn("profile properties " .. table.concat(property_counts, " "))
    local continuous_counts = {}
    for name, count in pairs(performance) do
      local reason = name:match("^continuous_(.+)$")
      if reason then
        continuous_counts[#continuous_counts + 1] =
          reason .. "=" .. tostring(count)
      end
    end
    table.sort(continuous_counts)
    msg.warn("profile continuous " .. table.concat(continuous_counts, " "))
  end)
end

runtime_host:start()
if opts.show_on_mouse_move then controller:show() end
config_watcher:start()
updater:start()
