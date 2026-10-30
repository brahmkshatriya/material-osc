local controls = {}

function controls.new(services)
  local state, ui, player = services.state, services.ui, services.player
  local timers = services.timers
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
  local draw_icon = ui.draw_icon
  local draw_seekbar, mouse_in = ui.draw_seekbar, ui.mouse_in
  local text_width, format_time = ui.text_width, ui.format_time
  local render = services.effects.render
  local render_all = services.effects.render_all or render
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
  local ConnectedPill = ui.ConnectedPill
  local is_render_pass = ui.is_render_pass

  local function set_pip_enabled(enabled, requested_window_state)
    timers:cancel(state.pip, "raise_timer")
    if enabled then
      state.pip.restore = {
        fullscreen = mp.get_property_native("fullscreen") == true,
        maximized = mp.get_property_native("window-maximized") == true,
        ontop = mp.get_property_native("ontop") == true,
        scale = mp.get_property_number("current-window-scale")
      }
      state.pip.active = true
      state.controller.visible = false
      state.controller.pointer_timed_out = true
      state.controller.opacity:snap(0)
      mp.set_property_bool("fullscreen", false)
      mp.set_property_bool("window-maximized", false)
      -- resize before pinning: on Windows a geometry change made right after
      -- ontop is ignored, leaving the pinned window at full size
      mp.set_property("geometry", "30%-24-24")
      mp.set_property_bool("ontop", true)
    else
      local restore = state.pip.restore or {}
      state.pip.active, state.pip.restore, state.pip.bounds = false, nil, nil
      mp.set_property_bool("fullscreen", false)
      if requested_window_state ~= "maximized" then
        mp.set_property_bool("window-maximized", false)
      end
      mp.set_property("geometry", "50%:50%")
      if restore.scale then
        mp.set_property_number("current-window-scale", restore.scale)
      end
      if requested_window_state == "maximized" then
        mp.set_property_bool("window-maximized", true)
      elseif requested_window_state == "fullscreen" then
        mp.set_property_bool("fullscreen", true)
      elseif restore.maximized then
        mp.set_property_bool("window-maximized", true)
      elseif restore.fullscreen then
        mp.set_property_bool("fullscreen", true)
      end
      if restore.ontop then
        mp.set_property_bool("ontop", true)
      else
        timers:after(state.pip, "raise_timer", 0.12, function()
          if not state.pip.active then
            mp.set_property_bool("ontop", false)
          end
        end)
      end
    end
    render_all()
  end

  services.pip = services.pip or {}
  services.pip.set_enabled = set_pip_enabled
  services.pip.exit_for_window_state = function(window_state)
    if not state.pip.active then return false end
    set_pip_enabled(false, window_state)
    return true
  end

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
    node.guard = {
      modifier = Modifier():pointerArea({
        name = "volume-popup-guard",
        enabled = false,
        on_click = function() end,
        on_scroll_up = function() mp.commandv("add", "volume", "5") end,
        on_scroll_down = function() mp.commandv("add", "volume", "-5") end
      })
    }
    function node.guard:measure(parent)
      return apply_modifier_size(self.modifier, {w = parent.w, h = parent.h}, parent)
    end
    function node.guard:draw() end
    node.button = IconButton({
      name = "volume-button",
      icon = "volume_up",
      render_pass = "dynamic",
      tooltip = "Mute",
      shortcut_before = {"volume-down", "volume-up"},
      shortcut = "mute",
      on_click = function() mp.commandv("cycle", "mute") end,
      on_scroll_up = function()
        volume_state.tooltip_suppressed_until = mp.get_time() + tooltip_delay()
        mp.commandv("add", "volume", "5")
      end,
      on_scroll_down = function()
        volume_state.tooltip_suppressed_until = mp.get_time() + tooltip_delay()
        mp.commandv("add", "volume", "-5")
      end
    })
    node.slider = VolumeSlider()
    node.slider.modifier.render_pass = "dynamic"

    function node:update(snapshot)
      local tooltip = nil
      if mp.get_time() >= volume_state.tooltip_suppressed_until then
        tooltip = ""
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
      self.guard.modifier.pointer_enabled = visual_progress > 0.2

      local popup_alpha = mouse_in(popup) and "00" or "58"
      draw_box(ass, popup.x1, popup.y1, popup.x2, popup.y2,
           popup.w / 2, "#050708", popup_alpha)

      local slider_bounds = Rect({
        x = popup.x,
        y = popup.y,
        w = popup.w,
        h = math.max(0, bounds.y - popup.y)
      })
      if slider_bounds.h > 0 then draw_node(self.slider, ass, slider_bounds) end
      local guard_height = math.max(0, popup.y2 - bounds.y2)
      if guard_height > 0 then
        draw_node(self.guard, ass, Rect({
          x = popup.x, y = bounds.y2, w = popup.w, h = guard_height
        }))
      end
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

  local function YouTubeActions()
    local node = {
      actions = {},
      chips = {},
      persistent = false,
      suppressed = false,
      action_signature = "",
      modifier = Modifier():height(dp(36))
    }

    local function actions_signature(actions)
      local values = {}
      for index, action in ipairs(actions) do
        values[index] = table.concat({
          tostring(action.name or ""),
          tostring(action.label or ""),
          action.compact and "1" or "0"
        }, "\0")
      end
      return table.concat(values, "\1")
    end

    local function ActionChip(index)
      local chip = {
        action = nil,
        persistent = false,
        suppressed = false,
        opacity = 1
      }
      chip.modifier = Modifier():height(dp(36)):clickable({
        name = "youtube-action-" .. tostring(index),
        enabled = false,
        on_click = function()
          local action = chip.action
          if action and action.enabled ~= false and action.on_click then
            action.on_click()
          end
        end
      })
      chip.modifier.render_pass = "dynamic"

      function chip:update(action, persistent, suppressed, opacity)
        self.action, self.persistent = action, persistent
        self.suppressed = suppressed == true
        self.opacity = clamp(tonumber(opacity) or 1, 0, 1)
        self.modifier.pointer_enabled =
          not self.suppressed and action ~= nil and action.enabled ~= false
        local hitbox = state.input.hitboxes[self.modifier.pointer_name]
        if hitbox then hitbox.enabled = self.modifier.pointer_enabled end
      end

      function chip:measure(parent)
        local action = self.action
        if not action then return {w = 0, h = 0} end
        local label = tostring(action.label or "")
        local width = action.compact and dp(36) or
          math.max(dp(44), dp(38) + text_width(label, 19) + dp(12))
        return apply_modifier_size(
          self.modifier, {w = width, h = dp(36)}, parent)
      end

      function chip:draw(ass, bounds)
        local action = self.action
        local opacity = self.opacity
        if not action or opacity <= 0.001 then return end
        local ignore_fade = self.persistent
        local function faded_alpha(value)
          local base_opacity =
            1 - (tonumber(value or "00", 16) or 0) / 255
          return ass_alpha_for_opacity(base_opacity * opacity)
        end
        if is_render_pass("dynamic") then
          local color =
            action.selected and config.opts.accent_color or "#050708"
          local alpha = faded_alpha(action.selected and "30" or "48")
          draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
            bounds.h / 2, color, alpha, ignore_fade)
          local label = tostring(action.label or "")
          local icon_x = label == "" and (bounds.x + bounds.w / 2) or
            (bounds.x + dp(19))
          draw_icon(ass, icon_x, bounds.y + bounds.h / 2,
            action.icon or "skip_next", "#FFFFFF", 22,
            faded_alpha(action.enabled == false and "90" or "00"),
            ignore_fade)
          if label ~= "" then
            draw_text(ass, bounds.x + dp(36), bounds.y + bounds.h / 2,
              label, 19, "#FFFFFF",
              faded_alpha(action.enabled == false and "90" or "00"),
              default_text_font, 4, nil, ignore_fade)
          end
          -- Paint the hover state with the chip itself so the seek preview,
          -- which is composed afterward, remains above the entire action.
          if action.enabled ~= false and mouse_in(bounds) then
            draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
              bounds.h / 2, "#FFFFFF", faded_alpha("D8"), ignore_fade)
          end
        end
        if not self.suppressed and opacity > 0.5 and action.tooltip and
          action.enabled ~= false and mouse_in(bounds) then
          ui.request_tooltip(action.tooltip, bounds, self.persistent)
        end
      end

      return chip
    end

    for index = 1, 8 do node.chips[index] = ActionChip(index) end

    function node:update(suppressed)
      -- These actions remain visible after the controller hides. Keep them
      -- independent of controller opacity during the fade as well, otherwise
      -- they disappear with the title row and pop back in as an overlay.
      self.persistent = true
      self.suppressed = suppressed == true
      local presence = state.sponsorblock.actions_opacity
      local desired_actions = services.sponsorblock and
        services.sponsorblock:prompt_actions() or {}
      local desired_signature = actions_signature(desired_actions)
      local now = ui.now()

      if desired_signature == self.action_signature then
        self.actions = desired_actions
        presence:set_target(
          #desired_actions > 0 and 1 or 0, now,
          #desired_actions > 0 and 0.16 or 0.12)
      elseif #self.actions == 0 or presence.value <= 0.001 then
        self.actions = desired_actions
        self.action_signature = desired_signature
        presence:set_target(
          #desired_actions > 0 and 1 or 0, now,
          #desired_actions > 0 and 0.16 or 0.12)
      else
        -- Fade the current group out before replacing it with a structurally
        -- different set, such as Skip/Dismiss becoming Vote/Undo.
        presence:set_target(0, now, 0.12)
      end

      self.opacity = clamp(
        state.playlist.controls_opacity.value * presence.value, 0, 1)
      local actions_suppressed = self.suppressed or
        desired_signature ~= self.action_signature
      for index, chip in ipairs(self.chips) do
        chip:update(
          self.actions[index], self.persistent,
          actions_suppressed, self.opacity)
      end
    end

    function node:measure(parent)
      if #self.actions == 0 then return {w = 0, h = 0} end
      local total = 0
      for index = 1, math.min(#self.actions, #self.chips) do
        total = total + self.chips[index]:measure(parent).w +
          (index > 1 and dp(6) or 0)
      end
      return apply_modifier_size(
        self.modifier, {w = total, h = dp(36)}, parent)
    end

    function node:draw(ass, bounds)
      self.bounds = bounds
      local gap = dp(6)
      local widths, total = {}, 0
      for index = 1, math.min(#self.actions, #self.chips) do
        widths[index] = self.chips[index]:measure(bounds).w
        total = total + widths[index] + (index > 1 and gap or 0)
      end
      local x = bounds.x
      for index = 1, #widths do
        local chip_bounds = Rect({
          x = x, y = bounds.y, w = widths[index], h = bounds.h
        })
        draw_node(self.chips[index], ass, chip_bounds)
        x = x + widths[index] + gap
      end
    end

    return node
  end

  local function SponsorBlockControls()
    local node = {
      actions = {},
      buttons = {},
      modifier = Modifier():drawBehindInteraction(false)
    }

    local function ActionButton(index)
      local button = {
        action = nil,
        modifier = Modifier():drawBehindInteraction(false)
      }
      button.icon = IconButton({
        icon = "flag",
        size = 30,
        icon_size = 30,
        modifier = Modifier():padding({
          horizontal = dp(6),
          vertical = dp(2)
        })
      })
      button.label = TextItem({
        text = "",
        size = 20,
        modifier = Modifier():padding({ending = dp(8)})
      })
      button.label_visibility = Visibility({
        visible = false,
        child = button.label
      })
      button.pill = Pill({
        gap = 0,
        horizontal_padding = 4,
        children = {button.icon, button.label_visibility},
        modifier = Modifier():clickable({
          name = "sponsorblock-tool-" .. tostring(index),
          enabled = false,
          on_click = function()
            local action = button.action
            if action and action.enabled ~= false and action.on_click then
              action.on_click()
            end
          end
        }):hoverIndication({inset = dp(4)})
      })
      button.pill.modifier:drawBehindInteraction(true)

      function button:update(action)
        self.action = action
        local enabled = action ~= nil and action.enabled ~= false
        self.pill.modifier.pointer_enabled = enabled
        local hitbox =
          state.input.hitboxes[self.pill.modifier.pointer_name]
        if hitbox then hitbox.enabled = enabled end
        if not action then return end
        local label = tostring(action.label or "")
        self.icon:update({
          icon = action.icon or "flag",
          enabled = enabled,
          alpha = enabled and "00" or "90"
        })
        self.label:update({
          text = label,
          alpha = enabled and "00" or "90"
        })
        self.label_visibility:set_visible(label ~= "")
        self.pill.tooltip = action.tooltip
        self.pill.modifier.background_color =
          action.selected and config.opts.accent_color or "#050708"
        self.pill.modifier.background_alpha =
          action.selected and "30" or "58"
      end

      function button:measure(parent)
        if not self.action then return {w = 0, h = 0} end
        return measure_node(self.pill, parent)
      end

      function button:draw(ass, bounds)
        if self.action then draw_node(self.pill, ass, bounds) end
      end

      return button
    end

    for index = 1, 6 do
      node.buttons[index] = ActionButton(index)
    end
    node.row = Row({gap = dp(8), children = node.buttons})

    function node:update()
      self.actions = services.sponsorblock and
        services.sponsorblock:tool_actions() or {}
      for index, button in ipairs(self.buttons) do
        button:update(self.actions[index])
      end
    end

    function node:measure(parent)
      return apply_modifier_size(
        self.modifier, measure_node(self.row, parent), parent)
    end

    function node:draw(ass, bounds)
      self.row:draw(ass, content_bounds(bounds, self.modifier))
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
      shortcut = "pause",
      on_click = function() mp.commandv("cycle", "pause") end})
    -- with prev_next_beside_play, previous/next sit beside play/pause
    -- instead of in the playlist pill
    local function step_playlist(direction)
      local snapshot = get_snapshot()
      local count = snapshot.playlist_count or 0
      local position = snapshot.playlist_pos or -1
      if snapshot.playlist_looping and direction < 0 and position <= 0 then
        mp.commandv("playlist-play-index", count - 1)
      elseif snapshot.playlist_looping and direction > 0 and position >= count - 1 then
        mp.commandv("playlist-play-index", 0)
      else
        mp.commandv(direction < 0 and "playlist-prev" or "playlist-next", "weak")
      end
    end
    node.previous = IconButton({name = "playlist-previous", icon = "skip_previous",
      tooltip = "Previous", shortcut = "playlist-prev",
      on_click = function() step_playlist(-1) end})
    node.next = IconButton({name = "playlist-next", icon = "skip_next",
      tooltip = "Next", shortcut = "playlist-next",
      on_click = function() step_playlist(1) end})
    node.volume = VolumeControl()
    node.time = TextItem({
      text = "0:00 / 0:00",
      render_pass = "dynamic",
      tooltip = "Toggle Remaining",
      modifier = Modifier():padding({
        horizontal = dp(10),
        vertical = dp(6)
      }):clickable({
        name = "time-display",
        on_click = function()
          time_state.show_remaining = not time_state.show_remaining
          render()
        end
      }):hoverIndication({inset = dp(4)})
    })
    node.chapter_text = TextItem({
      text = ""
    })
    node.chapter_chevron = IconButton({
      icon = "chevron_right",
      size = 20,
      icon_size = 20,
      modifier = Modifier()
    })
    node.chapter_leading_space = {
      modifier = Modifier(),
      measure = function(self, parent)
        return apply_modifier_size(self.modifier, {
          w = dp(12),
          h = dp(20)
        }, parent)
      end,
      draw = function() end
    }
    node.chapter_content = Row({
      gap = dp(4),
      children = {
        node.chapter_leading_space, node.chapter_text, node.chapter_chevron
      },
      modifier = Modifier():padding({
        starting = dp(4),
        ending = dp(8),
        vertical = dp(6)
      }):background({
        color = "#050708",
        alpha = "58",
        shape = {kind = "rounded", percent = 50}
      }):clickable({
        name = "chapter-display",
        on_click = function()
          local open = not chapter_state.open
          if open then
            chapter_state.scroll_index = math.max(0,
              (get_snapshot().chapter_index or 0) - 2)
          end
          set_chapter_dialog_open(open)
        end
      }):hoverIndication({inset = dp(4)})
    })
    node.chapter = Visibility({
      visible = false,
      child = node.chapter_content
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

    local function cached_duration(snapshot)
      local duration = math.max(0, tonumber(snapshot.duration) or 0)
      if not snapshot.network or duration <= 0 then return nil end
      local position = clamp(
        tonumber(snapshot.position) or 0, 0, duration)
      local ranges = (snapshot.cache_state or {})["seekable-ranges"] or {}
      local intervals = {}
      for _, range in ipairs(ranges) do
        local range_start = clamp(
          math.max(tonumber(range["start"]) or 0, position), 0, duration)
        local range_end = clamp(tonumber(range["end"]) or 0, 0, duration)
        if range_end > range_start then
          intervals[#intervals + 1] = {range_start, range_end}
        end
      end
      table.sort(intervals, function(a, b) return a[1] < b[1] end)
      local total, merged_start, merged_end = 0, nil, nil
      for _, interval in ipairs(intervals) do
        if not merged_start then
          merged_start, merged_end = interval[1], interval[2]
        elseif interval[1] <= merged_end then
          merged_end = math.max(merged_end, interval[2])
        else
          total = total + merged_end - merged_start
          merged_start, merged_end = interval[1], interval[2]
        end
      end
      if merged_start then total = total + merged_end - merged_start end
      return total
    end

    node.cached_time = TextItem({
      text = "0:00",
      color = "#000000",
      render_pass = "dynamic",
      tooltip = "Cached Time",
      modifier = Modifier():padding({
        starting = dp(4),
        ending = dp(12),
        vertical = dp(6)
      }):pointerArea({
        name = "cached-time",
        keyboard = false
      })
    })
    node.cached = Visibility({
      visible = false,
      child = node.cached_time
    })
    node.time_cache = ConnectedPill({
      primary = node.time,
      secondary = node.cached
    })

    local starting = {Pill({children = {node.play}})}
    if config.opts.prev_next_beside_play then
      starting[#starting + 1] = Pill({children = {node.previous, node.next}})
    end
    starting[#starting + 1] = Pill({no_background = true, children = {node.volume}})
    starting[#starting + 1] = node.time_cache
    starting[#starting + 1] = node.chapter
    node.starting = Row({
      gap = dp(8),
      modifier = Modifier():align({horizontal = "starting", vertical = "center"}),
      children = starting
    })
    node.subtitles = IconButton({name = "subtitles-button", icon = "subtitles",
      horizontal_padding = 6, tooltip = "Subtitles",
      shortcut = "subtitles",
      on_click = toggle_subtitles,
      on_scroll_up = function() cycle_subtitle(-1) end,
      on_scroll_down = function() cycle_subtitle(1) end})
    node.subtitles_visibility = Visibility({
      visible = false,
      child = node.subtitles
    })
    node.screenshot = IconButton({name = "screenshot-button", icon = "photo_camera",
      horizontal_padding = 6, tooltip = "Take Screenshot",
      shortcut = "screenshot",
      on_click = function() mp.commandv("screenshot", "subtitles") end})
    node.screenshot_visibility = Visibility({
      visible = config.opts.screenshot_button,
      child = node.screenshot
    })
    node.settings = IconButton({name = "settings-button", icon = "settings",
      horizontal_padding = 6, tooltip = "Settings",
      shortcut = "open-settings",
      on_click = function()
        set_settings_dialog_open(not settings_state.open)
      end})
    node.pip = IconButton({name = "picture-in-picture-button",
      icon = "picture_in_picture_alt", horizontal_padding = 6,
      tooltip = "Picture in Picture",
      on_click = function() set_pip_enabled(not state.pip.active) end})
    node.pip_visibility = Visibility({
      visible = config.opts.pip_button,
      child = node.pip
    })
    node.fullscreen = IconButton({name = "fullscreen-button",
      icon = "open_in_full", horizontal_padding = 6, tooltip = "Fullscreen",
      shortcut = "fullscreen",
      on_click = function() mp.commandv("cycle", "fullscreen") end})
    -- pin button: keeps the window on top at its current size (picture-in-picture
    -- has its own button)
    node.ontop = IconButton({name = "ontop-button", icon = "keep_off",
      horizontal_padding = 6, tooltip = "Pin Window", shortcut = "ontop",
      on_click = function() mp.commandv("cycle", "ontop") end})
    node.ontop_visibility = Visibility({
      visible = config.opts.ontop_button,
      child = node.ontop
    })
    -- info button, runs info_mbtn_left_command (the stats overlay by default)
    node.info = IconButton({name = "info-button", icon = "info",
      horizontal_padding = 6, tooltip = "Information",
      on_click = function() mp.command(config.opts.info_mbtn_left_command) end})
    node.info_visibility = Visibility({
      visible = config.opts.info_button,
      child = node.info
    })
    node.ending = Pill({
      gap = 0,
      children = {
        node.subtitles_visibility, node.screenshot_visibility,
        node.pip_visibility, node.settings, node.info_visibility,
        node.ontop_visibility, node.fullscreen
      },
      modifier = Modifier()
    })
    node.sponsorblock = SponsorBlockControls()
    node.ending_actions = Row({
      gap = dp(8),
      children = {node.sponsorblock, node.ending},
      modifier = Modifier():align({
        horizontal = "ending",
        vertical = "center"
      })
    })

    function node:update(snapshot, static_changed)
      self.sponsorblock:update()
      self.screenshot_visibility:set_visible(config.opts.screenshot_button)
      self.pip_visibility:set_visible(config.opts.pip_button)
      self.ontop_visibility:set_visible(config.opts.ontop_button)
      self.info_visibility:set_visible(config.opts.info_button)
      if static_changed then
        self.play:update({
          icon = snapshot.paused and "play_arrow" or "pause",
          tooltip = snapshot.paused and "Play" or "Pause"
        })
      end
      if static_changed and config.opts.prev_next_beside_play then
        local count, position = snapshot.playlist_count or 0, snapshot.playlist_pos or -1
        local wraps = snapshot.playlist_looping == true
        self.previous:update({
          enabled = count > 1 and position >= 0 and (wraps or position > 0)
        })
        self.next:update({
          enabled = count > 1 and position >= 0 and (wraps or position < count - 1)
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
        local duration_text = format_time(snapshot.duration or 0)
        self.cached_time.modifier.fixed_width =
          text_width(duration_text:gsub("%d", widest_digit),
            self.cached_time.size)
        self.last_duration = snapshot.duration
      end
      self.time:update({text = snapshot.time_text})
      local cached = cached_duration(snapshot)
      self.cached:set_visible(cached ~= nil)
      self.cached_time:update({text = format_time(cached or 0)})
      if static_changed then
        self.chapter_text:update({text = snapshot.chapter_name or ""})
        self.chapter:set_visible(snapshot.chapter_name ~= nil)
        local subtitles_on = snapshot.subtitle_id ~= 0 and snapshot.sub_visibility
        self.subtitles_visibility:set_visible(#snapshot.subtitle_items > 1)
        self.subtitles:update({
          icon = subtitles_on and "subtitles" or "subtitles_off",
          tooltip = subtitles_on and "Hide Subtitles" or "Show Subtitles"
        })
        self.pip:update({
          icon = state.pip.active and "pip_exit" or "picture_in_picture_alt",
          tooltip = state.pip.active and
            "Exit Picture in Picture" or "Picture in Picture"
        })
        self.fullscreen:update({
          icon = snapshot.fullscreen and "close_fullscreen" or "open_in_full",
          tooltip = snapshot.fullscreen and "Exit Fullscreen" or "Fullscreen"
        })
        local pinned = snapshot.ontop == true
        self.ontop:update({
          icon = pinned and "keep" or "keep_off",
          tooltip = pinned and "Unpin Window" or "Pin Window"
        })
      end
    end

    function node:measure(parent)
      local starting_size = measure_node(self.starting, parent)
      local ending_size = measure_node(self.ending_actions, parent)
      return apply_modifier_size(self.modifier, {
        w = math.max(starting_size.w, ending_size.w),
        h = math.max(starting_size.h, ending_size.h)
      }, parent)
    end

    function node:draw(ass, bounds)
      draw_node(self.starting, ass, bounds)
      draw_node(self.ending_actions, ass, bounds)
    end

    function node:draw_dynamic(ass)
      if self.volume.bounds then self.volume:draw(ass, self.volume.bounds) end
      if self.time.bounds then self.time:draw(ass, self.time.bounds) end
      if self.cached.visible and self.cached_time.bounds then
        self.cached_time:draw(ass, self.cached_time.bounds)
      end
    end

    function node:draw_volume_interaction(ass)
      if self.volume.bounds then self.volume:draw(ass, self.volume.bounds) end
    end

    return node
  end

  local function PipControl()
    local function exit_pip() set_pip_enabled(false) end
    local outer_padding = dp(12)
    local node = {
      modifier = Modifier():padding({all = outer_padding})
        :align({horizontal = "ending", vertical = "bottom"})
        :clickable({
          name = "picture-in-picture-exit-button",
          on_click = exit_pip
        })
        :hoverIndication({inset = outer_padding + dp(4)})
    }
    node.icon = IconButton({
      icon = "pip_exit", size = 30, icon_size = 28,
      modifier = Modifier():padding({
        horizontal = dp(6), vertical = dp(2)
      })
    })
    node.label = TextItem({
      text = "Exit PiP", size = 20,
      modifier = Modifier():padding({ending = dp(6)})
    })
    node.pill = Pill({
      gap = 0,
      children = {node.icon, node.label}
    })

    function node:measure(parent)
      return apply_modifier_size(
        self.modifier, measure_node(self.pill, parent), parent)
    end

    function node:draw(ass, bounds)
      draw_node(self.pill, ass, content_bounds(bounds, self.modifier))
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
      render_pass = "interaction", ignore_controller_fade = true,
      tooltip_allow_when_suppressed = true,
      horizontal_padding = 6, tooltip = "Minimize",
      on_click = function() mp.set_property_bool("window-minimized", true) end
    })
    node.maximize = IconButton({
      name = "window-maximize-button", icon = "crop_square", size = 22,
      render_pass = "interaction", ignore_controller_fade = true,
      tooltip_allow_when_suppressed = true,
      icon_size = 18, horizontal_padding = 6,
      tooltip = "Maximize",
      on_click = function()
        if state.pip.active then
          set_pip_enabled(false)
        elseif node.fullscreen then
          mp.set_property_bool("fullscreen", false)
        else
          mp.commandv("cycle", "window-maximized")
        end
      end
    })
    node.close = IconButton({
      name = "window-close-button", icon = "close", size = 22,
      render_pass = "interaction", ignore_controller_fade = true,
      tooltip_allow_when_suppressed = true,
      horizontal_padding = 6, hover_icon_color = "#000000", tooltip = "Close",
      on_click = function() mp.commandv("quit") end
    })
    node.close.modifier.hover_color = "#FF5263"
    node.close.modifier.hover_alpha = "40"
    node.pill = Pill({
      gap = 0,
      children = {node.minimize, node.maximize, node.close}
    })
    node.pill.modifier.render_pass = "interaction"
    node.pill.modifier.ignore_controller_fade = true
    node.pill_base_alpha = node.pill.modifier.background_alpha or "58"
    node.buttons = {node.minimize, node.maximize, node.close}
    for _, button in ipairs(node.buttons) do
      button.window_hover_alpha = button.modifier.hover_alpha
    end

    local function faded_alpha(base_alpha, opacity)
      local base = tonumber(base_alpha or "00", 16) or 0
      local base_opacity = 1 - base / 255
      return ass_alpha_for_opacity(base_opacity * opacity)
    end

    function node:set_interactive(interactive)
      interactive = interactive == true
      for _, button in ipairs(self.buttons) do
        button.modifier.pointer_enabled = interactive
        local hitbox = state.input.hitboxes[button.modifier.pointer_name]
        if hitbox then hitbox.enabled = interactive end
      end
    end

    function node:update(snapshot)
      self.fullscreen = snapshot.fullscreen
      local restored = snapshot.fullscreen or snapshot.window_maximized
      self.maximize:update({
        icon = restored and "filter_none" or "crop_square",
        tooltip = snapshot.fullscreen and "Exit Fullscreen" or
          (snapshot.window_maximized and "Restore" or "Maximize")
      })
    end

    function node:measure(parent)
      return apply_modifier_size(self.modifier, measure_node(self.pill, parent), parent)
    end

    function node:draw(ass, bounds)
      local opacity = clamp(state.window_controls.opacity.value, 0, 1)
      local icon_alpha = ass_alpha_for_opacity(opacity)
      self.pill.modifier.background_alpha =
        faded_alpha(self.pill_base_alpha, opacity)
      for _, button in ipairs(self.buttons) do
        button.alpha = icon_alpha
        button.modifier.hover_alpha =
          faded_alpha(button.window_hover_alpha, opacity)
      end
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
      local visual = tooltip_state.visual
      if self.suppressed and
          not (visual and visual.allow_when_suppressed) then return end
      local opacity = tooltip_state.opacity.value
      if visual and opacity > 0 then
        local alpha = ass_alpha_for_opacity(opacity)
        local ignore_controller_fade = visual.allow_when_suppressed == true
        local slide_distance = dp(tooltip_slide_distance) * (1 - tooltip_state.slide.value)
        local slide_y = visual.slide_direction_y * slide_distance
        local y1 = visual.y1 + slide_y
        draw_box(ass, visual.x1, y1, visual.x2, y1 + visual.h,
             visual.h / 2, "#E8E8E8", alpha, ignore_controller_fade)
        draw_text(ass, visual.text_x or (visual.x1 + visual.w / 2),
              y1 + visual.h / 2,
              visual.text, visual.text_size, "#202020", alpha,
              default_text_font, nil, nil, ignore_controller_fade)
        for _, keycap in ipairs(visual.keycaps or {}) do
          local cap_y1, cap_y2 = y1 + dp(4), y1 + visual.h - dp(4)
          draw_box(ass, keycap.x1, cap_y1, keycap.x1 + keycap.w, cap_y2,
            dp(5), "#C8C8C8", alpha, ignore_controller_fade)
          draw_text(ass, keycap.x1 + keycap.w / 2,
            y1 + visual.h / 2, keycap.label, visual.key_size,
            "#202020", alpha, default_text_font,
            nil, nil, ignore_controller_fade)
        end
      end
    end
    return node
  end


  return {
    VolumeSlider = VolumeSlider,
    VolumeControl = VolumeControl,
    SeekBar = SeekBar,
    YouTubeActions = YouTubeActions,
    SponsorBlockControls = SponsorBlockControls,
    VideoSurface = VideoSurface,
    ControlsRow = ControlsRow,
    PipControl = PipControl,
    WindowDragArea = WindowDragArea,
    WindowControls = WindowControls,
    TooltipHost = TooltipHost
  }
end

return controls
