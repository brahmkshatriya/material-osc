local animation_coordinator = {}

function animation_coordinator.new(args)
  local runtime = args.runtime
  local service = {}

  function service:update(now)
    runtime.controller.opacity:update(now)
    local modal = runtime.playlist.open or runtime.playlist.animation:is_running() or
      runtime.chapter.open or runtime.chapter.animation.value > 0.001 or
      runtime.settings.open or runtime.settings.animation.value > 0.001
    local wants_volume = not modal and (runtime.volume.dragging or
      (runtime.volume.button_bounds and args.mouse_in(runtime.volume.button_bounds)) or
      (runtime.volume.popup_bounds and args.mouse_in(runtime.volume.popup_bounds)))
    runtime.volume.animation:set_target(wants_volume and 1 or 0)
    runtime.volume.animation:update(now)

    for _, name in ipairs({"playlist", "chapter", "subtitle", "audio", "settings"}) do
      local state = runtime[name]
      state.animation:set_target(state.open and 1 or 0)
      state.animation:update(now)
    end
    runtime.playlist.width_animation:update(now)
    runtime.playlist.height_animation:update(now)
    runtime.settings.content_animation:update(now)
    runtime.settings.width_animation:update(now)
    runtime.settings.height_animation:update(now)
    runtime.playback_indicator.opacity:update(now)
    runtime.playback_indicator.scale:update(now)

    local settings = runtime.settings
    if settings.transition_phase == "fade_out" and
      settings.content_animation.value <= 0.25 then
      settings.page = settings.pending_page or settings.page
      settings.pending_page, settings.transition_phase = nil, "resize"
      settings.resize_started = false
      settings.content_animation:set_target(1, now, 0.12)
    elseif settings.transition_phase == "resize" and settings.resize_started and
      not settings.width_animation:is_running() and
      not settings.height_animation:is_running() and
      not settings.content_animation:is_running() then
      settings.transition_phase = nil
    end
    args.tooltip:update(now)
  end

  return service
end

return animation_coordinator
