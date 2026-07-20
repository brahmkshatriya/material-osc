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

  function service:render_frame()
    local now = args.now()
    runtime.snapshot = args.read_snapshot()
    args.on_snapshot(runtime.snapshot, now)
    args.update_animations(now)

    runtime.input.hitboxes, runtime.input.order = {}, {}
    args.effects:reset()
    args.tooltip:begin_frame()

    local ass = args.begin_frame(runtime.viewport)
    args.app():update(runtime.snapshot)
    args.app():draw(ass, args.root_bounds(runtime.viewport))

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
    args.tooltip:finalize(now, runtime.controller.opacity.value <= 0 or modal_visible)

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

    args.present(ass)
    args.update_mouse_area()
    args.effects:flush()
  end

  function service:render()
    if runtime.frame.rendering then
      runtime.frame.pending = true
      return
    end
    runtime.frame.rendering = true
    local passes = 0
    repeat
      runtime.frame.pending = false
      self:render_frame()
      passes = passes + 1
    until not runtime.frame.pending or passes >= 2
    runtime.frame.rendering = false
  end

  return service
end

return {pointer = pointer, effects = effects, renderer = render_orchestrator}
