local pointer = {}

function pointer.new(runtime)
  local service = {}

  function service:contains(box)
    return runtime.pointer.x >= box.x1 and runtime.pointer.x <= box.x2 and
      runtime.pointer.y >= box.y1 and runtime.pointer.y <= box.y2
  end

  function service:hitbox_at_cursor()
    for index = #runtime.input.order, 1, -1 do
      local name = runtime.input.order[index]
      local box = runtime.input.hitboxes[name]
      if box.enabled ~= false and self:contains(box) then return name, box end
    end
    return nil, nil
  end

  return service
end

local effects = {}

function effects.new(args)
  local runtime, msg = args.runtime, args.msg
  local service = {}

  function service:enqueue(key, effect)
    if key then
      if not runtime.effects.by_key[key] then
        runtime.effects.order[#runtime.effects.order + 1] = key
      end
      runtime.effects.by_key[key] = effect
      return
    end
    local anonymous_key = #runtime.effects.order + 1
    runtime.effects.order[#runtime.effects.order + 1] = anonymous_key
    runtime.effects.by_key[anonymous_key] = effect
  end

  function service:reset()
    runtime.effects = {order = {}, by_key = {}}
  end

  function service:flush()
    local order, queued = runtime.effects.order, runtime.effects.by_key
    self:reset()
    for _, key in ipairs(order) do
      local effect = queued[key]
      if effect then
        local ok, err = pcall(effect)
        if not ok then msg.error("material-osc effect failed: " .. tostring(err)) end
      end
    end
  end

  return service
end

local render_orchestrator = {}

function render_orchestrator.new(args)
  local runtime = args.runtime
  local service = {}
  local request_priority = {
    dynamic = 1, interaction = 2, visual = 3, full = 4
  }

  local function queue_request(kind)
    kind = kind or "full"
    local current = runtime.frame.request_mode
    if not current or request_priority[kind] > request_priority[current] then
      runtime.frame.request_mode = kind
    end
  end

  function service:render_frame(mode)
    local full = mode == "full"
    local interactive = mode == "interaction" or mode == "visual"
    if args.on_frame then args.on_frame(mode) end
    local started = args.on_profile_phase and os.clock() or nil
    local now = args.now()
    runtime.snapshot = args.read_snapshot()
    args.on_snapshot(runtime.snapshot, now, full)
    args.update_animations(now)
    if started then
      args.on_profile_phase(
        mode .. "_state", os.clock() - started)
      started = os.clock()
    end

    if full then
      runtime.input.hitboxes, runtime.input.order = {}, {}
    end
    if full or interactive then
      args.tooltip:begin_frame()
    end
    args.effects:reset()

    if full or not args.app().update_dynamic then
      args.app():update(runtime.snapshot)
    elseif interactive and args.app().update_interaction then
      args.app():update_interaction(runtime.snapshot)
    else
      args.app():update_dynamic(runtime.snapshot)
    end
    if started then
      args.on_profile_phase(
        mode .. "_update", os.clock() - started)
      started = os.clock()
    end
    if args.draw_layers then
      args.draw_layers(mode)
    else
      local ass = args.begin_frame(runtime.viewport)
      args.app():draw(ass, args.root_bounds(runtime.viewport))
      args.present(ass)
    end
    if started then
      args.on_profile_phase(
        mode .. "_draw", os.clock() - started)
      started = os.clock()
    end

    if full or interactive then
      local modal_visible = runtime.context_menu.open or
        runtime.context_menu.pending_x ~= nil or
        runtime.context_menu.animation:is_running() or
        runtime.context_menu.animation.value > 0.001 or
        runtime.context_menu.width_animation:is_running() or
        runtime.context_menu.height_animation:is_running()
      for _, name in ipairs(args.navigation.dialogs) do
        local state = runtime[name]
        modal_visible = modal_visible or state.open or state.animation:is_running()
      end
      args.tooltip:finalize(
        now, runtime.controller.opacity.value <= 0 or modal_visible)
    end

    if full then
      for _, name in ipairs(args.navigation.dialogs) do
        local state = runtime[name]
        if not state.open and state.animation.value == 0 then
          state.bounds = nil
          if name == "chapter" then state.dragging_scroll = false end
          if not state.hidden_notified then
            args.disable_dialog(args.navigation:binding(name))
            state.hidden_notified = true
          end
        else
          state.hidden_notified = false
        end
      end
    elseif interactive then
      local needs_cleanup = not runtime.context_menu.open and
        runtime.context_menu.pending_x == nil and
        not runtime.context_menu.animation:is_running() and
        runtime.context_menu.bounds ~= nil
      for _, name in ipairs(args.navigation.dialogs) do
        local state = runtime[name]
        needs_cleanup = needs_cleanup or
          (not state.open and not state.animation:is_running() and
            state.animation.value == 0 and state.bounds ~= nil)
      end
      if needs_cleanup then queue_request("full") end
    end

    args.update_mouse_area()
    args.effects:flush()
    if started then
      args.on_profile_phase(
        mode .. "_finish", os.clock() - started)
    end
  end

  function service:render(kind)
    queue_request(kind)
    if runtime.frame.rendering then
      runtime.frame.pending = true
      return
    end
    runtime.frame.rendering = true
    local passes = 0
    repeat
      runtime.frame.pending = false
      local mode = runtime.frame.request_mode or "full"
      runtime.frame.request_mode = nil
      self:render_frame(mode)
      passes = passes + 1
    until (not runtime.frame.pending and not runtime.frame.request_mode) or
      passes >= 2
    runtime.frame.rendering = false
    runtime.frame.last_render = args.now()
    if runtime.frame.request_mode then
      self:request_render(runtime.frame.request_mode)
    end
  end

  function service:request_render(kind)
    queue_request(kind)
    if runtime.frame.rendering then
      runtime.frame.pending = true
      return
    end
    if runtime.timers.render then return end

    local elapsed = args.now() - runtime.frame.last_render
    local delay = runtime.timers.frame_interval - elapsed
    if delay <= 0.0005 then
      self:render(kind)
      return
    end

    runtime.timers.render = args.schedule(delay, function()
      runtime.timers.render = nil
      self:render(runtime.frame.request_mode or kind)
      if args.on_rendered then args.on_rendered() end
    end)
  end

  return service
end

return {pointer = pointer, effects = effects, renderer = render_orchestrator}
