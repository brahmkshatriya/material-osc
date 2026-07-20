local navigation = {}

local DIALOGS = {"playlist", "chapter", "subtitle", "audio", "settings"}

function navigation.new(args)
  local runtime, mp = args.runtime, args.mp
  local service = {dialogs = DIALOGS}

  function service:binding(name)
    return "material-osc-" .. name .. "-dialog"
  end

  function service:render()
    if args.render then args.render() end
  end

  function service:close_others(active_name)
    for _, name in ipairs(DIALOGS) do
      if name ~= active_name then runtime[name].open = false end
    end
  end

  function service:cancel_pointer_gestures()
    runtime.pointer.active = nil
    runtime.seek.dragging = false
    runtime.volume.dragging = false
    runtime.playlist.drag_from, runtime.playlist.drag_to = nil, nil
    runtime.playlist.drag_start_y = nil
    runtime.playlist.dragging_scroll = false
  end

  function service:scroll_to_active(state, items, active_id)
    state.scroll_index = 0
    for index, item in ipairs(items or {}) do
      if item.id == active_id then
        state.scroll_index = math.max(0, index - 3)
        return
      end
    end
  end

  function service:open(name)
    self:close_others(name)
    self:cancel_pointer_gestures()
    mp.enable_key_bindings(self:binding(name))
  end

  function service:set_dialog_open(name, open)
    local state = runtime[name]
    state.open = open == true
    if name == "chapter" then state.dragging_scroll = false end
    if name == "playlist" then
      state.drag_from, state.drag_to, state.drag_start_y = nil, nil, nil
      state.dragging_scroll = false
    end
    if state.open then
      self:open(name)
      if name == "subtitle" then
        self:scroll_to_active(state, runtime.snapshot.subtitle_items, runtime.snapshot.subtitle_id)
      elseif name == "audio" then
        self:scroll_to_active(state, runtime.snapshot.audio_items, runtime.snapshot.audio_id)
      elseif name == "playlist" then
        state.scroll_index = math.max(0, (runtime.snapshot.playlist_pos or 0) - 2)
      elseif name == "settings" then
        state.page, state.pending_page, state.transition_phase = "root", nil, nil
        state.resize_started = false
        state.content_animation:snap(1)
      end
    end
    self:render()
  end

  function service:set_settings_page(page)
    local state = runtime.settings
    page = page or "root"
    if page == state.page and not state.transition_phase then return end
    state.pending_page, state.transition_phase = page, "fade_out"
    state.resize_started, state.scroll_index = false, 0
    state.content_animation:set_target(0, mp.get_time(), 0.09)
    local items, active_id
    if page == "video" then
      items, active_id = runtime.snapshot.video_items, runtime.snapshot.video_id
    elseif page == "audio" then
      items, active_id = runtime.snapshot.audio_items, runtime.snapshot.audio_id
    elseif page == "subtitles" then
      items, active_id = runtime.snapshot.subtitle_items, runtime.snapshot.subtitle_id
    elseif page == "secondary_subtitles" then
      items = runtime.snapshot.subtitle_items
      active_id = runtime.snapshot.secondary_subtitle_id
    elseif page == "auto_captions" then
      items = runtime.ytdl.caption_items
    end
    self:scroll_to_active(state, items, active_id)
    self:render()
  end

  function service:select_subtitle(item)
    if not item or item.id == 0 then
      mp.set_property("sid", "no")
      return
    end
    mp.set_property_number("sid", tonumber(item.id))
    mp.set_property_native("sub-visibility", true)
  end

  function service:toggle_subtitles()
    local snapshot = runtime.snapshot or {}
    if (snapshot.subtitle_id or 0) ~= 0 then
      mp.set_property_native("sub-visibility", not snapshot.sub_visibility)
    else
      self:select_subtitle(snapshot.subtitle_items and snapshot.subtitle_items[2])
    end
  end

  function service:cycle_subtitle(direction)
    local snapshot, current = runtime.snapshot or {}, 1
    local items = snapshot.subtitle_items or {}
    if #items <= 1 then return end
    for index, item in ipairs(items) do
      if item.id == snapshot.subtitle_id then current = index break end
    end
    self:select_subtitle(items[((current - 1 + direction) % #items) + 1])
  end

  function service:reset()
    for _, name in ipairs(DIALOGS) do
      local state = runtime[name]
      state.open, state.bounds, state.scroll_index = false, nil, 0
      state.animation:snap(0)
      state.hidden_notified = true
      mp.disable_key_bindings(self:binding(name))
    end
    runtime.chapter.dragging_scroll = false
    runtime.chapter.fade:snap(0)
    runtime.playlist.drag_from, runtime.playlist.drag_to = nil, nil
    runtime.playlist.drag_start_y = nil
    runtime.playlist.dragging_scroll = false
    runtime.playlist.width_animation:snap(args.dp(118))
    runtime.playlist.height_animation:snap(args.dp(42))
    local state = runtime.settings
    state.page, state.pending_page, state.transition_phase = "root", nil, nil
    state.resize_started = false
    state.content_animation:snap(1)
    state.width_animation:snap(args.dp(320))
    state.height_animation:snap(args.dp(292))
  end

  return service
end

return navigation
