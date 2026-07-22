local tooltip_service = {}

function tooltip_service.new(args)
  local state = args.runtime.tooltip
  local delay = args.delay or 1
  local fade_duration = args.fade_duration or 0.14

  local service = {delay = delay, slide_distance = args.slide_distance or 18}

  function service:request(text, bounds)
    if not args.enabled() or not text then return end
    state.requested = true
    if state.hover_key ~= text then
      state.hover_key = text
      state.hover_start = mp.get_time()
      state.opacity:snap(0)
      state.slide:snap(0)
    end

    local text_size, pad_x, pad_y = 18, args.dp(12), args.dp(6)
    local width = args.text_width(text, text_size) + pad_x * 2
    local height = args.dp(text_size) + pad_y * 2
    local x = args.clamp(bounds.x + bounds.w / 2 - width / 2,
      args.dp(8), args.runtime.viewport.w - args.dp(8) - width)
    local gap = args.dp(6)
    local space_above = bounds.y - args.dp(8)
    local space_below = args.runtime.viewport.h - bounds.y2 - args.dp(8)
    local above = space_above >= height + gap or space_above >= space_below
    local y = above and (bounds.y - gap - height) or (bounds.y2 + gap)
    state.visual = {
      text = text, text_size = text_size, x1 = x, y1 = y,
      x2 = x + width, y2 = y + height, w = width, h = height,
      slide_direction_y = above and 1 or -1
    }
  end

  function service:begin_frame()
    state.requested = false
  end

  function service:update(now)
    state.opacity:update(now)
    state.slide:update(now)
  end

  function service:needs_frames(now)
    if state.opacity:is_running() or state.slide:is_running() then return true end
    return state.requested and state.hover_key and
      now - state.hover_start < delay
  end

  function service:finalize(now, suppressed)
    local ready = not suppressed and state.requested and state.hover_key and
      now - state.hover_start >= delay
    state.opacity:set_target(ready and 1 or 0, now, fade_duration)
    state.slide:set_target(ready and 1 or 0)
    if not state.requested and state.opacity.value <= 0.001 then
      state.hover_key, state.hover_start, state.visual = nil, 0, nil
    end
  end

  return service
end

return tooltip_service
