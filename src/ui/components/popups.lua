local popups = {}
local popup_factories = require "src.ui.components.popup_factories"

local function normalize_aspect_override(value)
  value = tostring(value or "no"):lower():match("^%s*(.-)%s*$")
  if value == "" or value == "no" then return "no" end
  local numeric = tonumber(value)
  return numeric and numeric <= 0 and "no" or value
end

popups.normalize_aspect_override = normalize_aspect_override

function popups.new(services)
  local state, ui = services.state, services.ui
  local player, navigation = services.player, services.navigation
  local temporary_speed = services.temporary_speed
  local pointer, input, viewport = state.pointer, state.input, state.viewport
  local chapter_state, subtitle_state = state.chapter, state.subtitle
  local audio_state, settings_state, ytdl_state = state.audio, state.settings, state.ytdl
  local opts, msg = services.config.opts, services.platform.msg
  local filesystem = services.platform.filesystem
  local process = services.platform.process
  local timers = services.timers
  local dp, clamp, smooth_step = ui.dp, ui.clamp, ui.smooth_step
  local ass_alpha_for_opacity = ui.alpha
  local format_time = ui.format_time
  local truncate_to_width, text_width = ui.truncate_to_width, ui.text_width
  local draw_box, draw_rect, draw_icon = ui.draw_box, ui.draw_rect, ui.draw_icon
  local draw_text, draw_loading_shape_morph = ui.draw_text, ui.draw_loading
  local default_text_font, render = ui.default_text_font, services.effects.render
  local Modifier, Rect = ui.Modifier, ui.Rect
  local apply_modifier_size, measure_node = ui.apply_modifier_size, ui.measure_node
  local draw_node, mouse_in = ui.draw_node, ui.mouse_in
  local push_clip, pop_clip = ui.push_clip, ui.pop_clip
  local request_tooltip = ui.request_tooltip
  local set_settings_page = navigation.set_settings_page
  local select_stream_quality = player.select_stream_quality
  local open_subtitle_file_picker = player.open_subtitle_file_picker
  local open_subtitle_link_picker = player.open_subtitle_link_picker
  local open_secondary_subtitle_file_picker = player.open_secondary_subtitle_file_picker
  local open_secondary_subtitle_link_picker = player.open_secondary_subtitle_link_picker
  local open_shader_file_picker = player.open_shader_file_picker
  local open_shader_link_picker = player.open_shader_link_picker
  local remove_shader, clear_shaders = player.remove_shader, player.clear_shaders
  local attach_ytdl_caption = player.attach_ytdl_caption
  local set_chapter_dialog_open = navigation.set_chapter_open
  local set_subtitle_dialog_open = navigation.set_subtitle_open
  local set_audio_dialog_open = navigation.set_audio_open
  local set_settings_dialog_open = navigation.set_settings_open

  local function update_fields(target, props)
    for key, value in pairs(props) do target[key] = value end
  end

  local function PointerLayer(args)
    local node = {modifier = Modifier():fillMaxWidth():fillMaxHeight()}
    node.modifier:clickable({
      name = args.name, enabled = args.enabled, on_click = args.on_click
    })
    function node:set_enabled(enabled) self.modifier.pointer_enabled = enabled end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end
    function node:draw() end
    return node
  end

  local function PopupHost(args)
    local node = {modifier = Modifier():fillMaxWidth():fillMaxHeight()}
    node.backdrop = PointerLayer({
      name = args.name .. "-backdrop", enabled = false, on_click = args.on_close
    })
    node.popup = args.popup
    local function popup_opacity()
      local source = args.opacity_animation or args.state.animation
      local value = clamp(source.value, 0, 1)
      return args.opacity_animation and value or smooth_step(value)
    end
    local function morph_progress()
      if not args.morph then return 1 end
      local source = args.morph_animation or args.state.animation
      return clamp(source.value, 0, 1.05)
    end
    function node:update(snapshot)
      local opacity = popup_opacity()
      if not args.state.open and opacity <= 0 then
        self.backdrop:set_enabled(false)
        return
      end
      local progress = morph_progress()
      local interactive = args.state.open and
        (not args.morph or progress >= 0.9)
      self.backdrop:set_enabled(args.state.open or opacity > 0)
      args.update_popup(self.popup, snapshot, opacity, interactive,
        progress, input.hitboxes[args.anchor_name])
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end
    function node:draw(ass, bounds)
      local opacity = popup_opacity()
      if opacity <= 0 and not args.state.open then return end
      draw_node(self.backdrop, ass, bounds)
      local anchor = input.hitboxes[args.anchor_name]
      local popup_size = measure_node(self.popup, bounds)
      local margin = dp(12)
      local desired_x = bounds.x + (bounds.w - popup_size.w) / 2
      if anchor then
        if args.anchor_start then
          desired_x = anchor.x1 + (args.anchor_offset_x or 0)
        else
          desired_x = anchor.x2 - popup_size.w + (args.anchor_offset_x or 0)
        end
      end
      -- Keep the final bottom edge fixed while the dimensions spring. With
      -- start alignment Chapter pivots around its bottom-left corner; with
      -- end alignment Settings pivots around its bottom-right corner.
      local desired_y = anchor and
        (anchor.y1 - popup_size.h - dp(8)) or
        (bounds.y + (bounds.h - popup_size.h) / 2)
      local x = clamp(desired_x, bounds.x + margin,
        bounds.x2 - margin - popup_size.w)
      local y = clamp(desired_y, bounds.y + margin,
        bounds.y2 - margin - popup_size.h)
      local popup_bounds = Rect({x = x, y = y, w = popup_size.w, h = popup_size.h})
      args.state.bounds = popup_bounds
      draw_node(self.popup, ass, popup_bounds)
    end
    return node
  end

  local function popup_visual_props(opacity, interactive)
    return {
      opacity = opacity, interactive = interactive,
      alpha = ass_alpha_for_opacity(opacity),
      text_alpha = ass_alpha_for_opacity(opacity),
      secondary_alpha = ass_alpha_for_opacity(opacity * 0.72),
      hover_alpha = ass_alpha_for_opacity(opacity * 0.18),
      selected_alpha = ass_alpha_for_opacity(opacity * 0.33)
    }
  end

  local function morph_size(anchor_size, target_size, progress, fallback)
    local origin = anchor_size or fallback
    return origin + (target_size - origin) * progress
  end

  local function morph_content_opacity(progress)
    -- Match the context menu: the shell establishes itself first, then its
    -- contents resolve during the final 38% of the fade.
    return smooth_step(clamp((progress - 0.62) / 0.38, 0, 1))
  end

  local function morph_shell_opacity(open, fade)
    return open and (0.53 + clamp(fade, 0, 1) * 0.43) or
      clamp(fade, 0, 1) * 0.96
  end

  local function ChapterCloseButton(args)
    local node = {
      alpha = "00",
      hover_alpha = "E6",
      enabled = false,
      on_click = args.on_click,
      icon = args.icon or "close",
      tooltip = args.tooltip or (args.icon == "arrow_back" and "Back" or "Close"),
      shortcut = args.shortcut,
      modifier = Modifier():width(dp(36)):height(dp(36))
    }
    if args.on_press or args.on_release then
      node.modifier:pointerArea({
        name = args.name or "chapter-dialog-close",
        enabled = false,
        on_press = function()
          if node.enabled and args.on_press then args.on_press() end
        end,
        on_release = function()
          if args.on_release then args.on_release() end
        end
      })
    else
      node.modifier:clickable({
        name = args.name or "chapter-dialog-close",
        enabled = false,
        on_click = function()
          if node.enabled and node.on_click then node.on_click() end
        end
      })
    end
    function node:update(props)
      self.alpha = props.alpha
      self.hover_alpha = props.hover_alpha
      self.enabled = props.enabled
      self.modifier.pointer_enabled = props.enabled
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end
    function node:draw(ass, bounds)
      if self.enabled and mouse_in(bounds) then
        draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
             bounds.h / 2, "#FFFFFF", self.hover_alpha)
      end
      draw_icon(ass, bounds.x + bounds.w / 2, bounds.y + bounds.h / 2,
           self.icon, "#FFFFFF", 24, self.alpha)
      local tooltip = type(self.tooltip) == "function" and
        self.tooltip() or self.tooltip
      local visible = (tonumber(self.alpha or "FF", 16) or 255) < 250
      if visible and tooltip and mouse_in(bounds) then
        request_tooltip(tooltip, bounds, true, self.shortcut)
      end
    end
    return node
  end

  local function ChapterHeader(on_close, title, action_icon, right_action,
      close_name)
    local title_key = tostring(title or "chapters"):lower()
      :gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    local node = {
      alpha = "00", title_alpha = "00", hover_alpha = "E6", interactive = false,
      title = title or "Chapters",
      action_on_left = action_icon == "arrow_back",
      actions = {},
      modifier = Modifier():fillMaxWidth():height(dp(56))
    }
    node.close = ChapterCloseButton({
      name = close_name or (title_key .. "-header-close"),
      on_click = on_close,
      icon = action_icon
    })
    if right_action then
      local actions = right_action[1] and right_action or {right_action}
      for _, action in ipairs(actions) do
        node.actions[#node.actions + 1] = ChapterCloseButton({
          name = action.name,
          on_click = action.on_click,
          icon = action.icon,
          tooltip = action.tooltip,
          shortcut = action.shortcut,
          on_press = action.on_press,
          on_release = action.on_release
        })
      end
    end
    function node:update(props)
      self.alpha = props.alpha
      self.title_alpha = props.title_alpha or props.alpha
      self.hover_alpha = props.hover_alpha
      self.interactive = props.interactive
      self.close:update({alpha = props.alpha, hover_alpha = props.hover_alpha,
        enabled = props.interactive})
      for _, action in ipairs(self.actions) do
        action:update({alpha = props.alpha, hover_alpha = props.hover_alpha,
          enabled = props.interactive})
      end
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = dp(56)}, parent)
    end
    function node:draw(ass, bounds)
      local title_x = bounds.x + dp(self.action_on_left and 50 or 22)
      draw_text(ass, title_x, bounds.y + bounds.h / 2,
            self.title, 24, "#FFFFFF", self.title_alpha, default_text_font, 4)
      local close_size = dp(36)
      draw_node(self.close, ass, Rect({
        x = self.action_on_left and (bounds.x + dp(6)) or
          (bounds.x2 - dp(12) - close_size),
        y = bounds.y + (bounds.h - close_size) / 2,
        w = close_size,
        h = close_size
      }))
      for index, action in ipairs(self.actions) do
        local slots_from_right = #self.actions - index
        if not self.action_on_left then slots_from_right = slots_from_right + 1 end
        draw_node(action, ass, Rect({
          x = bounds.x2 - dp(12) - close_size -
            slots_from_right * (close_size + dp(4)),
          y = bounds.y + (bounds.h - close_size) / 2,
          w = close_size,
          h = close_size
        }))
      end
      if self.action_on_left then
        local header_opacity = 1 - (tonumber(self.alpha, 16) or 255) / 255
        draw_rect(ass, bounds.x, bounds.y2 - dp(1), bounds.x2, bounds.y2,
          "#FFFFFF", ass_alpha_for_opacity(header_opacity * 0.18))
      end
    end
    return node
  end

  local chapter_widgets = popup_factories.new_chapter_popup({
    pointer = pointer, state = chapter_state, opts = opts, dp = dp, clamp = clamp,
    ass_alpha_for_opacity = ass_alpha_for_opacity,
    truncate_to_width = truncate_to_width, text_width = text_width,
    format_time = format_time,
    draw_box = draw_box, draw_icon = draw_icon, draw_text = draw_text,
    default_text_font = default_text_font,
    render = render, Modifier = Modifier, Rect = Rect,
    apply_modifier_size = apply_modifier_size, draw_node = draw_node,
    mouse_in = mouse_in, ChapterHeader = ChapterHeader,
    bookmarks = services.bookmarks,
    update_fields = update_fields
  })
  local ChapterPopup = chapter_widgets.ChapterPopup
  local VerticalScrollbar = chapter_widgets.VerticalScrollbar

  local track_popups = popup_factories.new_track_popup({
    opts = opts, dp = dp, clamp = clamp,
    truncate_to_width = truncate_to_width, text_width = text_width,
    draw_box = draw_box, draw_rect = draw_rect, draw_icon = draw_icon,
    draw_text = draw_text,
    draw_loading_shape_morph = draw_loading_shape_morph,
    default_text_font = default_text_font, render = render,
    Modifier = Modifier, Rect = Rect, apply_modifier_size = apply_modifier_size,
    draw_node = draw_node, mouse_in = mouse_in, ChapterHeader = ChapterHeader,
    VerticalScrollbar = VerticalScrollbar, update_fields = update_fields,
    subtitle_state = subtitle_state, audio_state = audio_state
  })
  local TrackPopup = track_popups.TrackPopup
  local SubtitlePopup, AudioPopup = track_popups.SubtitlePopup, track_popups.AudioPopup

  local function SettingsActionRow(name, icon, on_click)
    local node = {
      icon = icon, label = "", value = "", loading = false,
      interactive = false, text_alpha = "00",
      secondary_alpha = "00", hover_alpha = "00",
      modifier = Modifier():fillMaxWidth():height(dp(44)):clickable({
        name = name, enabled = false, on_click = on_click
      })
    }
    function node:update(props)
      update_fields(self, props)
      self.modifier.pointer_enabled = self.interactive
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = dp(44)}, parent)
    end
    function node:draw(ass, bounds)
      if self.interactive and mouse_in(bounds) then
        draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
          bounds.h / 2, "#FFFFFF", self.hover_alpha)
      end
      draw_icon(ass, bounds.x + dp(28), bounds.y + bounds.h / 2,
        self.icon, "#FFFFFF", 24, self.text_alpha)
      local label_x = bounds.x + dp(52)
      draw_text(ass, label_x, bounds.y + bounds.h / 2,
        self.label, 22, "#FFFFFF", self.text_alpha, default_text_font, 4)
      if self.loading then
        draw_loading_shape_morph(ass, bounds.x2 - dp(24),
          bounds.y + bounds.h / 2, dp(22))
      else
        local value_right = bounds.x2 - dp(16)
        local value_left = label_x + text_width(self.label, 22) + dp(16)
        local value = truncate_to_width(self.value,
          math.max(0, value_right - value_left), 20)
        draw_text(ass, value_right, bounds.y + bounds.h / 2,
          value,
          20, "#CAC4D0", self.secondary_alpha, default_text_font, 6)
      end
    end
    return node
  end

  local function SpeedPreset(value)
    local node = {
      value = value, speed = 1, interactive = false, text_alpha = "00",
      hover_alpha = "00", selected_alpha = "00",
      modifier = Modifier():width(dp(62)):height(dp(38)):clickable({
        name = "speed-preset-" .. tostring(value), enabled = false,
        on_click = function() mp.set_property_number("speed", value) end
      })
    }
    function node:update(props)
      update_fields(self, props)
      self.modifier.pointer_enabled = self.interactive
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = dp(62), h = dp(38)}, parent)
    end
    function node:draw(ass, bounds)
      local selected = math.abs(self.speed - self.value) < 0.01
      local alpha = selected and self.selected_alpha or
        (self.interactive and mouse_in(bounds) and self.hover_alpha or "D8")
      draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
        bounds.h / 2, selected and opts.accent_color or "#FFFFFF", alpha)
      draw_text(ass, bounds.x + bounds.w / 2, bounds.y + bounds.h / 2,
        string.format("%gx", self.value), 22, "#FFFFFF", self.text_alpha,
        default_text_font)
    end
    return node
  end

  local function SpeedPopup(on_back)
    local speed_min, speed_max, speed_step = 0.25, 3, 0.05
    local node = {
      width = dp(420), height = dp(190), speed = 1, interactive = false,
      panel_alpha = "00", text_alpha = "00", hover_alpha = "00",
      selected_alpha = "00", modifier = Modifier():clickable({
        name = "speed-dialog-panel", enabled = false, on_click = function() end
      })
    }
    local function stepped_speed(value)
      local steps = math.floor(
        (clamp(value, speed_min, speed_max) - speed_min) / speed_step + 0.5)
      return clamp(speed_min + steps * speed_step, speed_min, speed_max)
    end
    local function adjust_speed(amount)
      mp.set_property_number("speed", stepped_speed(node.speed + amount))
    end
    local function speed_at_pointer(box)
  local raw_speed = speed_min + clamp((pointer.x - box.x1) / box.w, 0, 1) * (speed_max - speed_min)
  return clamp(math.floor(raw_speed * 100 + 0.5) / 100, speed_min, speed_max)
end
    node.header = ChapterHeader(on_back, "Playback Speed", "arrow_back", {
      name = "playback-speed-temporary",
      icon = "bolt_boost",
      tooltip = function()
        return string.format(
          "Temporary %gx", tonumber(services.config.temporary_speed()) or 2)
      end,
      shortcut = "temporary-speed",
      on_press = function() temporary_speed:activate() end,
      on_release = function() temporary_speed:deactivate() end
    }, "playback-speed-back")
    node.decrease = ChapterCloseButton({
      name = "playback-speed-decrease",
      icon = "remove",
      tooltip = "Decrease Speed",
      shortcut = "speed-down",
      on_click = function() adjust_speed(-speed_step) end
    })
    node.increase = ChapterCloseButton({
      name = "playback-speed-increase",
      icon = "add",
      tooltip = "Increase Speed",
      shortcut = "speed-up",
      on_click = function() adjust_speed(speed_step) end
    })
    node.slider = {dragging = false, modifier = Modifier():pointerArea({
      name = "playback-speed-slider", enabled = false,
      on_keyboard_left = function()
        adjust_speed(-speed_step)
      end,
      on_keyboard_right = function()
        adjust_speed(speed_step)
      end,
      on_press = function(box)
        node.slider.dragging = true
        mp.set_property_number("speed", speed_at_pointer(box))
      end,
      on_move = function(box)
        mp.set_property_number("speed", speed_at_pointer(box))
      end,
      on_release = function()
        node.slider.dragging = false
      end
    })}
    function node.slider:measure(parent)
      return apply_modifier_size(self.modifier, {w = parent.w, h = dp(36)}, parent)
    end
    function node.slider:draw(ass, bounds)
      local track_y, track_h = bounds.y + bounds.h / 2, dp(4)
      local ratio = clamp(
        (node.speed - speed_min) / (speed_max - speed_min), 0, 1)
      local cx = bounds.x + bounds.w * ratio
      local handle_w = node.slider.dragging and dp(2) or track_h
      local gap = dp(4)
      local gap_left, gap_right = cx - handle_w / 2 - gap,
        cx + handle_w / 2 + gap
      if gap_left > bounds.x then
        draw_rect(ass, bounds.x, track_y - track_h / 2, gap_left,
          track_y + track_h / 2, opts.accent_color, node.text_alpha)
      end
      if gap_right < bounds.x2 then
        draw_rect(ass, gap_right, track_y - track_h / 2, bounds.x2,
          track_y + track_h / 2, "#282828", "99")
      end
      local hovering = mouse_in(bounds)
      local handle_h = dp(hovering and 24 or 22)
      draw_box(ass, cx - handle_w / 2, track_y - handle_h / 2,
        cx + handle_w / 2, track_y + handle_h / 2, handle_w / 2,
        opts.accent_color, node.text_alpha)
    end
    node.presets = {}
    for _, value in ipairs({0.5, 1, 1.5, 2}) do
      node.presets[#node.presets + 1] = SpeedPreset(value)
    end
    function node:update(props)
      update_fields(self, props)
      self.modifier.fixed_width, self.modifier.fixed_height = self.width, self.height
      self.modifier.pointer_enabled = self.interactive
      self.slider.modifier.pointer_enabled = self.interactive
      self.header:update({alpha = self.text_alpha, hover_alpha = self.hover_alpha,
        interactive = self.interactive})
      local button_props = {
        alpha = self.text_alpha,
        hover_alpha = self.hover_alpha,
        enabled = self.interactive
      }
      self.decrease:update(button_props)
      self.increase:update(button_props)
      for _, preset in ipairs(self.presets) do
        preset:update({speed = self.speed, interactive = self.interactive,
          text_alpha = self.text_alpha, hover_alpha = self.hover_alpha,
          selected_alpha = self.selected_alpha})
      end
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = self.width, h = self.height}, parent)
    end
    function node:draw(ass, bounds)
      draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
        dp(30), "#050708", self.panel_alpha)
      draw_node(self.header, ass, Rect({x = bounds.x, y = bounds.y, w = bounds.w, h = dp(56)}))
      draw_text(ass, bounds.x + bounds.w / 2, bounds.y + dp(82),
        string.format("%.2fx", self.speed), 24, "#FFFFFF", self.text_alpha,
        default_text_font)
      local slider_y, button_size = bounds.y + dp(98), dp(36)
      draw_node(self.decrease, ass, Rect({
        x = bounds.x + dp(16), y = slider_y,
        w = button_size, h = button_size
      }))
      draw_node(self.slider, ass, Rect({
        x = bounds.x + dp(60), y = slider_y,
        w = bounds.w - dp(120), h = dp(36)
      }))
      draw_node(self.increase, ass, Rect({
        x = bounds.x2 - dp(52), y = slider_y,
        w = button_size, h = button_size
      }))
      local gap, pill_w = dp(8), dp(62)
      local total_w = #self.presets * pill_w + (#self.presets - 1) * gap
      local x = bounds.x + (bounds.w - total_w) / 2
      for _, preset in ipairs(self.presets) do
        draw_node(preset, ass, Rect({x = x, y = bounds.y + dp(138),
          w = pill_w, h = dp(38)}))
        x = x + pill_w + gap
      end
    end
    return node
  end

  local function selected_track_label(items, active_id, fallback)
    for _, item in ipairs(items or {}) do
      if item.id == active_id then return item.label end
    end
    return fallback
  end

  local function open_image_track(item)
    local source = mp.get_property("path")
    if not source or source == "" then return end
    if not source:match("^%a[%w+.-]*://") and
      not source:match("^[/\\]") and not source:match("^%a:[/\\]") then
      source = filesystem:join(
        mp.get_property("working-directory") or ".", source)
    end

    -- Sandboxed image viewers (Flatpak/Snap in particular) have a private /tmp,
    -- so a host-side /tmp path can disappear from the viewer's point of view.
    -- The user's cache directory is visible through the desktop file portal.
    local temp_dir = os.getenv("XDG_CACHE_HOME")
    if not temp_dir or temp_dir == "" then
      local home = os.getenv("HOME") or mp.get_property("working-directory") or "."
      temp_dir = filesystem:join(home, ".cache")
    end
    temp_dir = filesystem:join(temp_dir, "mpv")
    temp_dir = filesystem:join(temp_dir, "material-osc")
    temp_dir = filesystem:join(temp_dir, "thumbnails")
    if not filesystem:ensure_directory(temp_dir) then
      msg.error("Could not create image thumbnail directory: " .. temp_dir)
      return
    end
    local video_title = mp.get_property("media-title") or "video"
    video_title = video_title:gsub("[/\\:*?\"<>|%c]", "_")
      :gsub("^%s+", ""):gsub("%s+$", "")
    if video_title == "" then video_title = "video" end
    local output = filesystem:join(temp_dir, string.format(
      "%s-%s.png", video_title, tostring(item.id)))
    local video_index = tonumber(item.video_index)
    if video_index == nil then
      msg.error("Cannot open image track: video stream index is unavailable")
      return
    end

    process:run_async(
      {"ffmpeg", "-v", "error", "-y", "-i", source,
        "-map", "0:v:" .. tostring(video_index), "-frames:v", "1",
        "-f", "image2", output}, nil, function(success, result)
      if not success then
        msg.error("Could not extract image track: " ..
          tostring(result and result.stderr or "unknown subprocess error"))
        return
      end
      local info = filesystem:info(output)
      if not info or not info.is_file or (tonumber(info.size) or 0) <= 0 then
        msg.error("FFmpeg finished without creating the image: " .. output)
        return
      end
      filesystem:open(output, nil, function(open_success)
        if not open_success then
          msg.error("Could not launch the system image viewer")
        end
      end)
    end)
  end

  local function SubtitleAdjustRow(name, label, on_decrease, on_increase)
    local node = {
      label = label, value = "", interactive = false,
      text_alpha = "00", secondary_alpha = "00", hover_alpha = "00",
      modifier = Modifier():fillMaxWidth():height(dp(44))
    }
    local function button(suffix, text, on_click)
      local item = {text = text, repeat_delay = nil, repeat_timer = nil}
      local function stop_repeat()
        timers:cancel_all(item, {"repeat_delay", "repeat_timer"})
      end
      local function start_repeat()
        stop_repeat()
        on_click()
        timers:after(item, "repeat_delay", 0.38, function()
          timers:every(item, "repeat_timer", 0.08, on_click)
        end)
      end
      item.stop_repeat = stop_repeat
      item.modifier = Modifier():width(dp(34)):height(dp(34)):clickable({
        name = name .. "-" .. suffix, enabled = false,
        on_press = start_repeat, on_release = stop_repeat,
        on_keyboard = on_click
      })
      function item:measure(parent)
        return apply_modifier_size(self.modifier, {w = dp(34), h = dp(34)}, parent)
      end
      function item:draw(ass, bounds)
        if node.interactive and mouse_in(bounds) then
          draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
            bounds.h / 2, "#FFFFFF", node.hover_alpha)
        end
        draw_text(ass, bounds.x + bounds.w / 2, bounds.y + bounds.h / 2,
          self.text, 26, "#FFFFFF", node.text_alpha, default_text_font)
      end
      return item
    end
    node.decrease = button("decrease", "−", on_decrease)
    node.increase = button("increase", "+", on_increase)
    function node:update(props)
      update_fields(self, props)
      self.decrease.modifier.pointer_enabled = self.interactive
      self.increase.modifier.pointer_enabled = self.interactive
      if not self.interactive then
        self.decrease.stop_repeat()
        self.increase.stop_repeat()
      end
    end
    function node:measure(parent) return {w = parent.w, h = dp(44)} end
    function node:draw(ass, bounds)
      draw_text(ass, bounds.x + dp(16), bounds.y + bounds.h / 2,
        self.label, 21, "#FFFFFF", self.text_alpha, default_text_font, 4)
      local plus = Rect({x = bounds.x2 - dp(42), y = bounds.y + dp(5), w = dp(34), h = dp(34)})
      local minus = Rect({x = plus.x - dp(42), y = plus.y, w = dp(34), h = dp(34)})
      draw_text(ass, minus.x - dp(8), bounds.y + bounds.h / 2,
        self.value, 19, "#CAC4D0", self.secondary_alpha, default_text_font, 6)
      draw_node(self.decrease, ass, minus)
      draw_node(self.increase, ass, plus)
    end
    return node
  end

  local subtitle_colors = {
    {name = "White", value = "#FFFFFFFF"},
    {name = "Yellow", value = "#FFFFFF00"},
    {name = "Cyan", value = "#FF00FFFF"},
    {name = "Green", value = "#FF80FF80"},
    {name = "Pink", value = "#FFFFB0D8"}
  }
  local subtitle_fonts = {"sans-serif", "Google Sans Flex", "serif", "monospace"}

  local function normalize_subtitle_color(color)
    color = tostring(color or "#FFFFFFFF"):upper()
    if color:match("^#%x%x%x%x%x%x%x%x") then return color:sub(1, 9) end
    return color
  end

  local function cycle_option(items, current, direction, value_of)
    local index = 1
    for i, item in ipairs(items) do
      if value_of(item) == current then index = i break end
    end
    return items[((index - 1 + direction) % #items) + 1]
  end

  local function SubtitleStylePopup(on_back)
    local node = {
      width = dp(360), height = dp(332), interactive = false,
      panel_alpha = "00", text_alpha = "00", secondary_alpha = "00",
      hover_alpha = "00", delay_value = 0, font_size = 38, border_size = 1.65,
      position = 100,
      color = "#FFFFFFFF", font = "sans-serif",
      modifier = Modifier():clickable({
        name = "subtitle-style-panel", enabled = false, on_click = function() end
      })
    }
    local function reset_subtitle_style()
      mp.set_property_number("sub-delay", 0)
      mp.set_property_number("sub-font-size", 38)
      mp.set_property_number("sub-outline-size", 1.65)
      mp.set_property("sub-color", "#FFFFFFFF")
      mp.set_property("sub-font", "sans-serif")
      services.subtitle_position:set_baseline(services.subtitle_position.configured)
      render()
    end
    node.header = ChapterHeader(on_back, "Subtitle Settings", "arrow_back", {
      name = "subtitle-style-reset",
      icon = "restart_alt",
      tooltip = "Reset Subtitle Settings",
      on_click = reset_subtitle_style
    })
    node.delay = SubtitleAdjustRow("subtitle-delay", "Timing", 
      function()
        mp.set_property_number("sub-delay", clamp(node.delay_value - 0.1, -10, 10))
      end,
      function()
        mp.set_property_number("sub-delay", clamp(node.delay_value + 0.1, -10, 10))
      end)
    node.font_size_row = SubtitleAdjustRow("subtitle-font-size", "Font size",
      function()
        mp.set_property_number("sub-font-size", clamp(node.font_size - 2, 10, 120))
      end,
      function()
        mp.set_property_number("sub-font-size", clamp(node.font_size + 2, 10, 120))
      end)
    -- sub-pos counts down from the bottom (100), so raising lowers it
    local function move_subtitles(step)
      local position = services.subtitle_position
      position:set_baseline(clamp(position.baseline + step, 0, 150))
      render() -- sub-pos isn't observed, so redraw to show the new value
    end
    node.height_row = SubtitleAdjustRow("subtitle-height", "Height",
      function() move_subtitles(1) end, function() move_subtitles(-1) end)
    node.border = SubtitleAdjustRow("subtitle-border", "Border",
      function()
        mp.set_property_number("sub-outline-size", clamp(node.border_size - 0.5, 0, 10))
      end,
      function()
        mp.set_property_number("sub-outline-size", clamp(node.border_size + 0.5, 0, 10))
      end)
    node.color_row = SubtitleAdjustRow("subtitle-color", "Color",
      function()
        local item = cycle_option(subtitle_colors, normalize_subtitle_color(node.color), -1,
          function(v) return v.value end)
        mp.set_property("sub-color", item.value)
      end,
      function()
        local item = cycle_option(subtitle_colors, normalize_subtitle_color(node.color), 1,
          function(v) return v.value end)
        mp.set_property("sub-color", item.value)
      end)
    node.font_row = SubtitleAdjustRow("subtitle-font", "Font",
      function()
        mp.set_property("sub-font", cycle_option(subtitle_fonts, node.font, -1, function(v) return v end))
      end,
      function()
        mp.set_property("sub-font", cycle_option(subtitle_fonts, node.font, 1, function(v) return v end))
      end)
    function node:update(props)
      update_fields(self, props)
      self.modifier.fixed_width, self.modifier.fixed_height = self.width, self.height
      self.modifier.pointer_enabled = self.interactive
      self.header:update({alpha = self.text_alpha, hover_alpha = self.hover_alpha,
        interactive = self.interactive})
      local common = {interactive = self.interactive, text_alpha = self.text_alpha,
        secondary_alpha = self.secondary_alpha, hover_alpha = self.hover_alpha}
      common.value = string.format("%+.1fs", self.delay_value); self.delay:update(common)
      common.value = string.format("%g", self.font_size); self.font_size_row:update(common)
      self.position = services.subtitle_position.baseline
      common.value = string.format("%g", 100 - self.position); self.height_row:update(common)
      common.value = string.format("%g", self.border_size); self.border:update(common)
      local color_name = normalize_subtitle_color(self.color)
      for _, item in ipairs(subtitle_colors) do
        if item.value == color_name then color_name = item.name break end
      end
      common.value = color_name; self.color_row:update(common)
      common.value = self.font; self.font_row:update(common)
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = self.width, h = self.height}, parent)
    end
    function node:draw(ass, bounds)
      draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
        dp(30), "#050708", self.panel_alpha)
      draw_node(self.header, ass, Rect({x = bounds.x, y = bounds.y, w = bounds.w, h = dp(56)}))
      local rows = {self.delay, self.font_size_row, self.height_row, self.border,
        self.color_row, self.font_row}
      local y = bounds.y + dp(60)
      for _, row in ipairs(rows) do
        draw_node(row, ass, Rect({x = bounds.x + dp(8), y = y,
          w = bounds.w - dp(16), h = dp(44)}))
        y = y + dp(44)
      end
    end
    return node
  end

  local crop_presets = {
    {label = "Original", value = "", mode = "original"},
    {label = "Stretch", value = "stretch", mode = "stretch"},
    {label = "Fit to Screen", value = "fit", mode = "fit"},
    {label = "16:9", value = "16:9", ratio = 16 / 9},
    {label = "21:9", value = "21:9", ratio = 21 / 9},
    {label = "4:3", value = "4:3", ratio = 4 / 3},
    {label = "1:1", value = "1:1", ratio = 1},
    {label = "9:16", value = "9:16", ratio = 9 / 16}
  }

  local function crop_preset_value(value)
    value = tostring(value or "")
    if value == "" then return "" end
    local width, height = value:match("^(%d+)[xX](%d+)")
    width, height = tonumber(width), tonumber(height)
    if not width or not height or height <= 0 then return nil end
    local ratio = width / height
    for _, preset in ipairs(crop_presets) do
      if preset.ratio and math.abs(ratio - preset.ratio) < 0.015 then
        return preset.value
      end
    end
    return nil
  end

  local function crop_label(value, keepaspect, panscan)
    local selected
    if keepaspect == false then selected = "stretch"
    elseif (tonumber(panscan) or 0) > 0.99 and tostring(value or "") == "" then
      selected = "fit"
    else selected = crop_preset_value(value) end
    for _, preset in ipairs(crop_presets) do
      if preset.value == selected then return preset.label end
    end
    value = tostring(value or "")
    return value == "" and "Original" or value
  end

  local function apply_crop_preset(item)
    mp.set_property("video-aspect-override", "no")
    if item.mode == "stretch" then
      mp.set_property("video-crop", "")
      mp.set_property_native("keepaspect", false)
      mp.set_property_number("panscan", 0)
      return
    elseif item.mode == "fit" then
      mp.set_property("video-crop", "")
      mp.set_property_native("keepaspect", true)
      mp.set_property_number("panscan", 1)
      return
    elseif not item.ratio then
      mp.set_property("video-crop", "")
      mp.set_property_native("keepaspect", true)
      mp.set_property_number("panscan", 0)
      return
    end
    mp.set_property_native("keepaspect", true)
    mp.set_property_number("panscan", 0)
    local params = mp.get_property_native("video-dec-params") or {}
    local width, height = tonumber(params.w), tonumber(params.h)
    if not width or not height or width <= 0 or height <= 0 then
      services.toast:error(
        "Video dimensions are unavailable", {duration = 2})
      return
    end
    local pixel_aspect = 1
    local display_width, display_height = tonumber(params.dw), tonumber(params.dh)
    if display_width and display_height and display_width > 0 and display_height > 0 then
      pixel_aspect = (display_width / display_height) / (width / height)
    end
    local target_pixel_ratio = item.ratio / pixel_aspect
    local crop_width, crop_height = width, height
    if width / height > target_pixel_ratio then
      crop_width = math.floor(height * target_pixel_ratio / 2 + 0.5) * 2
    else
      crop_height = math.floor(width / target_pixel_ratio / 2 + 0.5) * 2
    end
    crop_width = clamp(crop_width, 2, width)
    crop_height = clamp(crop_height, 2, height)
    mp.set_property("video-crop", string.format("%dx%d", crop_width, crop_height))
  end

  local function CropPill(name, item, on_click)
    on_click = on_click or apply_crop_preset
    local node = {
      item = item, selected = false, interactive = false,
      text_alpha = "00", hover_alpha = "00", selected_alpha = "00",
      modifier = Modifier():height(dp(42)):clickable({
        name = name, enabled = false,
        on_click = function() on_click(item) end
      })
    }
    function node:update(props)
      update_fields(self, props)
      self.modifier.pointer_enabled = self.interactive
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = parent.w, h = dp(42)}, parent)
    end
    function node:draw(ass, bounds)
      local hovered = self.interactive and mouse_in(bounds)
      draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
        bounds.h / 2, self.selected and opts.accent_color or "#FFFFFF",
        self.selected and self.selected_alpha or (hovered and self.hover_alpha or "D8"))
      local icon = self.item.icon
      if icon then
        local icon_size, gap = dp(20), dp(6)
        local label_width = text_width(self.item.label, 19)
        local group_width = icon_size + gap + label_width
        local start_x = bounds.x + (bounds.w - group_width) / 2
        draw_icon(ass, start_x + icon_size / 2,
          bounds.y + bounds.h / 2, icon, "#FFFFFF", 20, self.text_alpha)
        draw_text(ass, start_x + icon_size + gap, bounds.y + bounds.h / 2,
          self.item.label, 19, "#FFFFFF", self.text_alpha,
          default_text_font, 4)
      else
        draw_text(ass, bounds.x + bounds.w / 2, bounds.y + bounds.h / 2,
          self.item.label, 19, "#FFFFFF", self.text_alpha,
          default_text_font, nil, false, false)
      end
    end
    return node
  end

  local function VideoCropPopup(on_back)
    local node = {
      width = dp(400), height = dp(164), selected = "", interactive = false,
      panel_alpha = "00", text_alpha = "00", hover_alpha = "00",
      selected_alpha = "00", modifier = Modifier():clickable({
        name = "video-crop-panel", enabled = false, on_click = function() end
      })
    }
    node.header = ChapterHeader(on_back, "Crop", "arrow_back", {
      name = "video-crop-aspect-override",
      icon = "aspect_ratio",
      tooltip = "Aspect Override",
      on_click = function() set_settings_page("video_aspect") end
    })
    node.mode_pills, node.ratio_pills = {}, {}
    for index, preset in ipairs(crop_presets) do
      if preset.mode then
        preset.icon = preset.mode == "original" and "aspect_ratio" or
          (preset.mode == "stretch" and "open_in_full" or "fit_screen")
        node.mode_pills[#node.mode_pills + 1] = CropPill(
          "video-crop-mode-" .. tostring(index), preset)
      else
        node.ratio_pills[#node.ratio_pills + 1] = CropPill(
          "video-crop-ratio-" .. tostring(index), preset)
      end
    end
    function node:update(props)
      update_fields(self, props)
      self.modifier.fixed_width, self.modifier.fixed_height = self.width, self.height
      self.modifier.pointer_enabled = self.interactive
      self.header:update({alpha = self.text_alpha, hover_alpha = self.hover_alpha,
        interactive = self.interactive})
      local common = {interactive = self.interactive, text_alpha = self.text_alpha,
        hover_alpha = self.hover_alpha, selected_alpha = self.selected_alpha}
      for _, pill in ipairs(self.mode_pills) do
        common.selected = pill.item.value == self.selected
        pill:update(common)
      end
      for _, pill in ipairs(self.ratio_pills) do
        common.selected = pill.item.value == self.selected
        pill:update(common)
      end
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = self.width, h = self.height}, parent)
    end
    function node:draw(ass, bounds)
      draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
        dp(30), "#050708", self.panel_alpha)
      draw_node(self.header, ass, Rect({x = bounds.x, y = bounds.y,
        w = bounds.w, h = dp(56)}))
      local inset, gap = dp(8), dp(8)
      local mode_width = (bounds.w - inset * 2 - gap * 2) / 3
      local x, y = bounds.x + inset, bounds.y + dp(64)
      for _, pill in ipairs(self.mode_pills) do
        draw_node(pill, ass, Rect({x = x, y = y, w = mode_width, h = dp(42)}))
        x = x + mode_width + gap
      end
      local ratio_gap = gap
      local ratio_width = (bounds.w - inset * 2 -
        ratio_gap * (#self.ratio_pills - 1)) / #self.ratio_pills
      x, y = bounds.x + inset, bounds.y + dp(114)
      for _, pill in ipairs(self.ratio_pills) do
        draw_node(pill, ass, Rect({x = x, y = y, w = ratio_width, h = dp(42)}))
        x = x + ratio_width + ratio_gap
      end
    end
    return node
  end

  local aspect_presets = {
    {label = "Original", value = "no"},
    {label = "16:9", value = "16:9", ratio = 16 / 9},
    {label = "21:9", value = "21:9", ratio = 21 / 9},
    {label = "4:3", value = "4:3", ratio = 4 / 3},
    {label = "1:1", value = "1:1", ratio = 1},
    {label = "9:16", value = "9:16", ratio = 9 / 16}
  }

  local function aspect_preset_value(value)
    value = normalize_aspect_override(value)
    if value == "no" then return "no" end
    local left, right = value:match("^([%d%.]+):([%d%.]+)$")
    local ratio = left and tonumber(left) / tonumber(right) or tonumber(value)
    if not ratio then return value end
    for _, preset in ipairs(aspect_presets) do
      if preset.ratio and math.abs(ratio - preset.ratio) < 0.015 then
        return preset.value
      end
    end
    return value
  end

  local function aspect_label(value)
    local selected = aspect_preset_value(value)
    for _, preset in ipairs(aspect_presets) do
      if preset.value == selected then return preset.label end
    end
    return selected == "no" and "Original" or selected
  end

  local function apply_aspect_preset(item)
    if item.value ~= "no" then
      mp.set_property("video-crop", "")
      mp.set_property_native("keepaspect", true)
      mp.set_property_number("panscan", 0)
    end
    mp.set_property("video-aspect-override", item.value)
  end

  local function VideoAspectPopup(on_back)
    local node = {
      width = dp(400), height = dp(164), selected = "no", interactive = false,
      panel_alpha = "00", text_alpha = "00", hover_alpha = "00",
      selected_alpha = "00", modifier = Modifier():clickable({
        name = "video-aspect-panel", enabled = false, on_click = function() end
      })
    }
    node.header = ChapterHeader(on_back, "Aspect Override", "arrow_back")
    node.pills = {}
    for index, preset in ipairs(aspect_presets) do
      node.pills[index] = CropPill(
        "video-aspect-preset-" .. tostring(index), preset,
        apply_aspect_preset)
    end
    function node:update(props)
      update_fields(self, props)
      self.modifier.fixed_width, self.modifier.fixed_height = self.width, self.height
      self.modifier.pointer_enabled = self.interactive
      self.header:update({alpha = self.text_alpha, hover_alpha = self.hover_alpha,
        interactive = self.interactive})
      local common = {interactive = self.interactive, text_alpha = self.text_alpha,
        hover_alpha = self.hover_alpha, selected_alpha = self.selected_alpha}
      for _, pill in ipairs(self.pills) do
        common.selected = pill.item.value == self.selected
        pill:update(common)
      end
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = self.width, h = self.height}, parent)
    end
    function node:draw(ass, bounds)
      draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
        dp(30), "#050708", self.panel_alpha)
      draw_node(self.header, ass, Rect({x = bounds.x, y = bounds.y,
        w = bounds.w, h = dp(56)}))
      local inset, gap = dp(8), dp(8)
      local pill_width = (bounds.w - inset * 2 - gap * 2) / 3
      for index, pill in ipairs(self.pills) do
        local column = (index - 1) % 3
        local row = math.floor((index - 1) / 3)
        draw_node(pill, ass, Rect({
          x = bounds.x + inset + column * (pill_width + gap),
          y = bounds.y + dp(64) + row * dp(50),
          w = pill_width, h = dp(42)
        }))
      end
    end
    return node
  end

  local function VideoSettingsPopup(on_back)
    local node = {
      width = dp(380), height = dp(332), interactive = false,
      panel_alpha = "00", text_alpha = "00", secondary_alpha = "00",
      hover_alpha = "00", crop = "", gamma = 0, brightness = 0,
      contrast = 0, saturation = 0, rotation = 0, shader_count = 0,
      keepaspect = true, panscan = 0,
      modifier = Modifier():clickable({
        name = "video-settings-panel", enabled = false, on_click = function() end
      })
    }
    local function reset_video_settings()
      mp.set_property("video-crop", "")
      mp.set_property("video-aspect-override", "no")
      mp.set_property_native("keepaspect", true)
      mp.set_property_number("panscan", 0)
      mp.set_property_number("gamma", 0)
      mp.set_property_number("brightness", 0)
      mp.set_property_number("contrast", 0)
      mp.set_property_number("saturation", 0)
      mp.set_property_number("video-rotate", 0)
    end
    node.header = ChapterHeader(on_back, "Video Settings", "arrow_back", {
      name = "video-settings-reset", icon = "restart_alt",
      tooltip = "Reset Video Settings",
      on_click = reset_video_settings
    })
    node.gamma_row = SubtitleAdjustRow("video-settings-gamma", "Gamma",
      function()
        mp.set_property_number("gamma", clamp(node.gamma - 5, -100, 100))
      end,
      function()
        mp.set_property_number("gamma", clamp(node.gamma + 5, -100, 100))
      end)
    node.brightness_row = SubtitleAdjustRow(
      "video-settings-brightness", "Brightness",
      function()
        mp.set_property_number("brightness", clamp(node.brightness - 5, -100, 100))
      end,
      function()
        mp.set_property_number("brightness", clamp(node.brightness + 5, -100, 100))
      end)
    node.contrast_row = SubtitleAdjustRow(
      "video-settings-contrast", "Contrast",
      function()
        mp.set_property_number("contrast", clamp(node.contrast - 5, -100, 100))
      end,
      function()
        mp.set_property_number("contrast", clamp(node.contrast + 5, -100, 100))
      end)
    node.saturation_row = SubtitleAdjustRow(
      "video-settings-saturation", "Saturation",
      function()
        mp.set_property_number("saturation", clamp(node.saturation - 5, -100, 100))
      end,
      function()
        mp.set_property_number("saturation", clamp(node.saturation + 5, -100, 100))
      end)
    node.rotation_row = SubtitleAdjustRow("video-settings-rotation", "Rotate",
      function()
        mp.set_property_number("video-rotate", (node.rotation - 90) % 360)
      end,
      function()
        mp.set_property_number("video-rotate", (node.rotation + 90) % 360)
      end)
    node.shaders_row = SettingsActionRow("video-settings-shaders", "texture",
      function() set_settings_page("video_shaders") end)
    function node:update(props)
      update_fields(self, props)
      self.modifier.fixed_width, self.modifier.fixed_height = self.width, self.height
      self.modifier.pointer_enabled = self.interactive
      self.header:update({alpha = self.text_alpha, hover_alpha = self.hover_alpha,
        interactive = self.interactive})
      local common = {interactive = self.interactive, text_alpha = self.text_alpha,
        secondary_alpha = self.secondary_alpha, hover_alpha = self.hover_alpha}
      common.value = string.format("%+d", math.floor(self.gamma + 0.5))
      self.gamma_row:update(common)
      common.value = string.format("%+d", math.floor(self.brightness + 0.5))
      self.brightness_row:update(common)
      common.value = string.format("%+d", math.floor(self.contrast + 0.5))
      self.contrast_row:update(common)
      common.value = string.format("%+d", math.floor(self.saturation + 0.5))
      self.saturation_row:update(common)
      common.value = string.format("%d°", math.floor(self.rotation + 0.5) % 360)
      self.rotation_row:update(common)
      common.label, common.value = "Shaders", tostring(self.shader_count)
      self.shaders_row:update(common)
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = self.width, h = self.height}, parent)
    end
    function node:draw(ass, bounds)
      draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
        dp(30), "#050708", self.panel_alpha)
      draw_node(self.header, ass, Rect({x = bounds.x, y = bounds.y,
        w = bounds.w, h = dp(56)}))
      local rows = {
        {self.gamma_row, 44}, {self.brightness_row, 44},
        {self.contrast_row, 44}, {self.saturation_row, 44},
        {self.rotation_row, 44}, {self.shaders_row, 44}
      }
      local y = bounds.y + dp(60)
      for _, entry in ipairs(rows) do
        draw_node(entry[1], ass, Rect({x = bounds.x + dp(8), y = y,
          w = bounds.w - dp(16), h = dp(entry[2])}))
        y = y + dp(entry[2])
      end
    end
    return node
  end

  local function SettingsPopup(on_close)
    local node = {
      width = dp(480), height = dp(260), interactive = false,
      modifier = Modifier():clickable({
        name = "settings-dialog-panel", enabled = false, on_click = function() end
      })
    }
    node.header = ChapterHeader(on_close, "Settings")
    node.video_row = SettingsActionRow("settings-video-row", "videocam",
      function() set_settings_page("video") end)
    node.audio_row = SettingsActionRow("settings-audio-row", "record_voice_over",
      function() set_settings_page("audio") end)
    node.subtitle_row = SettingsActionRow("settings-subtitle-row", "subtitles",
      function() set_settings_page("subtitles") end)
    node.crop_row = SettingsActionRow("settings-crop-row", "crop",
      function() set_settings_page("video_crop") end)
    node.speed_row = SettingsActionRow("settings-speed-row", "speed",
      function() set_settings_page("speed") end)
    node.video = TrackPopup(function() set_settings_page("root") end, {
      name = "settings-video", title = "Video", action_icon = "arrow_back",
      right_action = {
        name = "settings-video-options", icon = "tune",
        tooltip = "Video Settings",
        on_click = function() set_settings_page("video_settings") end
      },
      state = settings_state,
      on_select = function(item)
        if item.id == 0 then
          mp.set_property("vid", "no")
        elseif item.image then
          open_image_track(item)
          return false
        elseif item.stream_quality then
          -- the file reloads: close Settings so its keys (Enter, Space,
          -- arrows) don't stay captured until the new quality plays
          set_settings_dialog_open(false)
          select_stream_quality(item)
          return false
        else mp.set_property_number("vid", tonumber(item.id)) end
      end
    })
    node.audio = TrackPopup(function() set_settings_page("root") end, {
      name = "settings-audio", title = "Audio", action_icon = "arrow_back",
      state = settings_state,
      on_select = function(item)
        if item.id == 0 then mp.set_property("aid", "no")
        else mp.set_property_number("aid", tonumber(item.id)) end
      end
    })
    node.subtitles = TrackPopup(function() set_settings_page("root") end, {
      name = "settings-subtitles", title = "Subtitles", action_icon = "arrow_back",
      footer = {label = "Add", icon = "add", on_click = open_subtitle_file_picker},
      secondary_footer = {label = "Link", icon = "link",
        on_click = open_subtitle_link_picker},
      right_action = {
        {
          name = "settings-secondary-subtitles",
          icon = "filter_2",
          tooltip = "Secondary Subtitles",
          on_click = function() set_settings_page("secondary_subtitles") end
        },
        {
          name = "settings-subtitles-style",
          icon = "subtitles_gear",
          tooltip = "Subtitle Settings",
          on_click = function() set_settings_page("subtitle_style") end
        }
      },
      state = settings_state,
      on_select = function(item)
        if item.auto_page then
          set_settings_page("auto_captions")
          return false
        elseif item.id == 0 then mp.set_property("sid", "no")
        else
          mp.set_property_number("sid", tonumber(item.id))
          mp.set_property_native("sub-visibility", true)
        end
      end
    })
    node.secondary_subtitles = TrackPopup(function() set_settings_page("subtitles") end, {
      name = "settings-secondary-subtitles", title = "Secondary Subtitle",
      action_icon = "arrow_back", state = settings_state,
      footer = {label = "Add", icon = "add",
        on_click = open_secondary_subtitle_file_picker},
      secondary_footer = {label = "Link", icon = "link",
        on_click = open_secondary_subtitle_link_picker},
      on_select = function(item)
        if item.id == 0 then
          mp.set_property("secondary-sid", "no")
        else
          mp.set_property_number("secondary-sid", tonumber(item.id))
          mp.set_property_native("secondary-sub-visibility", true)
        end
      end
    })
    node.auto_captions = TrackPopup(function() set_settings_page("subtitles") end, {
      name = "settings-auto-captions", title = "Auto Captions",
      action_icon = "arrow_back", state = settings_state,
      on_select = function(item)
        attach_ytdl_caption(item)
        return false
      end
    })
    node.speed = SpeedPopup(function() set_settings_page("root") end)
    node.subtitle_style = SubtitleStylePopup(function() set_settings_page("subtitles") end)
    node.video_settings = VideoSettingsPopup(function()
      set_settings_page("video")
    end)
    node.video_crop = VideoCropPopup(function() set_settings_page("root") end)
    node.video_aspect = VideoAspectPopup(function()
      set_settings_page("video_crop")
    end)
    node.video_shaders = TrackPopup(function()
      set_settings_page("video_settings")
    end, {
      name = "settings-video-shaders", title = "Shaders", action_icon = "arrow_back",
      state = settings_state,
      footer = {label = "Add", icon = "add", on_click = open_shader_file_picker},
      secondary_footer = {label = "Link", icon = "link",
        on_click = open_shader_link_picker},
      right_action = {
        name = "settings-video-shaders-clear", icon = "delete_sweep",
        tooltip = "Clear Shaders",
        on_click = clear_shaders
      },
      is_selected = function() return false end,
      on_action = function(item)
        remove_shader(item.id)
      end,
      on_select = function()
        return false
      end
    })
    function node:update(props)
      update_fields(self, props)
      if self.video_keepaspect == false then
        self.video_crop_selected = "stretch"
      elseif (tonumber(self.video_panscan) or 0) > 0.99 and
        tostring(self.video_crop_value or "") == "" then
        self.video_crop_selected = "fit"
      else
        self.video_crop_selected = crop_preset_value(self.video_crop_value)
      end
      self.video_aspect_selected =
        aspect_preset_value(self.video_aspect_override)
      self.modifier.fixed_width, self.modifier.fixed_height = self.width, self.height
      self.modifier.pointer_enabled = self.interactive
      local common = {interactive = self.interactive, text_alpha = self.text_alpha,
        secondary_alpha = self.secondary_alpha, hover_alpha = self.hover_alpha,
        selected_alpha = self.selected_alpha}
      self.header:update({alpha = self.text_alpha,
        title_alpha = ass_alpha_for_opacity((self.opacity or 0) * 0.70),
        hover_alpha = self.hover_alpha,
        interactive = self.interactive})
      common.label, common.value = "Video (" ..
        tostring(self.video_track_count or #self.video_items) .. ")",
        selected_track_label(self.video_items, self.video_id, "None")
      self.video_row:update(common)
      common.label, common.value = "Audio (" ..
        math.max(0, #self.audio_items - 1) .. ")",
        selected_track_label(self.audio_items, self.audio_id, "None")
      self.audio_row:update(common)
      common.label, common.value = "Subtitles (" ..
        tostring(self.subtitle_track_count or math.max(0, #self.subtitle_items - 1)) .. ")",
        selected_track_label(self.subtitle_items, self.subtitle_id, "Off")
      self.subtitle_row:update(common)
      common.label = "Crop"
      common.value = self.video_aspect_selected ~= "no" and
        ("Aspect " .. aspect_label(self.video_aspect_override)) or
        crop_label(self.video_crop_value, self.video_keepaspect,
          self.video_panscan)
      self.crop_row:update(common)
      common.label, common.value = "Playback Speed", string.format("%gx", self.speed_value)
      self.speed_row:update(common)
      local page_props = {
        interactive = self.interactive, panel_alpha = self.panel_alpha,
        text_alpha = self.text_alpha, secondary_alpha = self.secondary_alpha,
        hover_alpha = self.hover_alpha, selected_alpha = self.selected_alpha,
        scrollbar_opacity = self.scrollbar_opacity
      }
      page_props.width, page_props.height = self.width, self.height
      page_props.layout_height = self.layout_height
      if settings_state.page == "video" then
        page_props.items, page_props.active_id = self.video_items, self.video_id
        self.video:update(page_props)
      elseif settings_state.page == "audio" then
        page_props.items, page_props.active_id = self.audio_items, self.audio_id
        self.audio:update(page_props)
      elseif settings_state.page == "subtitles" then
        page_props.items, page_props.active_id = self.subtitle_items, self.subtitle_id
        self.subtitles:update(page_props)
      elseif settings_state.page == "secondary_subtitles" then
        page_props.items = self.subtitle_items
        page_props.active_id = self.secondary_subtitle_id
        self.secondary_subtitles:update(page_props)
      elseif settings_state.page == "auto_captions" then
        page_props.items, page_props.active_id = {}, nil
        for _, item in ipairs(self.auto_caption_items or {}) do
          local row_item = {}
          for key, value in pairs(item) do row_item[key] = value end
          row_item.loading = item.id == ytdl_state.caption_loading_id
          page_props.items[#page_props.items + 1] = row_item
        end
        self.auto_captions:update(page_props)
      elseif settings_state.page == "speed" then
        page_props.speed = self.speed_value
        self.speed:update(page_props)
      elseif settings_state.page == "subtitle_style" then
        page_props.delay_value = self.subtitle_delay
        page_props.font_size = self.subtitle_font_size
        page_props.border_size = self.subtitle_border_size
        page_props.color = self.subtitle_color
        page_props.font = self.subtitle_font
        self.subtitle_style:update(page_props)
      elseif settings_state.page == "video_settings" then
        page_props.crop = self.video_crop_value
        page_props.keepaspect = self.video_keepaspect
        page_props.panscan = self.video_panscan
        page_props.gamma = self.video_gamma
        page_props.brightness = self.video_brightness
        page_props.contrast = self.video_contrast
        page_props.saturation = self.video_saturation
        page_props.rotation = self.video_rotation
        page_props.shader_count = #self.shader_items
        self.video_settings:update(page_props)
      elseif settings_state.page == "video_crop" then
        page_props.selected = self.video_crop_selected
        self.video_crop:update(page_props)
      elseif settings_state.page == "video_aspect" then
        page_props.selected = self.video_aspect_selected
        self.video_aspect:update(page_props)
      elseif settings_state.page == "video_shaders" then
        page_props.items = self.shader_items
        self.video_shaders:update(page_props)
      end
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = self.width, h = self.height}, parent)
    end
    function node:draw(ass, bounds)
      local page
      if settings_state.page == "video" then page = self.video end
      if settings_state.page == "audio" then page = self.audio end
      if settings_state.page == "subtitles" then page = self.subtitles end
      if settings_state.page == "secondary_subtitles" then
        page = self.secondary_subtitles
      end
      if settings_state.page == "auto_captions" then
        page = self.auto_captions
      end
      if settings_state.page == "speed" then page = self.speed end
      if settings_state.page == "subtitle_style" then
        page = self.subtitle_style
      end
      if settings_state.page == "video_settings" then
        page = self.video_settings
      end
      if settings_state.page == "video_crop" then
        page = self.video_crop
      end
      if settings_state.page == "video_aspect" then
        page = self.video_aspect
      end
      if settings_state.page == "video_shaders" then
        page = self.video_shaders
      end
      if page then
        push_clip(bounds)
        page:draw(ass, bounds)
        pop_clip()
        return
      end
      draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
        dp(30), "#050708", self.panel_alpha)
      push_clip(bounds)
      draw_node(self.header, ass, Rect({x = bounds.x, y = bounds.y, w = bounds.w, h = dp(56)}))
      local y = bounds.y + dp(64)
      local rows = {self.video_row}
      rows[#rows + 1] = self.audio_row
      rows[#rows + 1] = self.subtitle_row
      rows[#rows + 1] = self.crop_row
      rows[#rows + 1] = self.speed_row
      for _, row in ipairs(rows) do
        draw_node(row, ass, Rect({x = bounds.x + dp(8), y = y,
          w = bounds.w - dp(16), h = dp(44)}))
        y = y + dp(48)
      end
      pop_clip()
    end
    return node
  end

  local function close_or_reverse_from_anchor(dialog_state, anchor_name, set_open)
    if not dialog_state.open then
      local anchor = input.hitboxes[anchor_name]
      if anchor and mouse_in(anchor) then
        set_open(true)
        return
      end
    end
    set_open(false)
  end

  local function ChapterDialogHost()
    local close = function()
      close_or_reverse_from_anchor(
        chapter_state, "chapter-display", set_chapter_dialog_open)
    end
    return PopupHost({
      name = "chapter-dialog", state = chapter_state,
      anchor_name = "chapter-display", anchor_start = true, on_close = close,
      opacity_animation = chapter_state.fade,
      morph = true,
      popup = ChapterPopup(close),
      update_popup = function(popup, snapshot, opacity, interactive,
          progress, anchor)
        local content_opacity = opacity * morph_content_opacity(opacity)
        local props = popup_visual_props(content_opacity, interactive)
        props.opacity = content_opacity
        props.panel_alpha = ass_alpha_for_opacity(
          morph_shell_opacity(chapter_state.open, opacity))
        props.scrollbar_opacity =
          progress >= 0.9 and content_opacity or 0
        local target_width =
          math.max(dp(160), math.min(dp(320), viewport.w - dp(24)))
        local content_h = dp(72) + #snapshot.chapters * dp(48)
        if #snapshot.chapters > 0 then content_h = content_h - dp(4) end
        local max_h = math.max(dp(116), math.min(dp(480), viewport.h - dp(24)))
        local whole_rows = math.max(1,
          math.floor((max_h - dp(68)) / dp(48)))
        max_h = dp(68) + whole_rows * dp(48)
        local target_height = clamp(content_h, dp(116), max_h)
        props.width = morph_size(anchor and anchor.w, target_width,
          progress, dp(42))
        props.height = morph_size(anchor and anchor.h, target_height,
          progress, dp(42))
        props.layout_height = target_height
        props.chapters = snapshot.chapters
        props.selected_index = snapshot.chapter_index or -1
        popup:update(props)
      end
    })
  end

  local function TrackDialogHost(args)
    return PopupHost({
      name = args.name, state = args.state, anchor_name = args.anchor_name,
      on_close = args.close, popup = args.create_popup(args.close),
      update_popup = function(popup, snapshot, opacity, interactive)
        local props = popup_visual_props(opacity, interactive)
        props.width = math.max(dp(220), math.min(dp(420), viewport.w - dp(24)))
        local items = snapshot[args.items_key]
        local content_h = dp(72) + #items * dp(48)
        if #items > 0 then content_h = content_h - dp(4) end
        props.height = clamp(content_h, dp(116),
          math.max(dp(116), math.min(dp(480), viewport.h - dp(24))))
        props.items, props.active_id = items, snapshot[args.active_key]
        popup:update(props)
      end
    })
  end

  local function SettingsDialogHost()
    local close_from_backdrop = function()
      close_or_reverse_from_anchor(
        settings_state, "settings-button", set_settings_dialog_open)
    end
    return PopupHost({
      name = "settings-dialog", state = settings_state,
      anchor_name = "settings-button",
      opacity_animation = settings_state.fade,
      morph = true,
      on_close = close_from_backdrop,
      popup = SettingsPopup(function() set_settings_dialog_open(false) end),
      update_popup = function(popup, snapshot, opacity, interactive,
          progress, anchor)
        local video_items = snapshot.video_items or {}
        local audio_items = snapshot.audio_items or {}
        local subtitle_items = snapshot.subtitle_items or {}
        local wide_page = settings_state.page == "subtitles" or
          settings_state.page == "secondary_subtitles" or
          settings_state.page == "auto_captions" or
          settings_state.page == "video_shaders"
        local desired_w = wide_page and dp(420) or
          ((settings_state.page == "video_crop" or
              settings_state.page == "video_aspect") and dp(400) or
            (settings_state.page == "video_settings" and dp(380) or dp(320)))
        local target_w = math.max(dp(300), math.min(desired_w, viewport.w - dp(24)))
        local item_count = 0
        if settings_state.page == "video" then item_count = #video_items
        elseif settings_state.page == "audio" then item_count = #audio_items
        elseif settings_state.page == "subtitles" or
          settings_state.page == "secondary_subtitles" then
          item_count = #subtitle_items + (settings_state.page == "subtitles" and
            ytdl_state.source == "youtube" and 1 or 0)
        elseif settings_state.page == "auto_captions" then
          item_count = #ytdl_state.caption_items
        elseif settings_state.page == "video_shaders" then
          item_count = #(snapshot.shader_items or {})
        end
        local desired_h
        if settings_state.page == "root" then
          desired_h = dp(308)
        elseif settings_state.page == "speed" then desired_h = dp(190)
        elseif settings_state.page == "subtitle_style" then desired_h = dp(332)
        elseif settings_state.page == "video_settings" then desired_h = dp(332)
        elseif settings_state.page == "video_crop" or
          settings_state.page == "video_aspect" then desired_h = dp(164)
        elseif settings_state.page == "video_shaders" and item_count == 0 then
          desired_h = dp(116)
        else
          local has_footer = settings_state.page == "subtitles" or
            settings_state.page == "secondary_subtitles" or
            settings_state.page == "video_shaders"
          desired_h = dp(68) + math.max(1, item_count) * dp(48) +
            (has_footer and dp(48) or 0)
        end
        local max_h = math.max(dp(116), math.min(dp(480), viewport.h - dp(24)))
        if settings_state.page == "video" or settings_state.page == "audio" or
          settings_state.page == "subtitles" or
          settings_state.page == "secondary_subtitles" or
          settings_state.page == "auto_captions" or
          settings_state.page == "video_shaders" then
          local whole_rows = math.max(1, math.floor((max_h - dp(68)) / dp(48)))
          max_h = dp(68) + whole_rows * dp(48)
        end
        local target_h = clamp(desired_h, dp(116), max_h)
        if settings_state.transition_phase == "resize" then
          settings_state.width_animation:set_target(target_w)
          settings_state.height_animation:set_target(target_h)
          settings_state.resize_started = true
        elseif not settings_state.transition_phase then
          local fully_open = settings_state.open and
            not settings_state.animation:is_running() and
            settings_state.animation.value >= 0.999
          if fully_open then
            -- Track/content changes can alter the target without going through
            -- a page transition. Once open, always spring to those dimensions
            -- with the same geometry response used by the context menu.
            settings_state.width_animation:set_target(target_w)
            settings_state.height_animation:set_target(target_h)
          else
            -- Opening already morphs from the launcher, so establish the final
            -- page size without introducing a second competing spring.
            settings_state.width_animation:snap(target_w)
            settings_state.height_animation:snap(target_h)
          end
        end
        local content_opacity = opacity * settings_state.content_animation.value *
          morph_content_opacity(opacity)
        local props = popup_visual_props(content_opacity, interactive)
        props.opacity = opacity
        props.panel_alpha = ass_alpha_for_opacity(
          morph_shell_opacity(settings_state.open, opacity))
        props.scrollbar_opacity =
          progress >= 0.9 and content_opacity or 0
        props.width = morph_size(anchor and anchor.w,
          settings_state.width_animation.value, progress, dp(42))
        props.height = morph_size(anchor and anchor.h,
          settings_state.height_animation.value, progress, dp(42))
        props.layout_height = target_h
        props.video_items = video_items
        props.video_id = snapshot.video_id
        props.video_track_count = snapshot.video_track_count
        props.audio_items = audio_items
        props.audio_id = snapshot.audio_id
        props.subtitle_items = subtitle_items
        props.subtitle_id = snapshot.subtitle_id
        props.secondary_subtitle_id = snapshot.secondary_subtitle_id
        props.auto_caption_items = ytdl_state.caption_items or {}
        props.speed_value = snapshot.speed or 1
        props.subtitle_delay = snapshot.subtitle_delay or 0
        props.subtitle_font_size = snapshot.subtitle_font_size or 38
        props.subtitle_border_size = snapshot.subtitle_border_size or 1.65
        props.subtitle_color = snapshot.subtitle_color or "#FFFFFFFF"
        props.subtitle_font = snapshot.subtitle_font or "sans-serif"
        props.video_crop_value = snapshot.video_crop or ""
        props.video_aspect_override = snapshot.video_aspect_override or "no"
        props.video_keepaspect = snapshot.video_keepaspect ~= false
        props.video_panscan = snapshot.video_panscan or 0
        props.video_gamma = snapshot.video_gamma or 0
        props.video_brightness = snapshot.video_brightness or 0
        props.video_contrast = snapshot.video_contrast or 0
        props.video_saturation = snapshot.video_saturation or 0
        props.video_rotation = snapshot.video_rotation or 0
        props.shader_items = snapshot.shader_items or {}
        popup:update(props)
      end
    })
  end

  local SubtitleDialogHost = function()
    return TrackDialogHost({
      name = "subtitle-dialog", state = subtitle_state,
      anchor_name = "subtitles-button", items_key = "subtitle_items",
      active_key = "subtitle_id", create_popup = SubtitlePopup,
      close = function() set_subtitle_dialog_open(false) end
    })
  end
  local AudioDialogHost = function()
    return TrackDialogHost({
      name = "audio-dialog", state = audio_state,
      anchor_name = "audio-button", items_key = "audio_items",
      active_key = "audio_id", create_popup = AudioPopup,
      close = function() set_audio_dialog_open(false) end
    })
  end


  return {
    ChapterDialogHost = ChapterDialogHost,
    SubtitleDialogHost = SubtitleDialogHost,
    AudioDialogHost = AudioDialogHost,
    SettingsDialogHost = SettingsDialogHost
  }
end

return popups
