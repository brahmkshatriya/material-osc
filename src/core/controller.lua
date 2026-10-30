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
    if visible then runtime.controller.pointer_timed_out = false end
    local target = visible and 1 or 0
    if runtime.controller.visible == visible and
      runtime.controller.opacity.target == target then
      return false
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
    runtime.controller.opacity:set_target(target, mp.get_time(), 0.18)
    if not visible then args.thumbnail:clear() end
    if args.render_visibility then args.render_visibility()
    else args.render() end
    return true
  end

  function service:cancel_hide_timer()
    runtime.controller.hide_deadline = nil
    if not runtime.timers.hide then return end
    runtime.timers.hide:kill()
    runtime.timers.hide = nil
  end

  function service:arm_hide_timer()
    local timeout = math.max(0, tonumber(opts.mouse_timeout) or 0)
    if timeout <= 0 then
      self:cancel_hide_timer()
      return
    end
    runtime.controller.hide_deadline = mp.get_time() + timeout
    if runtime.timers.hide then return end

    local function check_deadline()
      runtime.timers.hide = nil
      local deadline = runtime.controller.hide_deadline
      if not deadline then return end
      local remaining = deadline - mp.get_time()
      if remaining > 0.001 then
        runtime.timers.hide = mp.add_timeout(remaining, check_deadline)
        return
      end
      runtime.controller.hide_deadline = nil
      self:update_mouse()
      if self:interaction_requires_visibility() then
        self:arm_hide_timer()
        return
      end
      runtime.controller.pointer_timed_out = true
      -- Pointer-only feedback (such as edge seek) can be visible while the
      -- controller is already hidden. In that case animate_visibility(false)
      -- has no visibility transition from which to schedule cursor hiding, so
      -- make the idle deadline authoritative for every part of the viewport.
      runtime.controller.hide_cursor_after_fade = true
      if not self:animate_visibility(false) then
        -- Edge feedback can be visible while the controller itself is
        -- already hidden, so it still needs a frame to receive its new
        -- timeout target.
        args.render()
      end
    end

    runtime.timers.hide = mp.add_timeout(timeout, check_deadline)
  end

  function service:show()
    if runtime.controller.input_suppressed then
      return self:animate_visibility(false)
    end
    local visibility_changed = self:animate_visibility(true)
    self:arm_hide_timer()
    return visibility_changed
  end

  function service:interaction_requires_visibility()
    if runtime.update.open then return true end
    if runtime.seek.dragging or runtime.volume.dragging or
      runtime.pointer.window_dragging then
      return true
    end
    local hovered = args.hitbox_at_cursor and args.hitbox_at_cursor() or nil
    if hovered == "seekbar" or
      (type(hovered) == "string" and
        hovered:match("^youtube%-")) then
      return true
    end
    for _, name in ipairs(args.navigation.dialogs) do
      if runtime[name].open then return true end
    end
    return false
  end

  function service:window_controls_hovered()
    return (runtime.window_controls.reveal_bounds and
      args.mouse_in(runtime.window_controls.reveal_bounds)) or false
  end

  function service:update_window_controls_hover()
    local hovered = self:window_controls_hovered()
    local changed = runtime.window_controls.hovered ~= hovered
    runtime.window_controls.hovered = hovered
    if changed and args.window_controls_hover_changed then
      args.window_controls_hover_changed(hovered)
    end
    return changed
  end

  function service:should_show_at_pointer()
    if self:interaction_requires_visibility() then return true end
    return (runtime.controller.bounds and args.mouse_in(runtime.controller.bounds)) or
      (runtime.volume.popup_bounds and args.mouse_in(runtime.volume.popup_bounds)) or false
  end

  function service:sync_visibility_with_pointer()
    local pointer_active = runtime.pointer.x >= 0 and runtime.pointer.y >= 0
    if pointer_active and not opts.show_on_mouse_move and
      self:window_controls_hovered() and
      not self:interaction_requires_visibility() then
      self:cancel_hide_timer()
      local changed = self:animate_visibility(false)
      runtime.controller.hide_cursor_after_fade = false
      args.set_cursor_autohide("no")
      return changed
    end
    local show_from_pointer =
      pointer_active and (runtime.pip.active or opts.show_on_mouse_move)
    if show_from_pointer or self:should_show_at_pointer() then
      return self:show()
    end
    local changed = self:animate_visibility(false)
    if pointer_active then self:arm_hide_timer()
    else self:cancel_hide_timer() end
    return changed
  end

  function service:pointer_visual_feedback_changed()
    local name, box = args.hitbox_at_cursor()
    local hover_changed = runtime.pointer.hover_hitbox ~= name
    runtime.pointer.hover_hitbox = name
    if hover_changed and args.tooltip_hover_changed then
      args.tooltip_hover_changed(name)
    end

    local seek_x = nil
    if name == "seekbar" and box then
      seek_x = math.floor(math.max(box.x1,
        math.min(box.x2, runtime.pointer.x)) + 0.5)
    end
    local seek_changed = runtime.pointer.seek_hover_x ~= seek_x
    runtime.pointer.seek_hover_x = seek_x
    local preview_bounds = runtime.seek.preview_bounds
    local position_pill_visible = preview_bounds ~= nil and
      (runtime.seek.dragging or
        (runtime.controller.visible and args.mouse_in(preview_bounds)))
    local position_pill_changed =
      runtime.seek.position_pill_visible ~= position_pill_visible
    runtime.seek.position_pill_visible = position_pill_visible

    local context_changed = false
    if runtime.context_menu.open then
      if runtime.pointer.context_hover_hitbox ~= name then
        runtime.pointer.context_hover_hitbox = name
        context_changed = true
      end
    else
      runtime.pointer.context_hover_hitbox = nil
    end

    local window_controls_changed = self:update_window_controls_hover()

    local edge_changed = args.pointer_feedback_changed and
      args.pointer_feedback_changed()
    if window_controls_changed then return "interaction" end
    if hover_changed or context_changed or edge_changed or
      position_pill_changed then
      return "interaction"
    end
    if seek_changed then return "dynamic" end
    return nil
  end

  function service:dispatch_mouse_move()
    runtime.timers.pointer_move = nil
    runtime.pointer.last_move_dispatch = mp.get_time()
    runtime.controller.pointer_timed_out = false
    local timeout = math.max(0, tonumber(opts.mouse_timeout) or 0)
    if timeout <= 0 or self:window_controls_hovered() then
      args.set_cursor_autohide("no")
    else
      local cursor_timeout = math.max(100,
        math.floor(timeout * 1000 + 0.5))
      args.set_cursor_autohide(cursor_timeout)
    end
    local active = runtime.pointer.active
    if active and active.on_move then active.on_move(active) end
    if args.update_dragging then args.update_dragging() end
    -- Update top-hover ownership before hiding or showing the bottom
    -- controller. Any visibility render triggered below then sees the correct
    -- independent window-control state.
    local feedback_mode = self:pointer_visual_feedback_changed()
    local rendered = self:sync_visibility_with_pointer()
    if feedback_mode == "layout" and not rendered and args.render_layout then
      args.render_layout()
    elseif feedback_mode and not rendered then
      if feedback_mode == "dynamic" and args.render_dynamic then
        args.render_dynamic()
      else
        args.render()
      end
    end
  end

  function service:on_mouse_move()
    runtime.input.keyboard_focus, runtime.input.keyboard_scope = nil, nil
    self:update_mouse()
    local interval = args.pointer_interval and args.pointer_interval() or
      runtime.timers.frame_interval or (1 / 60)
    local elapsed = mp.get_time() - runtime.pointer.last_move_dispatch
    if elapsed >= math.max(0, interval - 0.0005) then
      if runtime.timers.pointer_move then
        runtime.timers.pointer_move:kill()
        runtime.timers.pointer_move = nil
      end
      self:dispatch_mouse_move()
    elseif not runtime.timers.pointer_move then
      runtime.timers.pointer_move = mp.add_timeout(
        math.max(0.0005, interval - elapsed), function()
          self:dispatch_mouse_move()
        end)
    end
  end

  function service:on_mouse_leave()
    if runtime.timers.pointer_move then
      runtime.timers.pointer_move:kill()
      runtime.timers.pointer_move = nil
    end
    runtime.pointer.x, runtime.pointer.y = -1, -1
    runtime.controller.pointer_timed_out = true
    runtime.pointer.last_move_dispatch = mp.get_time()
    args.thumbnail:clear()
    local feedback_mode = self:pointer_visual_feedback_changed()
    local rendered = self:sync_visibility_with_pointer()
    if feedback_mode == "layout" and not rendered and args.render_layout then
      args.render_layout()
    elseif feedback_mode and not rendered then
      if feedback_mode == "dynamic" and args.render_dynamic then
        args.render_dynamic()
      else
        args.render()
      end
    end
  end

  function service:on_primary_down()
    runtime.controller.pointer_timed_out = false
    self:update_mouse()
    self:update_window_controls_hover()
    local _, box = args.hitbox_at_cursor()
    runtime.pointer.pressed_button = nil
    if box and box.on_press then
      if box.on_move or box.on_release then runtime.pointer.active = box end
      box.on_press(box)
    elseif box and box.on_click then
      if box.name == "video-surface" then runtime.pointer.pending_click = box
      else
        -- buttons fire on release, so a press that turns into a window drag
        -- never triggers them
        runtime.pointer.pressed_button = box
      end
    end
    self:sync_visibility_with_pointer()
  end

  function service:on_primary_double()
    runtime.controller.pointer_timed_out = false
    self:update_mouse()
    self:update_window_controls_hover()
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
    local pressed = runtime.pointer.pressed_button
    runtime.pointer.pressed_button = nil
    if pressed then
      self:update_mouse()
      if args.mouse_in(pressed) and pressed.enabled ~= false then
        pressed.on_click()
      end
    end
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
    if event and event.canceled then
      runtime.pointer.active = nil
      runtime.pointer.pending_click = nil
      runtime.pointer.pressed_button = nil
      runtime.pointer.window_dragging = nil
      if runtime.pointer.click_timer then
        runtime.pointer.click_timer:kill()
        runtime.pointer.click_timer = nil
      end
      runtime.seek.dragging, runtime.chapter.dragging_scroll = false, false
      runtime.volume.dragging = false
      runtime.playlist.drag_from, runtime.playlist.drag_to = nil, nil
      runtime.playlist.drag_start_y = nil
      runtime.playlist.dragging_scroll = false
      runtime.seek.position, runtime.seek.offset_x = nil, 0
      return
    end
    if event and event.event == "down" then
      runtime.controller.pointer_timed_out = false
      self:update_mouse()
      self:update_window_controls_hover()
      local name = args.hitbox_at_cursor()
      if name == "window-drag-area" then
        runtime.pointer.window_dragging = true
        mp.commandv("begin-vo-dragging")
        return
      end
    elseif event and event.event == "up" and runtime.pointer.window_dragging then
      runtime.pointer.window_dragging = nil
      return
    end
    if not event or event.event == "press" then
      -- a press without separate down/up events is a complete click
      self:on_primary_down()
      self:on_primary_up()
    elseif event.event == "down" then
      self:on_primary_down()
    elseif event.event == "up" then
      self:on_primary_up()
    end
  end

  function service:on_secondary_down()
    runtime.controller.pointer_timed_out = false
    self:update_mouse()
    if runtime.update.open then return end
    runtime.pointer.hover_hitbox = nil
    runtime.pointer.context_hover_hitbox = nil
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
    runtime.controller.pointer_timed_out = false
    self:update_mouse()
    self:arm_hide_timer()
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
    local below_top_inset = runtime.pointer.y >= args.edge_seek_top_inset()
    if below_top_inset and (horizontal_position < seeking_zone or
      horizontal_position > 1 - seeking_zone) then
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
      local ui_scale = args.window_scale and args.window_scale() or 1
      if ui_scale ~= runtime.viewport.ui_scale then
        runtime.viewport.ui_scale = ui_scale
        args.recreate_app()
      end
    end
    if args.render_layout then args.render_layout()
    else args.render() end
  end

  function service:on_hidpi_scale(_, value)
    local dpi = tonumber(value) or 1
    if math.abs(dpi - runtime.viewport.dpi) > 0.0001 then
      runtime.viewport.dpi = dpi
      if args.window_scale then runtime.viewport.ui_scale = args.window_scale() end
      args.recreate_app()
    end
    if args.render_layout then args.render_layout()
    else args.render() end
  end

  return service
end

return controller
