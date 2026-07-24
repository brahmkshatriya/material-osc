local mpv_runtime = {}

function mpv_runtime.new(args)
  local state, mp = args.state, args.mp
  local service = {
    original_cursor_autohide = nil,
    cursor_autohide = nil,
    mouse_areas = {}
  }

  local function same_area(area, x1, y1, x2, y2)
    return area and area[1] == x1 and area[2] == y1 and
      area[3] == x2 and area[4] == y2
  end

  function service:set_mouse_area(name, x1, y1, x2, y2)
    local previous = self.mouse_areas[name]
    if same_area(previous, x1, y1, x2, y2) then return end
    self.mouse_areas[name] = {x1, y1, x2, y2}
    mp.set_mouse_area(x1, y1, x2, y2, name)
  end

  function service:set_cursor_autohide(value)
    value = tostring(value)
    if self.cursor_autohide == value then return end
    self.cursor_autohide = value
    mp.set_property("cursor-autohide", value)
  end

  function service:update_mouse_area()
    self:set_mouse_area("material-osc-showhide", 0, 0, 0, 0)
    self:set_mouse_area("material-osc-input",
      0, 0, state.viewport.w, state.viewport.h)
    local controller = state.controller.bounds
    if controller and state.controller.opacity.value > 0 then
      self:set_mouse_area("material-osc-controller",
        controller.x1, controller.y1, controller.x2, controller.y2)
    else
      self:set_mouse_area("material-osc-controller", 0, 0, 0, 0)
    end
    local volume = state.volume.popup_bounds
    if volume then
      self:set_mouse_area("material-osc-volume-popup",
        volume.x1, volume.y1, volume.x2, volume.y2)
    else
      self:set_mouse_area("material-osc-volume-popup", 0, 0, 0, 0)
    end
  end

  function service:update_rate()
    local fps = mp.get_property_number("display-fps")
    if not fps or fps < 30 then
      fps = mp.get_property_number("estimated-display-fps")
    end
    fps = tonumber(fps) or 60
    -- Popup morphs benefit noticeably from matching high-refresh displays.
    -- The animation coordinator still throttles controller fades and ambient
    -- effects, so the higher ceiling only applies to short, interactive
    -- animations rather than idle playback.
    local interval = 1 / math.max(30, math.min(240, fps))
    if math.abs(interval - state.timers.frame_interval) < 0.0001 then return end
    state.timers.frame_interval = interval
    if state.timers.frame then
      state.timers.frame:kill()
      state.timers.frame = nil
      self:update_frame_timer()
    end
  end

  function service:update_frame_timer()
    local needs_frames = args.needs_continuous_render and
      args.needs_continuous_render() or false
    if needs_frames and not state.timers.frame then
      local interval = args.animation_interval and
        args.animation_interval(state.timers.frame_interval) or
        state.timers.frame_interval
      state.timers.frame = mp.add_timeout(interval, function()
        state.timers.frame = nil
        if args.render_continuous then args.render_continuous()
        else args.render_cached() end
      end)
    elseif not needs_frames and state.timers.frame then
      state.timers.frame:kill()
      state.timers.frame = nil
    end
  end

  function service:dispose()
    if state.timers.frame then state.timers.frame:kill() end
    state.timers.frame = nil
    if state.timers.render then state.timers.render:kill() end
    state.timers.render = nil
    if state.timers.hide then state.timers.hide:kill() end
    state.timers.hide = nil
    if state.timers.progress then state.timers.progress:kill() end
    state.timers.progress = nil
    if state.timers.pointer_move then state.timers.pointer_move:kill() end
    state.timers.pointer_move = nil
    if state.wheel.timer then state.wheel.timer:kill() end
    state.wheel.kind, state.wheel.amount, state.wheel.timer = nil, 0, nil
    if self.original_cursor_autohide ~= nil then
      mp.set_property("cursor-autohide", self.original_cursor_autohide)
    end
  end

  function service:on_file_loaded()
    state.media.loading = false
    if state.wheel.timer then state.wheel.timer:kill() end
    state.wheel.kind, state.wheel.amount, state.wheel.timer = nil, 0, nil
    args.close_context_menu()
    args.directory_playlist:load()
    args.navigation:reset()
    args.playback_indicator:reset()
    state.pointer.pending_click = nil
    if state.pointer.click_timer then
      state.pointer.click_timer:kill(); state.pointer.click_timer = nil
    end
    args.stream_quality:load()
    args.stream_quality:restore_subtitles()
    args.bookmarks:restore()
    args.render()
  end

  function service:start()
    self.original_cursor_autohide = mp.get_property("cursor-autohide")
    self.cursor_autohide = self.original_cursor_autohide
    local function controller() return args.controller() end
    local function render_dynamic()
      if args.render_dynamic then args.render_dynamic()
      else args.render_cached() end
    end
    mp.observe_property("osd-dimensions", "native",
      function(...) controller():on_dimensions(...) end)
    mp.observe_property("display-hidpi-scale", "number",
      function(...) controller():on_hidpi_scale(...) end)
    for _, property in ipairs({
      {"pause", "bool"}, {"mute", "bool"}, {"volume", "number"},
      {"chapter", "number"},
      {"chapter-list", "native"}, {"track-list", "native"}, {"sid", "number"},
      {"secondary-sid", "number"}, {"secondary-sub-visibility", "bool"},
      {"aid", "number"}, {"speed", "number"}, {"sub-visibility", "bool"},
      {"fullscreen", "bool"}, {"border", "bool"}, {"title-bar", "bool"},
      {"window-maximized", "bool"}, {"seeking", "bool"},
      {"paused-for-cache", "bool"}, {"cache-buffering-state", "number"},
      {"vid", "number"},
      {"video-out-params", "native"}, {"demuxer-via-network", "bool"},
      {"playlist", "native"}, {"playlist-pos", "number"},
      {"input-bindings", "native"},
      {"loop-playlist", "string"}, {"loop-file", "string"},
      {"ab-loop-a", "number"}, {"ab-loop-b", "number"},
      {"shuffle", "bool"}, {"media-title", "string"},
      {"video-crop", "string"}, {"keepaspect", "bool"},
      {"panscan", "number"}, {"video-rotate", "number"},
      {"gamma", "number"}, {"brightness", "number"},
      {"saturation", "number"}, {"glsl-shaders", "native"},
      {"sub-delay", "number"}, {"sub-font-size", "number"},
      {"sub-border-size", "number"}, {"sub-color", "string"},
      {"sub-font", "string"}, {"volume-max", "number"}
    }) do
      local name = property[1]
      mp.observe_property(name, property[2], function(_, value)
        state.properties[name] = value
        if args.property_changed then args.property_changed(name) end
        args.render()
      end)
    end
    for _, property in ipairs({
      {"container-fps", "number"}, {"estimated-vf-fps", "number"}
    }) do
      local name = property[1]
      mp.observe_property(name, property[2], function(_, value)
        state.properties[name] = value
        if args.property_changed then args.property_changed(name) end
      end)
    end
    local function render_controller_progress(_, value)
      if args.update_cached_property then
        args.update_cached_property("demuxer-cache-state", value)
      end
      state.properties["demuxer-cache-state"] = value
      if state.controller.opacity.value > 0.001 then render_dynamic() end
    end
    local function playback_visual_changed(value)
      local position = tonumber(value) or 0
      local duration = state.snapshot.duration or 0
      local displayed_second = state.time.show_remaining and duration > 0 and
        math.floor(math.max(0, duration - position)) or math.floor(position)
      local progress_pixel = duration > 0 and
        math.floor(position / duration * math.max(1, state.viewport.w) + 0.5) or 0
      local frame = state.frame
      if frame.progress_second == displayed_second and
        frame.progress_pixel == progress_pixel then
        return false
      end
      frame.progress_second = displayed_second
      frame.progress_pixel = progress_pixel
      return true
    end
    local function render_playback_position(_, value)
      if args.update_cached_property then
        args.update_cached_property("time-pos", value)
      end
      state.properties["time-pos"] = value
      if not playback_visual_changed(value) then return end
      if state.controller.opacity.value > 0.001 then
        if state.timers.progress then state.timers.progress:kill() end
        state.timers.progress = nil
        render_dynamic()
        return
      end
      if not args.hidden_playback_progress_visible or
        not args.hidden_playback_progress_visible() or state.timers.progress then
        return
      end
      state.timers.progress = mp.add_timeout(0.1, function()
        state.timers.progress = nil
        render_dynamic()
      end)
    end
    local function render_duration(_, value)
      if args.update_cached_property then
        args.update_cached_property("duration", value)
      end
      state.properties.duration = value
      state.frame.progress_second, state.frame.progress_pixel = nil, nil
      local duration = math.max(0, tonumber(value) or 0)
      local hours = math.floor(duration / 3600)
      local minutes = math.floor(duration / 60)
      local layout_key = hours > 0 and
        ("h" .. tostring(#tostring(hours))) or
        ("m" .. tostring(#tostring(minutes)))
      if state.frame.duration_layout_key ~= layout_key then
        state.frame.duration_layout_key = layout_key
        args.render_cached()
      else
        render_dynamic()
      end
    end
    local function update_subtitle_text(_, value)
      if args.update_cached_property then
        args.update_cached_property("sub-text", value)
      end
      state.properties["sub-text"] = value
      if state.context_menu.open then args.render_cached() end
    end
    mp.observe_property("time-pos", "number", render_playback_position)
    mp.observe_property("duration", "number", render_duration)
    mp.observe_property("sub-text", "string", update_subtitle_text)
    mp.observe_property("demuxer-cache-state", "native", render_controller_progress)
    mp.observe_property("display-fps", "number", function() self:update_rate() end)
    mp.observe_property("estimated-display-fps", "number", function() self:update_rate() end)

    local move = function() controller():on_mouse_move() end
    local leave = function() controller():on_mouse_leave() end
    mp.set_key_bindings({{"mouse_move", move}, {"mouse_leave", leave}},
      "material-osc-showhide", "force")
    mp.enable_key_bindings("material-osc-showhide",
      "allow-vo-dragging+allow-hide-cursor")
    mp.set_key_bindings({
      {"mouse_move", move}, {"mouse_leave", leave},
      {"mbtn_left_dbl", function() controller():on_primary_double() end},
      {"mbtn_right", function() controller():on_secondary_down() end},
      {"wheel_up", function() controller():on_wheel(-1) end},
      {"wheel_down", function() controller():on_wheel(1) end}
    }, "material-osc-input", "force")
    mp.enable_key_bindings("material-osc-input",
      "allow-hide-cursor+allow-vo-dragging")
    mp.set_key_bindings({{"ESC", args.close_context_menu}},
      "material-osc-context-menu", "force")
    mp.disable_key_bindings("material-osc-context-menu")
    for _, name in ipairs({"controller", "volume-popup"}) do
      local binding = "material-osc-" .. name
      mp.set_key_bindings({{"mouse_move", move}, {"mouse_leave", leave}}, binding, "force")
      mp.enable_key_bindings(binding)
    end

    for _, name in ipairs(args.navigation.dialogs) do
      local dialog_name = name
      mp.set_key_bindings({{"ESC", function()
        if dialog_name == "settings" and state.settings.open and
          state.settings.page ~= "root" then
          args.navigation:set_settings_page("root")
        elseif state[dialog_name].open then
          args.navigation:set_dialog_open(dialog_name, false)
        end
      end}}, args.navigation:binding(dialog_name), "force")
      mp.disable_key_bindings(args.navigation:binding(dialog_name))
    end
    mp.add_forced_key_binding("mbtn_left", "material-osc-primary",
      function(event) controller():on_primary_button(event) end, {complex = true})

    mp.register_script_message("material-osc-show", function() controller():show() end)
    mp.register_script_message("material-osc-hide",
      function() controller():animate_visibility(false) end)
    mp.register_script_message("material-osc-toggle", function()
      controller():animate_visibility(not state.controller.visible)
    end)
    mp.register_event("playback-restart", function()
      if not state.loading.quality_switching then return end
      state.loading.quality_switching = false
      args.render()
    end)
    mp.register_event("start-file", function()
      state.media.loading = true
      args.render()
    end)
    mp.register_event("end-file", function()
      state.media.loading = true
      args.render()
    end)
    mp.register_event("shutdown", function()
      self:dispose()
    end)
    mp.register_event("file-loaded", function() self:on_file_loaded() end)

    self:update_rate()
    args.render()
  end

  return service
end

return mpv_runtime
