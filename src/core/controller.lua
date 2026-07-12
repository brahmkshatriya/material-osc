local controller = {}

function controller.new(args)
  local runtime, mp, opts = args.runtime, args.mp, args.opts
  local service = {}

  function service:update_mouse()
    local x, y = mp.get_mouse_pos()
    runtime.pointer.x, runtime.pointer.y = x or -1, y or -1
  end

  function service:animate_visibility(visible)
    if opts.always_visible then visible = true end
    runtime.controller.visible = visible
    runtime.controller.opacity:set_target(visible and 1 or 0, mp.get_time(), 0.18)
    if not visible then args.thumbnail:clear() end
    args.render()
  end

  function service:show()
    self:animate_visibility(true)
    if runtime.timers.hide then runtime.timers.hide:kill(); runtime.timers.hide = nil end
    if opts.always_visible or opts.timeout <= 0 then return end
    runtime.timers.hide = mp.add_timeout(opts.timeout, function()
      self:update_mouse()
      if runtime.chapter.open or runtime.settings.open or runtime.seek.dragging or
        runtime.volume.dragging or
        (runtime.controller.bounds and args.mouse_in(runtime.controller.bounds)) or
        (runtime.volume.popup_bounds and args.mouse_in(runtime.volume.popup_bounds)) then
        self:show()
      else
        self:animate_visibility(false)
      end
    end)
  end

  function service:on_mouse_move()
    self:update_mouse()
    local active = runtime.pointer.active
    if active and active.on_move then active.on_move(active) end
    self:show()
  end

  function service:on_mouse_leave()
    runtime.pointer.x, runtime.pointer.y = -1, -1
    args.thumbnail:clear()
    args.render()
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
    self:show()
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
    self:show()
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
    runtime.seek.position, runtime.seek.offset_x = nil, 0
    self:show()
  end

  function service:on_primary_button(event)
    if not event or event.event == "down" or event.event == "press" then
      self:on_primary_down()
    elseif event.event == "up" then
      self:on_primary_up()
    end
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

  function service:on_wheel(direction)
    self:update_mouse()
    if self:scroll_open_dialog(direction) then return end
    local _, box = args.hitbox_at_cursor()
    local action = direction < 0 and box and box.on_scroll_up or box and box.on_scroll_down
    if action then action(box) end
    self:show()
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
