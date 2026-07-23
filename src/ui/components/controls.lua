local controls = {}

function controls.new(services)
  local state, ui, player = services.state, services.ui, services.player
  local navigation, config = services.navigation, services.config
  local pointer, volume_state = state.pointer, state.volume
  local seek_state, tooltip_state = state.seek, state.tooltip
  local time_state, chapter_state = state.time, state.chapter
  local settings_state = state.settings
  local get_snapshot = player.snapshot
  local dp, clamp = ui.dp, ui.clamp
  local smooth_step, lerp = ui.smooth_step, ui.lerp
  local ass_alpha_for_opacity = ui.alpha
  local draw_rect, draw_box, draw_text = ui.draw_rect, ui.draw_box, ui.draw_text
  local draw_seekbar, mouse_in = ui.draw_seekbar, ui.mouse_in
  local text_width, format_time = ui.text_width, ui.format_time
  local render = services.effects.render
  local preview_seek_to_mouse = player.preview_seek_to_mouse
  local seek_pos_from_mouse, seek_to_pos = player.seek_pos_from_mouse, player.seek_to_pos
  local set_chapter_dialog_open = navigation.set_chapter_open
  local set_settings_dialog_open = navigation.set_settings_open
  local toggle_subtitles, cycle_subtitle = navigation.toggle_subtitles, navigation.cycle_subtitle
  local tooltip_delay, tooltip_slide_distance = config.tooltip_delay, config.tooltip_slide_distance
  local max_volume_percentage = config.max_volume_percentage
  local default_text_font = ui.default_text_font
  local Modifier, Rect = ui.Modifier, ui.Rect
  local apply_modifier_size, measure_node = ui.apply_modifier_size, ui.measure_node
  local content_bounds = ui.content_bounds
  local draw_node, IconButton, TextItem = ui.draw_node, ui.IconButton, ui.TextItem
  local Visibility, Row, Pill = ui.Visibility, ui.Row, ui.Pill
  local is_render_pass = ui.is_render_pass

  local function VolumeSlider()
    local node = {
      volume = 0,
      max_volume_percentage = max_volume_percentage,
      progress = 0,
      track_y1 = 0,
      track_y2 = 0,
      modifier = Modifier():fillMaxWidth():fillMaxHeight()
    }

    local function set_from_mouse()
      local track_length = node.track_y2 - node.track_y1
      if track_length <= 0 then return end
      local value = clamp((node.track_y2 - pointer.y) / track_length, 0, 1)
      mp.set_property_number("volume", value * node.max_volume_percentage)
    end

    node.modifier:pointerArea({
      name = "volume-slider",
      enabled = false,
      on_press = function()
        volume_state.dragging = true
        set_from_mouse()
        render()
      end,
      on_move = function()
        if volume_state.dragging then set_from_mouse() end
      end,
      on_release = function()
        set_from_mouse()
        volume_state.dragging = false
        render()
      end,
      on_scroll_up = function() mp.commandv("add", "volume", "5") end,
      on_scroll_down = function() mp.commandv("add", "volume", "-5") end
    })

    function node:update(snapshot, progress)
      self.volume = clamp(snapshot.volume or 0, 0,
        snapshot.max_volume_percentage or max_volume_percentage)
      self.max_volume_percentage = math.max(100,
        snapshot.max_volume_percentage or max_volume_percentage)
      self.progress = progress
      self.modifier.pointer_enabled = progress > 0.2
    end

    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end

    function node:draw(ass, bounds)
      local track_x = bounds.x + bounds.w / 2
      self.track_y1 = bounds.y + dp(18)
      self.track_y2 = bounds.y2 - dp(10)
      local track_length = self.track_y2 - self.track_y1
      if track_length <= dp(2) then return end

      local fade_progress = smooth_step(clamp(self.progress, 0, 1))
      local inactive_alpha = ass_alpha_for_opacity(fade_progress * 0.4)
      local active_alpha = ass_alpha_for_opacity(fade_progress)
      local track_w = dp(4)
      local handle_y = self.track_y2 -
        track_length * self.volume / self.max_volume_percentage
      local normal_limit_y = self.track_y2 -
        track_length * 100 / self.max_volume_percentage
      local boosted = self.volume > 100
      local active_color = boosted and "#FF9800" or "#FFFFFF"
      local handle_w = dp(24)
      local handle_h = volume_state.dragging and dp(2) or dp(4)
      local handle_gap = dp(4)
      local active_start_y = handle_y + handle_h / 2 + handle_gap

      draw_rect(ass, track_x - track_w / 2, self.track_y1,
            track_x + track_w / 2, handle_y - handle_h / 2 - handle_gap,
            "#FFFFFF", inactive_alpha)

      if boosted then
        draw_rect(ass, track_x - track_w / 2, active_start_y,
              track_x + track_w / 2, normal_limit_y,
              "#FF9800", active_alpha)
        draw_rect(ass, track_x - track_w / 2, normal_limit_y,
              track_x + track_w / 2, self.track_y2,
              "#FFFFFF", active_alpha)
      else
        draw_rect(ass, track_x - track_w / 2, active_start_y,
              track_x + track_w / 2, self.track_y2,
              "#FFFFFF", active_alpha)
      end

      draw_box(ass, track_x - handle_w / 2, handle_y - handle_h / 2,
           track_x + handle_w / 2, handle_y + handle_h / 2,
           handle_h / 2, active_color, active_alpha)
    end

    return node
  end

  local function VolumeControl()
    local node = {modifier = Modifier():drawBehindInteraction(false)}
    node.button = IconButton({
      name = "volume-button",
      icon = "volume_up",
      render_pass = "dynamic",
      tooltip = "Mute",
      on_click = function() mp.commandv("cycle", "mute") end,
      on_scroll_up = function()
        volume_state.tooltip_suppressed_until = mp.get_time() + tooltip_delay
        mp.commandv("add", "volume", "5")
      end,
      on_scroll_down = function()
        volume_state.tooltip_suppressed_until = mp.get_time() + tooltip_delay
        mp.commandv("add", "volume", "-5")
      end
    })
    node.slider = VolumeSlider()
    node.slider.modifier.render_pass = "dynamic"

    function node:update(snapshot)
      local tooltip = nil
      if mp.get_time() >= volume_state.tooltip_suppressed_until then
        tooltip = snapshot.muted and "Unmute" or "Mute"
      end
      self.button:update({
        icon = snapshot.muted and "volume_off" or "volume_up",
        tooltip = tooltip,
        clear_tooltip = tooltip == nil
      })
      self.slider:update(snapshot, volume_state.animation.value)
    end

    function node:measure(parent) return self.button:measure(parent) end

    function node:draw(ass, bounds)
      self.bounds = bounds
      volume_state.button_bounds = bounds
      if is_render_pass("base") then
        draw_node(self.button, ass, bounds)
        return
      end
      if is_render_pass("interaction") then
        draw_node(self.button, ass, bounds)
        return
      end
      if not is_render_pass("dynamic") then return end
      local popup_w = dp(42)
      local expanded_h = dp(142) + bounds.h + dp(4)
      local popup_x1 = bounds.x + bounds.w / 2 - popup_w / 2
      local popup_y2 = bounds.y2 + dp(4)
      local collapsed_y1 = bounds.y - dp(4)
      local expanded_y1 = popup_y2 - expanded_h
      local visual_progress = clamp(volume_state.animation.value, 0, 1.08)
      local popup = Rect({
        x = popup_x1,
        y = lerp(collapsed_y1, expanded_y1, visual_progress),
        w = popup_w,
        h = popup_y2 - lerp(collapsed_y1, expanded_y1, visual_progress)
      })
      volume_state.popup_bounds = popup

      local popup_alpha = mouse_in(popup) and "00" or "78"
      draw_box(ass, popup.x1, popup.y1, popup.x2, popup.y2,
           popup.w / 2, "#050708", popup_alpha)

      local slider_bounds = Rect({
        x = popup.x,
        y = popup.y,
        w = popup.w,
        h = math.max(0, bounds.y - popup.y)
      })
      if slider_bounds.h > 0 then draw_node(self.slider, ass, slider_bounds) end
      draw_node(self.button, ass, bounds)
    end

    return node
  end

  local function SeekBar()
    local node = {modifier = Modifier():fillMaxWidth():height(dp(28))}
    node.modifier:pointerArea({
      name = "seekbar",
      extend_y = dp(6),
      on_press = function(box)
        local duration = get_snapshot().duration or 0
        local current_pos = get_snapshot().position or 0
        local handle_x = box.x1
        if duration > 0 and box.x2 > box.x1 then
          handle_x = box.x1 + (box.x2 - box.x1) * clamp(current_pos / duration, 0, 1)
        end
        seek_state.offset_x = math.abs(pointer.x - handle_x) <= dp(6) and
                      (handle_x - pointer.x) or 0
        seek_state.dragging = true
        preview_seek_to_mouse(box)
      end,
      on_move = function(box)
        if seek_state.dragging then preview_seek_to_mouse(box) end
      end,
      on_release = function(box)
        local pos = seek_pos_from_mouse(box)
        seek_state.position = pos
        seek_to_pos(pos)
        seek_state.dragging = false
        seek_state.position = nil
        seek_state.offset_x = 0
      end,
      on_scroll_up = function() mp.commandv("seek", "5", "relative") end,
      on_scroll_down = function() mp.commandv("seek", "-5", "relative") end
    })

    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end
    function node:draw(ass, bounds)
      self.bounds = bounds
      if not is_render_pass("dynamic") then return end
      draw_seekbar(ass, bounds.x, bounds.y + dp(14), bounds.x2)
    end
    return node
  end

  local function VideoSurface()
    local node = {modifier = Modifier():fillMaxWidth():fillMaxHeight()}
    node.modifier:pointerArea({
      name = "video-surface",
      on_click = config.opts.single_click_actions_enabled and
        function() mp.commandv("cycle", "pause") end or nil,
      on_double = function() mp.commandv("cycle", "fullscreen") end
    })
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end
    function node:draw() end
    return node
  end

  local function ControlsRow()
    local node = {modifier = Modifier():fillMaxWidth()}
    node.play = IconButton({name = "play-button", icon = "pause", tooltip = "Pause",
      on_click = function() mp.commandv("cycle", "pause") end})
    node.volume = VolumeControl()
    node.time = TextItem({
      text = "0:00 / 0:00",
      render_pass = "dynamic",
      modifier = Modifier():clickable({
        name = "time-display",
        on_click = function()
          time_state.show_remaining = not time_state.show_remaining
          render()
        end
      })
    })
    node.chapter_text = TextItem({text = ""})
    node.chapter = Visibility({
      visible = false,
      modifier = Modifier():clickable({
        name = "chapter-display",
        on_click = function()
          local open = not chapter_state.open
          if open then
            chapter_state.scroll_index = math.max(0,
              (get_snapshot().chapter_index or 0) - 2)
          end
          set_chapter_dialog_open(open)
        end
      }),
      child = Pill({
        horizontal_padding = 8,
        children = {node.chapter_text}
      })
    })

    local widest_digit = "0"
    local widest_digit_width = text_width(widest_digit, node.time.size)
    for digit = 1, 9 do
      local candidate = tostring(digit)
      local candidate_width = text_width(candidate, node.time.size)
      if candidate_width > widest_digit_width then
        widest_digit = candidate
        widest_digit_width = candidate_width
      end
    end

    local function stable_time_width(snapshot)
      local duration_text = format_time(snapshot.duration or 0)
      local widest_time = duration_text:gsub("%d", widest_digit)
      local reference = "-" .. widest_time .. " / " .. widest_time
      return math.max(text_width(reference, node.time.size),
              text_width(snapshot.time_text, node.time.size))
    end

    node.starting = Row({
      gap = dp(8),
      modifier = Modifier():align({horizontal = "starting", vertical = "center"}),
      children = {
        Pill({children = {node.play}}),
        Pill({no_background = true, children = {node.volume}}),
        Pill({children = {node.time}}),
        node.chapter
      }
    })
    node.subtitles = IconButton({name = "subtitles-button", icon = "subtitles", tooltip = "Subtitles",
      on_click = toggle_subtitles,
      on_scroll_up = function() cycle_subtitle(-1) end,
      on_scroll_down = function() cycle_subtitle(1) end})
    node.subtitles_visibility = Visibility({
      visible = false,
      child = node.subtitles
    })
    node.screenshot = IconButton({name = "screenshot-button", icon = "photo_camera",
      tooltip = "Take screenshot",
      on_click = function() mp.commandv("screenshot", "subtitles") end})
    node.settings = IconButton({name = "settings-button", icon = "settings", tooltip = "Settings",
      on_click = function()
        set_settings_dialog_open(not settings_state.open)
      end})
    node.fullscreen = IconButton({name = "fullscreen-button", icon = "open_in_full", tooltip = "Fullscreen",
      on_click = function() mp.commandv("cycle", "fullscreen") end})
    node.ending = Pill({
      children = {node.subtitles_visibility, node.screenshot, node.settings, node.fullscreen},
      modifier = Modifier():align({horizontal = "ending", vertical = "center"})
    })

    function node:update(snapshot, static_changed)
      if static_changed then
        self.play:update({
          icon = snapshot.paused and "play_arrow" or "pause",
          tooltip = snapshot.paused and "Play" or "Pause"
        })
      end
      local volume_progress = volume_state.animation.value
      if static_changed or volume_state.dragging or
        self.last_volume_progress ~= volume_progress then
        self.volume:update(snapshot)
        self.last_volume_progress = volume_progress
      end
      if static_changed or self.last_duration ~= snapshot.duration then
        self.time.modifier.fixed_width = stable_time_width(snapshot)
        self.last_duration = snapshot.duration
      end
      self.time:update({text = snapshot.time_text})
      if static_changed then
        self.chapter_text:update({text = snapshot.chapter_name or ""})
        self.chapter:set_visible(snapshot.chapter_name ~= nil)
        local subtitles_on = snapshot.subtitle_id ~= 0 and snapshot.sub_visibility
        self.subtitles_visibility:set_visible(#snapshot.subtitle_items > 1)
        self.subtitles:update({
          icon = subtitles_on and "subtitles" or "subtitles_off",
          tooltip = subtitles_on and "Hide subtitles" or "Show subtitles"
        })
        self.fullscreen:update({
          icon = snapshot.fullscreen and "close_fullscreen" or "open_in_full",
          tooltip = snapshot.fullscreen and "Exit fullscreen" or "Fullscreen"
        })
      end
    end

    function node:measure(parent)
      local starting_size = measure_node(self.starting, parent)
      local ending_size = measure_node(self.ending, parent)
      return apply_modifier_size(self.modifier, {
        w = math.max(starting_size.w, ending_size.w),
        h = math.max(starting_size.h, ending_size.h)
      }, parent)
    end

    function node:draw(ass, bounds)
      draw_node(self.starting, ass, bounds)
      draw_node(self.ending, ass, bounds)
    end

    function node:draw_dynamic(ass)
      if self.volume.bounds then self.volume:draw(ass, self.volume.bounds) end
      if self.time.bounds then self.time:draw(ass, self.time.bounds) end
    end

    return node
  end

  local function WindowControls()
    local node = {
      modifier = Modifier():padding({all = dp(12)}):align({
        horizontal = "ending", vertical = "top"
      })
    }
    node.minimize = IconButton({
      name = "window-minimize-button", icon = "minimize", size = 22,
      tooltip = "Minimize",
      on_click = function() mp.set_property_bool("window-minimized", true) end
    })
    node.maximize = IconButton({
      name = "window-maximize-button", icon = "crop_square", size = 22,
      icon_size = 18,
      tooltip = "Maximize",
      on_click = function()
        if node.fullscreen then mp.set_property_bool("fullscreen", false)
        else mp.commandv("cycle", "window-maximized") end
      end
    })
    node.close = IconButton({
      name = "window-close-button", icon = "close", size = 22,
      tooltip = "Close",
      on_click = function() mp.commandv("quit") end
    })
    node.close.modifier.hover_color = "#E81123"
    node.close.modifier.hover_alpha = "40"
    node.pill = Pill({
      children = {node.minimize, node.maximize, node.close}
    })

    function node:update(snapshot)
      self.fullscreen = snapshot.fullscreen
      local restored = snapshot.fullscreen or snapshot.window_maximized
      self.maximize:update({
        icon = restored and "filter_none" or "crop_square",
        tooltip = snapshot.fullscreen and "Exit fullscreen" or
          (snapshot.window_maximized and "Restore" or "Maximize")
      })
    end

    function node:measure(parent)
      return apply_modifier_size(self.modifier, measure_node(self.pill, parent), parent)
    end

    function node:draw(ass, bounds)
      draw_node(self.pill, ass, content_bounds(bounds, self.modifier))
    end

    return node
  end

  local function WindowDragArea()
    local node = {
      modifier = Modifier():fillMaxWidth():height(
        ui.edge_seek_top_inset()):pointerArea({
          name = "window-drag-area"
        })
    }

    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end

    function node:draw() end
    return node
  end

  local function TooltipHost()
    local node = {
      suppressed = false,
      modifier = Modifier():fillMaxWidth():fillMaxHeight()
    }
    function node:set_suppressed(value) self.suppressed = value == true end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end
    function node:draw(ass)
      if self.suppressed and not tooltip_state.allow_when_suppressed then return end
      local visual = tooltip_state.visual
      local opacity = tooltip_state.opacity.value
      if visual and opacity > 0 then
        local alpha = ass_alpha_for_opacity(opacity)
        local slide_distance = dp(tooltip_slide_distance) * (1 - tooltip_state.slide.value)
        local slide_y = visual.slide_direction_y * slide_distance
        local y1 = visual.y1 + slide_y
        draw_box(ass, visual.x1, y1, visual.x2, y1 + visual.h,
             visual.h / 2, "#E8E8E8", alpha)
        draw_text(ass, visual.x1 + visual.w / 2, y1 + visual.h / 2,
              visual.text, visual.text_size, "#202020", alpha,
              default_text_font)
      end
    end
    return node
  end


  return {
    VolumeSlider = VolumeSlider,
    VolumeControl = VolumeControl,
    SeekBar = SeekBar,
    VideoSurface = VideoSurface,
    ControlsRow = ControlsRow,
    WindowDragArea = WindowDragArea,
    WindowControls = WindowControls,
    TooltipHost = TooltipHost
  }
end

return controls
