local edge_seek = {}

function edge_seek.new(services)
  local state, ui = services.state, services.ui
  local opts = services.config.opts
  local render = services.effects.render
  local step = math.max(1, tonumber(opts.seek_step_seconds) or 5)
  local step_label = string.format("%g", step)
  local service = {}

  local function modal_open()
    return state.update.open or state.context_menu.open or
      state.context_menu.pending_x ~= nil or state.playlist.open or
      state.chapter.open or state.subtitle.open or state.audio.open or
      state.settings.open
  end

  local function register_hitbox(side, bounds, amount)
    local name = "edge-seek-" .. side
    bounds.name = name
    bounds.enabled = not modal_open()
    bounds.on_click = function()
      mp.commandv("seek", tostring(amount), "relative")
      local visual = state.edge_seek[side]
      if visual.feedback_timer then visual.feedback_timer:kill() end
      visual.feedback:snap(0)
      visual.feedback:set_target(1)
      visual.feedback_timer = mp.add_timeout(0.10, function()
        visual.feedback_timer = nil
        visual.feedback:set_target(0)
        render()
      end)
    end
    state.input.hitboxes[name] = bounds
    state.input.order[#state.input.order + 1] = name
  end

  local function draw_side(ass, root, side, direction)
    local visual = state.edge_seek[side]
    local opacity = visual.opacity.value
    if opacity <= 0.001 and not visual.opacity:is_running() and
      not visual.slide:is_running() then return end

    local dp = ui.dp
    local cx = root.x + root.w * (direction < 0 and 0.16 or 0.84)
    local cy = root.y + root.h * 0.46
    local slide = visual.slide.value
    cx = cx + direction * dp(28) * (1 - slide)

    local icon = direction < 0 and "fast_rewind" or "fast_forward"
    local label = (direction < 0 and "-" or "+") .. step_label .. "s"
    local alpha = ui.alpha(opacity)
    local feedback = visual.feedback.value
    local icon_x = cx + direction * dp(14) * feedback
    local icon_size = 64 * (1 + 0.12 * feedback)
    ui.draw_icon(ass, icon_x, cy, icon, "#FFFFFF", icon_size, alpha, true)

    local pill_h = dp(40)
    local pill_w = ui.text_width(label, 22) + dp(32)
    local pill_y = cy + dp(48)
    ui.draw_box(ass, cx - pill_w / 2, pill_y,
      cx + pill_w / 2, pill_y + pill_h, pill_h / 2,
      "#050708", ui.alpha(opacity * 0.82), true)
    ui.draw_text(ass, cx, pill_y + pill_h / 2, label, 22,
      "#FFFFFF", alpha, ui.default_text_font, nil, nil, true)
  end

  function service:draw(ass, root)
    local zone_w = root.w * 0.25
    local zone_h = state.controller.bounds and
      math.max(0, state.controller.bounds.y1 - root.y) or root.h
    local left = ui.Rect({x = root.x, y = root.y, w = zone_w, h = zone_h})
    local right = ui.Rect({
      x = root.x2 - zone_w, y = root.y, w = zone_w, h = zone_h
    })
    state.edge_seek.left.bounds, state.edge_seek.right.bounds = left, right
    register_hitbox("left", left, -step)
    register_hitbox("right", right, step)
    if modal_open() then return end
    draw_side(ass, root, "left", -1)
    draw_side(ass, root, "right", 1)
  end

  return service
end

return edge_seek
