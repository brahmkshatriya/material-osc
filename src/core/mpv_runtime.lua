local mpv_runtime = {}

function mpv_runtime.new(args)
  local state, mp = args.state, args.mp
  local service = {}

  function service:update_mouse_area()
    mp.set_mouse_area(0, 0, 0, 0, "material-osc-showhide")
    mp.set_mouse_area(0, 0, state.viewport.w, state.viewport.h, "material-osc-input")
    local controller = state.controller.bounds
    if controller and state.controller.opacity.value > 0 then
      mp.set_mouse_area(controller.x1, controller.y1, controller.x2, controller.y2,
        "material-osc-controller")
    else
      mp.set_mouse_area(0, 0, 0, 0, "material-osc-controller")
    end
    local volume = state.volume.popup_bounds
    if volume then
      mp.set_mouse_area(volume.x1, volume.y1, volume.x2, volume.y2,
        "material-osc-volume-popup")
    else
      mp.set_mouse_area(0, 0, 0, 0, "material-osc-volume-popup")
    end
  end

  function service:update_rate()
    local fps = mp.get_property_number("display-fps") or
      mp.get_property_number("estimated-display-fps") or 60
    local interval = 1 / fps
    if math.abs(interval - state.timers.frame_interval) < 0.0001 then return end
    state.timers.frame_interval = interval
    if state.timers.frame then
      state.timers.frame:kill()
      state.timers.frame = mp.add_periodic_timer(interval, args.render)
    end
  end

  function service:dispose()
    if state.timers.frame then state.timers.frame:kill() end
    state.timers.frame = nil
    if state.timers.hide then state.timers.hide:kill() end
    state.timers.hide = nil
  end

  function service:on_file_loaded()
    state.media.loading = false
    args.directory_playlist:load()
    args.navigation:reset()
    args.playback_indicator:reset()
    state.pointer.pending_click = nil
    if state.pointer.click_timer then
      state.pointer.click_timer:kill(); state.pointer.click_timer = nil
    end
    args.thumbnail:on_file_loaded()
    args.stream_quality:load()
    args.stream_quality:restore_subtitles()
    args.render()
  end

  function service:start()
    local function controller() return args.controller() end
    mp.observe_property("osd-dimensions", "native",
      function(...) controller():on_dimensions(...) end)
    mp.observe_property("display-hidpi-scale", "number",
      function(...) controller():on_hidpi_scale(...) end)
    for _, property in ipairs({
      {"pause", "bool"}, {"mute", "bool"}, {"volume", "number"},
      {"duration", "number"}, {"time-pos", "number"}, {"chapter", "number"},
      {"chapter-list", "native"}, {"track-list", "native"}, {"sid", "number"},
      {"aid", "number"}, {"speed", "number"}, {"sub-visibility", "bool"},
      {"fullscreen", "bool"}, {"seeking", "bool"},
      {"paused-for-cache", "bool"}, {"cache-buffering-state", "number"},
      {"demuxer-cache-state", "native"}, {"vid", "number"},
      {"video-out-params", "native"}, {"demuxer-via-network", "bool"},
      {"playlist", "native"}, {"playlist-pos", "number"},
      {"loop-playlist", "string"}, {"loop-file", "string"},
      {"shuffle", "bool"}, {"media-title", "string"}
    }) do mp.observe_property(property[1], property[2], args.render) end
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
      {"wheel_up", function() controller():on_wheel(-1) end},
      {"wheel_down", function() controller():on_wheel(1) end}
    }, "material-osc-input", "force")
    mp.enable_key_bindings("material-osc-input", "allow-hide-cursor")
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
      self:dispose(); args.thumbnail:dispose()
    end)
    mp.register_event("file-loaded", function() self:on_file_loaded() end)

    self:update_rate()
    if not state.timers.frame then
      state.timers.frame = mp.add_periodic_timer(state.timers.frame_interval, args.render)
    end
    args.render()
  end

  return service
end

return mpv_runtime
