local update_dialog = {}

function update_dialog.new(services)
  local state, ui, updater = services.state.update, services.ui, services.updater
  local dp, clamp, alpha = ui.dp, ui.clamp, ui.alpha
  local Modifier, Rect = ui.Modifier, ui.Rect
  local draw_box, draw_text, draw_icon = ui.draw_box, ui.draw_text, ui.draw_icon
  local mouse_in = ui.mouse_in

  local function action(name, label, on_click, filled)
    local node = {
      modifier = Modifier():clickable({name = name, on_click = on_click}):hoverIndication(),
      label = label, filled = filled
    }
    function node:measure() return {w = dp(label == "Cancel" and 92 or 104), h = dp(42)} end
    function node:draw(ass, bounds)
      if self.filled then
        draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2, bounds.h / 2,
          services.config.opts.accent_color, "00", true)
      elseif mouse_in(bounds) then
        draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2, bounds.h / 2,
          "#FFFFFF", "DD", true)
      end
      draw_text(ass, bounds.x + bounds.w / 2, bounds.y + bounds.h / 2,
        self.label, 20, self.filled and "#001F28" or "#FFFFFF", "00",
        ui.default_text_font, 5, false, true)
    end
    return node
  end

  local node = {modifier = Modifier():fillMaxWidth():fillMaxHeight()}
  node.backdrop = Modifier():fillMaxWidth():fillMaxHeight():clickable({
    name = "update-dialog-backdrop", on_click = function() end
  })
  node.toggle = Modifier():clickable({
    name = "update-dialog-preference", on_click = function()
      if state.done then updater:toggle_disable_auto_update()
      else updater:toggle_dont_ask() end
    end
  })
  node.release = Modifier():clickable({
    name = "update-dialog-release", on_click = function() updater:open_release() end
  })
  node.notes = Modifier():pointerArea({
    name = "update-dialog-notes",
    on_scroll_up = function()
      state.scroll_index = math.max(0, (state.scroll_index or 0) - 1)
      services.effects.render()
    end,
    on_scroll_down = function()
      state.scroll_index = math.min(node.max_scroll or 0,
        (state.scroll_index or 0) + 1)
      services.effects.render()
    end
  })
  node.cancel = action("update-dialog-cancel", "Cancel", function() updater:close() end, false)
  node.install = action("update-dialog-install", "Update", function() updater:install(false) end, true)
  node.okay = action("update-dialog-okay", "Okay", function() updater:close() end, true)

  function node:update() end
  function node:measure(parent) return {w = parent.w, h = parent.h} end

  local function register(modifier, bounds)
    local placeholder = {modifier = modifier}
    function placeholder:measure() return {w = bounds.w, h = bounds.h} end
    function placeholder:draw() end
    ui.draw_node(placeholder, nil, bounds)
  end

  local function wrap_notes(text, width, size)
    local lines = {}
    text = tostring(text or ""):gsub("\r", "")
    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
      local normalized = paragraph:gsub("^%s*[%-%*]%s+", "• ")
        :gsub("^%s+", ""):gsub("%s+$", "")
      if normalized ~= "" then
        local line = ""
        for word in normalized:gmatch("%S+") do
          local candidate = line == "" and word or (line .. " " .. word)
          if ui.text_width(candidate, size) <= width then
            line = candidate
          else
            if line ~= "" then lines[#lines + 1] = line end
            line = word
          end
        end
        if line ~= "" then lines[#lines + 1] = line end
      end
    end
    return lines
  end

  function node:draw(ass, bounds)
    if not state.open then return end
    register(self.backdrop, bounds)
    draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2, 0, "#000000", alpha(0.56), true)

    local width = math.max(dp(300), math.min(dp(500), bounds.w - dp(32)))
    local height = math.max(dp(300), math.min(dp(430), bounds.h - dp(32)))
    local panel = Rect({x = bounds.x + (bounds.w - width) / 2,
      y = bounds.y + (bounds.h - height) / 2, w = width, h = height})
    draw_box(ass, panel.x, panel.y, panel.x2, panel.y2, dp(28), "#111416", "00", true)
    local padding, gap = dp(8), dp(8)
    local release_size = dp(34)
    local release_bounds = Rect({
      x = panel.x2 - padding - release_size,
      y = panel.y + padding,
      w = release_size, h = release_size
    })
    register(self.release, release_bounds)
    if mouse_in(release_bounds) then
      draw_box(ass, release_bounds.x, release_bounds.y,
        release_bounds.x2, release_bounds.y2, release_bounds.h / 2,
        "#FFFFFF", "DD", true)
    end
    draw_icon(ass, release_bounds.x + release_bounds.w / 2,
      release_bounds.y + release_bounds.h / 2,
      "open_in_new", "#FFFFFF", 20, "00", true)
    local header_y, header_h = panel.y + padding, dp(42)
    local header_center_y = header_y + header_h / 2
    local header_text = state.done and "material-osc updated" or
      "material-osc update available"
    local header_version = tostring(state.version or "")
    local header_separator = header_version == "" and "" or " · "
    local header_icon_size = dp(22)
    local header_text_width = ui.text_width(header_text, 25)
    local header_separator_width = ui.text_width(header_separator, 25)
    local header_version_width = ui.text_width(header_version, 25)
    local header_group_width = header_icon_size + gap + header_text_width +
      header_separator_width + header_version_width
    local header_x = panel.x + (panel.w - header_group_width) / 2
    draw_icon(ass, header_x + header_icon_size / 2, header_center_y,
      state.done and "check_circle" or "system_update", "#FFFFFF",
      22, "00", true)
    draw_text(ass, header_x + header_icon_size + gap, header_center_y,
      header_text, 25, "#FFFFFF", "00", ui.default_text_font, 4, false, true)
    if header_version ~= "" then
      local suffix_x = header_x + header_icon_size + gap + header_text_width
      draw_text(ass, suffix_x, header_center_y, header_separator, 25,
        "#FFFFFF", "00", ui.default_text_font, 4, false, true)
      draw_text(ass, suffix_x + header_separator_width, header_center_y,
        header_version, 25,
        "#FFFFFF", "00", ui.default_text_font, 4, true, true)
      local underline_x = suffix_x + header_separator_width
      local underline_y = header_center_y + dp(14)
      draw_box(ass, underline_x, underline_y,
        underline_x + header_version_width, underline_y + dp(1.5),
        dp(0.75), "#FFFFFF", "00", true)
    end

    local button_h = dp(42)
    local button_y = panel.y2 - padding - button_h
    local cancel_w, install_w = dp(92), dp(104)
    local install_x = panel.x2 - padding - install_w
    local cancel_x = install_x - gap - cancel_w
    local note_y = header_y + header_h + gap
    local note_bottom = button_y - gap
    local text_inset = padding + dp(8)
    local note_size, line_height = 22, dp(27)
    local note_height = math.max(0, note_bottom - note_y)
    local visible_lines = math.max(1, math.floor(note_height / line_height))
    local notes = state.error or state.notes
    local provisional_width = panel.w - text_inset * 2 - gap - dp(3)
    local provisional_lines = wrap_notes(notes, provisional_width, note_size)
    local has_scrollbar = #provisional_lines > visible_lines
    local right_inset = has_scrollbar and padding or text_inset
    local note_bounds = Rect({
      x = panel.x + text_inset, y = note_y,
      w = panel.w - text_inset - right_inset, h = note_height
    })
    register(self.notes, note_bounds)
    local note_width = note_bounds.w - (has_scrollbar and (gap + dp(3)) or 0)
    local lines = wrap_notes(notes, note_width, note_size)
    node.max_scroll = math.max(0, #lines - visible_lines)
    state.scroll_index = clamp(state.scroll_index or 0, 0, node.max_scroll)
    local last_line = math.min(#lines, state.scroll_index + visible_lines)
    for index = state.scroll_index + 1, last_line do
      draw_text(ass, note_bounds.x, note_y +
        (index - state.scroll_index - 1) * line_height, lines[index], note_size,
        state.error and "#FFB4AB" or "#E2E2E6", "00", ui.default_text_font, 7,
        false, true, note_bounds)
    end
    if node.max_scroll > 0 then
      local track_x = note_bounds.x2 - dp(3)
      local track_h = note_bounds.h
      local thumb_h = math.max(dp(24), track_h * visible_lines / #lines)
      local thumb_y = note_bounds.y + (track_h - thumb_h) *
        state.scroll_index / node.max_scroll
      draw_box(ass, track_x, note_bounds.y, track_x + dp(3), note_bounds.y2,
        dp(1.5), "#FFFFFF", "D8", true)
      draw_box(ass, track_x, thumb_y, track_x + dp(3), thumb_y + thumb_h,
        dp(1.5), "#CAC4D0", "44", true)
    end

    do
      local action_x = state.done and install_x or cancel_x
      local toggle_bounds = Rect({
        x = panel.x + padding + dp(8), y = button_y,
        w = math.max(0, action_x - gap - panel.x - padding - dp(8)),
        h = button_h
      })
      register(self.toggle, toggle_bounds)
      local box_size = dp(22)
      local box_x = toggle_bounds.x
      local box_y = toggle_bounds.y + (toggle_bounds.h - box_size) / 2
      local checked = state.done and state.disable_auto_update or state.dont_ask
      draw_box(ass, box_x, box_y, box_x + box_size, box_y + box_size, dp(5),
        checked and services.config.opts.accent_color or "#111416", "00", true)
      if not checked then
        draw_box(ass, box_x, box_y, box_x + box_size, box_y + box_size, dp(5),
          "#CAC4D0", "88", true)
      else
        draw_icon(ass, box_x + box_size / 2, box_y + box_size / 2,
          "check", "#001F28", 18, "00", true)
      end
      draw_text(ass, box_x + box_size + gap, toggle_bounds.y + toggle_bounds.h / 2,
        state.done and "Disable automatic updates" or "Don’t ask again",
        20, "#FFFFFF", "00", ui.default_text_font, 4, false, true)
    end

    if state.done then
      local okay_bounds = Rect({x = install_x, y = button_y,
        w = install_w, h = button_h})
      ui.draw_node(self.okay, ass, okay_bounds)
    else
      local install_bounds = Rect({x = install_x, y = button_y,
        w = install_w, h = button_h})
      local cancel_bounds = Rect({x = cancel_x, y = button_y,
        w = cancel_w, h = button_h})
      self.install.modifier.pointer_enabled = not state.busy
      self.install.label = state.busy and "Updating…" or "Update"
      ui.draw_node(self.cancel, ass, cancel_bounds)
      ui.draw_node(self.install, ass, install_bounds)
    end
  end

  return node
end

return update_dialog
