local playback_indicator = {}

function playback_indicator.new(args)
  local state, mp, ui = args.state, args.mp, args.ui
  local service = {}

  function service:show(icon, label, now, label_color)
    state.icon, state.label = icon, label
    state.label_color = label_color or "#FFFFFF"
    state.pill_only = false
    state.opacity:snap(0); state.scale:snap(0.8)
    state.scale:set_target(1); state.opacity:set_target(1, now, 0.09)
    if state.hide_timer then state.hide_timer:kill() end
    state.hide_timer = mp.add_timeout(0.28, function()
      state.hide_timer = nil
      state.opacity:set_target(0, mp.get_time(), 0.20)
      args.render()
    end)
  end

  function service:show_pill(icon, label, now)
    state.icon, state.label = icon, label
    state.label_color = "#FFFFFF"
    state.pill_only = true
    state.opacity:snap(0); state.scale:snap(0.92)
    state.scale:set_target(1); state.opacity:set_target(1, now, 0.09)
    if state.hide_timer then state.hide_timer:kill() end
    state.hide_timer = mp.add_timeout(1.4, function()
      state.hide_timer = nil
      state.opacity:set_target(0, mp.get_time(), 0.20)
      args.render()
    end)
  end

  function service:observe(snapshot, now)
    if state.last_paused == nil then
      state.last_paused = snapshot.paused
    elseif state.last_paused ~= snapshot.paused then
      state.last_paused = snapshot.paused
      self:show(snapshot.paused and "pause" or "play_arrow", nil, now)
    end
    local volume_changed = state.last_volume ~= nil and
      math.abs(state.last_volume - snapshot.volume) >= 0.01
    local mute_changed = state.last_muted ~= nil and state.last_muted ~= snapshot.muted
    if state.last_volume == nil then state.last_volume = snapshot.volume end
    if state.last_muted == nil then state.last_muted = snapshot.muted end
    if volume_changed or mute_changed then
      state.last_volume, state.last_muted = snapshot.volume, snapshot.muted
      local volume = math.floor(snapshot.volume + 0.5)
      local muted = snapshot.muted or volume <= 0
      self:show(muted and "volume_off" or
        (volume < 50 and "volume_down" or "volume_up"),
        muted and "Muted" or tostring(volume) .. "%", now,
        volume > 100 and "#FF9800" or "#FFFFFF")
    end

    local subtitle_id = snapshot.subtitle_id or 0
    local subtitle_visible = snapshot.sub_visibility ~= false
    if state.last_subtitle_id == nil then
      state.last_subtitle_id = subtitle_id
      state.last_sub_visibility = subtitle_visible
    elseif state.last_subtitle_id ~= subtitle_id or
      state.last_sub_visibility ~= subtitle_visible then
      state.last_subtitle_id = subtitle_id
      state.last_sub_visibility = subtitle_visible
      local label = "Subtitles off"
      if subtitle_id ~= 0 and subtitle_visible then
        for _, item in ipairs(snapshot.subtitle_items or {}) do
          if item.id == subtitle_id then
            label = item.label or ("Subtitle " .. tostring(subtitle_id))
            break
          end
        end
      end
      self:show_pill("subtitles", label, now)
    end

    local loop_a, loop_b = snapshot.ab_loop_a, snapshot.ab_loop_b
    if not state.ab_loop_initialized then
      state.ab_loop_initialized = true
      state.last_ab_loop_a, state.last_ab_loop_b = loop_a, loop_b
    elseif state.last_ab_loop_a ~= loop_a or state.last_ab_loop_b ~= loop_b then
      state.last_ab_loop_a, state.last_ab_loop_b = loop_a, loop_b
      local label
      if loop_a == nil then
        label = "A–B loop cleared"
      elseif loop_b == nil then
        label = "Loop start · " .. ui.format_time(loop_a)
      else
        label = "Loop end · " .. ui.format_time(loop_b)
      end
      self:show_pill("repeat", label, now)
    end
  end

  function service:draw(ass, bounds)
    local opacity = state.opacity.value
    if opacity <= 0.001 then return end
    local scale, dp = state.scale.value, ui.dp
    if state.pill_only then
      local icon_size = dp(26) * scale
      local gap = dp(10) * scale
      local horizontal_padding = dp(20) * scale
      local pill_h = dp(54) * scale
      local text_w = ui.text_width(state.label or "", 26) * scale
      local pill_w = horizontal_padding * 2 + icon_size + gap + text_w
      local cx = bounds.x + bounds.w / 2
      local cy = bounds.y + bounds.h * 0.78
      local x1, x2 = cx - pill_w / 2, cx + pill_w / 2
      local y1, y2 = cy - pill_h / 2, cy + pill_h / 2
      ui.draw_box(ass, x1, y1, x2, y2, pill_h / 2,
        "#050708", ui.alpha(opacity * 0.84), true)
      local icon_x = x1 + horizontal_padding + icon_size / 2
      ui.draw_icon(ass, icon_x, cy, state.icon, "#FFFFFF", 26 * scale,
        ui.alpha(opacity), true)
      ui.draw_text(ass, icon_x + icon_size / 2 + gap, cy,
        state.label, 26 * scale, state.label_color, ui.alpha(opacity),
        ui.default_text_font, 4, nil, true)
      return
    end
    local size = dp(160) * scale
    local cx, cy = bounds.x + bounds.w / 2, bounds.y + bounds.h / 2
    ui.draw_box(ass, cx - size / 2, cy - size / 2,
      cx + size / 2, cy + size / 2, size / 2,
      "#050708", ui.alpha(opacity * 0.72), true)
    ui.draw_icon(ass, cx, cy, state.icon, "#FFFFFF", 96 * scale,
      ui.alpha(opacity), true)
    if state.label then
      local pill_h = dp(54) * scale
      local pill_w = (ui.text_width(state.label, 28) + dp(44)) * scale
      local pill_y = cy + size / 2 + dp(12) * scale
      ui.draw_box(ass, cx - pill_w / 2, pill_y,
        cx + pill_w / 2, pill_y + pill_h, pill_h / 2,
        "#050708", ui.alpha(opacity * 0.72), true)
      ui.draw_text(ass, cx, pill_y + pill_h / 2, state.label, 28 * scale,
        state.label_color, ui.alpha(opacity), ui.default_text_font,
        nil, nil, true)
    end
  end

  function service:reset()
    if state.hide_timer then state.hide_timer:kill(); state.hide_timer = nil end
    state.last_paused, state.last_volume, state.last_muted = nil, nil, nil
    state.last_subtitle_id, state.last_sub_visibility = nil, nil
    state.ab_loop_initialized = false
    state.last_ab_loop_a, state.last_ab_loop_b = nil, nil
    state.label = nil
    state.pill_only = false
    state.opacity:snap(0); state.scale:snap(1)
  end

  return service
end

return playback_indicator
