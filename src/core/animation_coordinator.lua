local animation_coordinator = {}

function animation_coordinator.new(args)
  local runtime = args.runtime
  local service = {}

  function service:update(now)
    runtime.controller.opacity:update(now)
    local context_visible = runtime.context_menu.open or
      runtime.context_menu.pending_x ~= nil or
      runtime.context_menu.animation:is_running() or
      runtime.context_menu.animation.value > 0.001 or
      runtime.context_menu.width_animation:is_running() or
      runtime.context_menu.height_animation:is_running()
    local modal = runtime.update.open or context_visible or runtime.playlist.open or
      runtime.playlist.animation:is_running() or
      runtime.chapter.open or runtime.chapter.animation.value > 0.001 or
      runtime.settings.open or runtime.settings.animation.value > 0.001
    local wants_volume = not modal and (runtime.volume.dragging or
      (runtime.volume.button_bounds and args.mouse_in(runtime.volume.button_bounds)) or
      (runtime.volume.popup_bounds and args.mouse_in(runtime.volume.popup_bounds)))
    runtime.volume.animation:set_target(wants_volume and 1 or 0)
    runtime.volume.animation:update(now)

    runtime.context_menu.animation:set_target(runtime.context_menu.open and 1 or 0)
    runtime.context_menu.animation:update(now)
    runtime.context_menu.width_animation:update(now)
    runtime.context_menu.height_animation:update(now)

    for _, name in ipairs({"playlist", "chapter", "subtitle", "audio", "settings"}) do
      local state = runtime[name]
      state.animation:set_target(state.open and 1 or 0)
      state.animation:update(now)
    end
    runtime.chapter.fade:set_target(runtime.chapter.open and 1 or 0)
    runtime.chapter.fade:update(now)
    runtime.playlist.width_animation:update(now)
    runtime.playlist.height_animation:update(now)
    runtime.settings.content_animation:update(now)
    runtime.settings.width_animation:update(now)
    runtime.settings.height_animation:update(now)
    runtime.playback_indicator.opacity:update(now)
    runtime.playback_indicator.scale:update(now)

    local pointer = runtime.pointer
    local controller_bounds = runtime.controller.bounds
    local over_controller = controller_bounds and args.mouse_in(controller_bounds)
    local edge_modal = modal or runtime.subtitle.open or runtime.audio.open or
      runtime.subtitle.animation:is_running() or runtime.audio.animation:is_running()
    local edge_allowed = not edge_modal and not over_controller and
      pointer.x >= 0 and pointer.y >= 0
    local edge_width = runtime.viewport.w * 0.25
    local wants_left = edge_allowed and pointer.x <= edge_width
    local wants_right = edge_allowed and pointer.x >= runtime.viewport.w - edge_width
    for _, item in ipairs({
      {state = runtime.edge_seek.left, visible = wants_left},
      {state = runtime.edge_seek.right, visible = wants_right}
    }) do
      item.state.opacity:set_target(item.visible and 1 or 0, now, 0.15)
      item.state.slide:set_target(item.visible and 1 or 0)
      item.state.opacity:update(now)
      item.state.slide:update(now)
      item.state.feedback:update(now)
    end

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
