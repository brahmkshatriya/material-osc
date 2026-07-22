local controller = {}

function controller.new(args)
  local runtime, mp, opts = args.runtime, args.mp, args.opts
  local service = {}

  function service:update_mouse()
    local x, y = mp.get_mouse_pos()
    runtime.pointer.x, runtime.pointer.y = x or -1, y or -1
  end

  function service:animate_visibility(visible)
    if runtime.controller.input_suppressed then
      visible = false
    end
    local was_visible = runtime.controller.visible or
      runtime.controller.opacity.value > 0.001 or
      runtime.controller.opacity:is_running()
    runtime.controller.visible = visible
    if visible then
      runtime.controller.hide_cursor_after_fade = false
      args.set_cursor_autohide("no")
    elseif was_visible then
      runtime.controller.hide_cursor_after_fade = true
    end
    runtime.controller.opacity:set_target(visible and 1 or 0, mp.get_time(), 0.18)
    if not visible then args.thumbnail:clear() end
    args.render()
  end

  function service:show()
    if runtime.controller.input_suppressed then
      self:animate_visibility(false)
      return
    end
    self:animate_visibility(true)
    if runtime.timers.hide then runtime.timers.hide:kill(); runtime.timers.hide = nil end
    if opts.mouse_timeout <= 0 then return end
    runtime.timers.hide = mp.add_timeout(opts.mouse_timeout, function()
      self:update_mouse()
      if self:interaction_requires_visibility() then
        self:show()
      else
        self:animate_visibility(false)
      end
    end)
  end

  function service:interaction_requires_visibility()
    if runtime.update.open then return true end
    if runtime.seek.dragging or runtime.volume.dragging then
      return true
    end
    for _, name in ipairs(args.navigation.dialogs) do
      if runtime[name].open then return true end
    end
    return false
  end

  function service:should_show_at_pointer()
    if self:interaction_requires_visibility() then return true end
    return (runtime.controller.bounds and args.mouse_in(runtime.controller.bounds)) or
      (runtime.volume.popup_bounds and args.mouse_in(runtime.volume.popup_bounds)) or false
  end

  function service:sync_visibility_with_pointer()
    local pointer_active = runtime.pointer.x >= 0 and runtime.pointer.y >= 0
    if (opts.show_on_mouse_move and pointer_active) or self:should_show_at_pointer() then
      self:show()
    else
      if runtime.timers.hide then
        runtime.timers.hide:kill()
        runtime.timers.hide = nil
      end
      self:animate_visibility(false)
    end
  end

  function service:on_mouse_move()
    local cursor_timeout = math.max(100,
      math.floor(math.max(0, tonumber(opts.mouse_timeout) or 0) * 1000 + 0.5))
    args.set_cursor_autohide(cursor_timeout)
    self:update_mouse()
    local active = runtime.pointer.active
    if active and active.on_move then active.on_move(active) end
    self:sync_visibility_with_pointer()
  end

  function service:on_mouse_leave()
    runtime.pointer.x, runtime.pointer.y = -1, -1
    args.thumbnail:clear()
    self:sync_visibility_with_pointer()
  end

  function service:on_primary_down()
    self:update_mouse()
    local _, box = args.hitbox_at_cursor()
    if box and box.on_press then
      if box.on_move or box.on_release then runtime.pointer.active = box end
      box.on_press(box)
    elseif box and box.on_click then
      if box.name == "video-surface" then runtime.pointer.pending_click = box
      else box.on_click() end
    end
    self:sync_visibility_with_pointer()
  end

  function service:on_primary_double()
    self:update_mouse()
    local _, box = args.hitbox_at_cursor()
    if box and box.on_double then
      runtime.pointer.pending_click = nil
      if runtime.pointer.click_timer then
        runtime.pointer.click_timer:kill(); runtime.pointer.click_timer = nil
      end
      box.on_double(box)
    end
    self:sync_visibility_with_pointer()
  end

  function service:on_primary_up()
    local active = runtime.pointer.active
    if active and active.on_release then
      self:update_mouse()
      active.on_release(active)
    end
    runtime.pointer.active = nil
    local pending = runtime.pointer.pending_click
    runtime.pointer.pending_click = nil
    if pending and pending.name == "video-surface" then
      self:update_mouse()
      local _, released = args.hitbox_at_cursor()
      if released and released.name == "video-surface" then
        if runtime.pointer.click_timer then runtime.pointer.click_timer:kill() end
        runtime.pointer.click_timer = mp.add_timeout(0.22, function()
          runtime.pointer.click_timer = nil
          pending.on_click()
        end)
      end
    end
    runtime.seek.dragging, runtime.chapter.dragging_scroll = false, false
    runtime.playlist.drag_from, runtime.playlist.drag_to = nil, nil
    runtime.playlist.drag_start_y = nil
    runtime.playlist.dragging_scroll = false
    runtime.seek.position, runtime.seek.offset_x = nil, 0
    self:sync_visibility_with_pointer()
  end

  function service:on_primary_button(event)
    if not event or event.event == "down" or event.event == "press" then
      self:on_primary_down()
    elseif event.event == "up" then
      self:on_primary_up()
    end
  end

  function service:on_secondary_down()
    self:update_mouse()
    if runtime.update.open then return end
    args.open_context_menu(runtime.pointer.x, runtime.pointer.y)
  end

  function service:scroll_open_dialog(direction)
    for _, name in ipairs(args.navigation.dialogs) do
      local state = runtime[name]
      if state.open and state.bounds and args.mouse_in(state.bounds) and
        (name ~= "settings" or state.page == "video" or state.page == "audio" or
          state.page == "subtitles" or state.page == "auto_captions") then
        state.scroll_index = math.max(0, state.scroll_index + direction)
        args.render(); self:show()
        return true
      end
    end
    return false
  end

  function service:flush_wheel()
    local wheel = runtime.wheel
    local kind, amount = wheel.kind, wheel.amount
    if wheel.timer then wheel.timer:kill() end
    wheel.kind, wheel.amount, wheel.timer = nil, 0, nil
    if not kind or amount == 0 then return end
    if kind == "seek" then
      mp.command(string.format("osd-auto seek %g relative", amount))
    else
      mp.commandv("add", "volume", tostring(amount))
    end
  end

  function service:queue_wheel(kind, amount)
    local wheel = runtime.wheel
    if wheel.kind and wheel.kind ~= kind then self:flush_wheel() end
    wheel.kind = kind
    wheel.amount = wheel.amount + amount
    if wheel.timer then return end
    wheel.timer = mp.add_timeout(0.05, function()
      wheel.timer = nil
      self:flush_wheel()
    end)
  end

  function service:on_wheel(direction)
    self:update_mouse()
    if self:scroll_open_dialog(direction) then return end
    local _, box = args.hitbox_at_cursor()
    local action = direction < 0 and box and box.on_scroll_up or box and box.on_scroll_down
    if action then
      action(box)
      self:sync_visibility_with_pointer()
      return
    end

    local context = runtime.context_menu
    local modal = runtime.update.open or context.open or
      context.pending_x ~= nil or context.animation:is_running()
    for _, name in ipairs(args.navigation.dialogs) do
      local state = runtime[name]
      modal = modal or state.open or state.animation:is_running()
    end
    if modal then return end

    local width = math.max(1, runtime.viewport.w)
    local horizontal_position = runtime.pointer.x / width
    local seeking_zone = opts.seeking_zone_percentage / 100
    if horizontal_position < seeking_zone or
      horizontal_position > 1 - seeking_zone then
      local step = math.max(1, tonumber(opts.seek_step_seconds) or 5)
      local amount = direction < 0 and step or -step
      self:queue_wheel("seek", amount)
    else
      self:queue_wheel("volume", direction < 0 and 5 or -5)
    end
  end

  function service:on_dimensions(_, value)
    if value and value.w and value.h and value.w > 0 and value.h > 0 then
      runtime.viewport.w, runtime.viewport.h = value.w, value.h
    end
    args.render()
  end

  function service:on_hidpi_scale(_, value)
    local dpi = tonumber(value) or 1
    if math.abs(dpi - runtime.viewport.dpi) > 0.0001 then
      runtime.viewport.dpi = dpi
      args.recreate_app()
    end
    args.render()
  end

  return service
end

return controller
