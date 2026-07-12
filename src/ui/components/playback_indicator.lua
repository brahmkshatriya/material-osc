local playback_indicator = {}

function playback_indicator.new(args)
  local state, mp, ui = args.state, args.mp, args.ui
  local service = {}

  function service:show(icon, label, now, label_color)
    state.icon, state.label = icon, label
    state.label_color = label_color or "#FFFFFF"
    state.opacity:snap(0); state.scale:snap(0.8)
    state.scale:set_target(1); state.opacity:set_target(1, now, 0.09)
    if state.hide_timer then state.hide_timer:kill() end
    state.hide_timer = mp.add_timeout(0.28, function()
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
  end

  function service:draw(ass, bounds)
    local opacity = state.opacity.value
    if opacity <= 0.001 then return end
    local scale, dp = state.scale.value, ui.dp
    local size = dp(160) * scale
    local cx, cy = bounds.x + bounds.w / 2, bounds.y + bounds.h / 2
    ui.draw_box(ass, cx - size / 2, cy - size / 2,
      cx + size / 2, cy + size / 2, size / 2,
      "#050708", ui.alpha(opacity * 0.72))
    ui.draw_icon(ass, cx, cy, state.icon, "#FFFFFF", 96 * scale, ui.alpha(opacity))
    if state.label then
      local pill_h = dp(54) * scale
      local pill_w = (ui.text_width(state.label, 28) + dp(44)) * scale
      local pill_y = cy + size / 2 + dp(12) * scale
      ui.draw_box(ass, cx - pill_w / 2, pill_y,
        cx + pill_w / 2, pill_y + pill_h, pill_h / 2,
        "#050708", ui.alpha(opacity * 0.72))
      ui.draw_text(ass, cx, pill_y + pill_h / 2, state.label, 28 * scale,
        state.label_color, ui.alpha(opacity), ui.default_text_font)
    end
  end

  function service:reset()
    if state.hide_timer then state.hide_timer:kill(); state.hide_timer = nil end
    state.last_paused, state.last_volume, state.last_muted = nil, nil, nil
    state.label = nil
    state.opacity:snap(0); state.scale:snap(1)
  end

  return service
end

return playback_indicator
