local context_menu = {}

function context_menu.new(services)
  local state, ui = services.state.context_menu, services.ui
  local actions = services.context_actions
  local dp, clamp = ui.dp, ui.clamp
  local Modifier, Rect = ui.Modifier, ui.Rect
  local draw_node = ui.draw_node
  local node = {
    items = {}, rows = {}, panel_w = dp(330), row_h = dp(42),
    panel_padding = dp(8), row_gap = dp(4), separator_h = dp(1),
    morph = 0, content_opacity = 0, interactive = false,
    modifier = Modifier():fillMaxWidth():fillMaxHeight():drawBehindInteraction(false)
  }

  node.backdrop = {
    modifier = Modifier():fillMaxWidth():fillMaxHeight():clickable({
      name = "context-menu-backdrop",
      on_click = function()
        services.close_context_menu(
          services.state.pointer.x, services.state.pointer.y)
      end
    })
  }
  function node.backdrop:measure(parent)
    return ui.apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
  end
  function node.backdrop:draw() end

  local function MenuRow(index)
    local row
    row = {
      item = nil,
      modifier = Modifier():fillMaxWidth():height(dp(42)):clickable({
        name = "context-menu-item-" .. tostring(index),
        on_click = function()
          if row.item and row.item.action then row.item.action() end
          services.close_context_menu()
        end
      })
    }
    function row:measure(parent)
      return ui.apply_modifier_size(self.modifier, {w = 0, h = node.row_h}, parent)
    end
    function row:draw(ass, bounds)
      if not self.item then return end
      if node.interactive and ui.mouse_in(bounds) then
        ui.draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
          bounds.h / 2, "#FFFFFF",
          ui.alpha(node.content_opacity * 0.15), true, node.clip_bounds)
      end
      ui.draw_icon(ass, bounds.x + dp(22), bounds.y + bounds.h / 2,
        self.item.icon, "#CAC4D0", 22, ui.alpha(node.content_opacity),
        true, node.clip_bounds)
      ui.draw_text(ass, bounds.x + dp(46), bounds.y + bounds.h / 2,
        ui.truncate_to_width(self.item.label, math.max(0, bounds.w - dp(60)), 20),
        20, "#FFFFFF", ui.alpha(node.content_opacity), ui.default_text_font,
        4, nil, true, node.clip_bounds)
    end
    return row
  end

  for index = 1, 16 do node.rows[index] = MenuRow(index) end

  node.panel = {
    modifier = Modifier():clickable({
      name = "context-menu-panel", on_click = function() end
    })
  }
  function node.panel:measure(parent)
    return ui.apply_modifier_size(self.modifier,
      {w = node.panel_w, h = node.panel_h or 0}, parent)
  end
  function node.panel:draw(ass, bounds)
    node.clip_bounds = bounds
    local shell_opacity = state.open and
      (0.53 + node.morph * 0.39) or node.morph * 0.92
    ui.draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
      dp(14) + dp(14) * node.morph, "#050708",
      ui.alpha(shell_opacity), true)
    local y, row_index = bounds.y + node.panel_padding, 1
    for item_index, item in ipairs(node.items) do
      if item.separator then
        ui.draw_box(ass, bounds.x + node.panel_padding + dp(4), y,
          bounds.x2 - node.panel_padding - dp(4), y + node.separator_h,
          node.separator_h / 2, "#FFFFFF",
          ui.alpha(node.content_opacity * 0.15), true, node.clip_bounds)
        y = y + node.separator_h
      else
        local row = node.rows[row_index]
        row.item = item
        draw_node(row, ass, Rect({
          x = bounds.x + node.panel_padding, y = y,
          w = bounds.w - node.panel_padding * 2, h = node.row_h
        }))
        y = y + node.row_h
        row_index = row_index + 1
      end
      if item_index < #node.items then y = y + node.row_gap end
    end
  end

  function node:update(snapshot)
    if not state.open and state.pending_x ~= nil and
      not state.animation:is_running() and state.animation.value <= 0.001 then
      state.width_animation:snap(dp(28))
      state.height_animation:snap(dp(28))
      state.x, state.y = state.pending_x, state.pending_y
      state.pending_x, state.pending_y = nil, nil
      state.close_x, state.close_y = nil, nil
      state.open = true
      state.animation:set_target(1, nil, 0.12)
    end
    self.items = actions:items(snapshot)
    self.morph = clamp(state.animation.value, 0, 1)
    local content_progress = clamp((self.morph - 0.62) / 0.38, 0, 1)
    content_progress = content_progress * content_progress *
      (3 - 2 * content_progress)
    self.content_opacity = self.morph * content_progress
    self.interactive = state.open and self.morph > 0.9
    self.backdrop.modifier.pointer_enabled = state.open
    self.panel.modifier.pointer_enabled = self.interactive
    self.panel_w = math.max(dp(220),
      math.min(dp(330), services.state.viewport.w - dp(16)))
    local rows, separators = 0, 0
    for _, item in ipairs(self.items) do
      if item.separator then separators = separators + 1 else rows = rows + 1 end
    end
    local available_h = math.max(dp(32), services.state.viewport.h - dp(16))
    local gaps = math.max(0, #self.items - 1)
    self.row_h = math.min(dp(42), math.max(dp(32),
      (available_h - self.panel_padding * 2 -
        separators * self.separator_h - gaps * self.row_gap) /
        math.max(1, rows)))
    for _, row in ipairs(self.rows) do row.modifier.fixed_height = self.row_h end
    self.panel_h = self.panel_padding * 2 + rows * self.row_h +
      separators * self.separator_h + gaps * self.row_gap
    state.width_animation:set_target(state.open and self.panel_w or dp(28))
    state.height_animation:set_target(state.open and self.panel_h or dp(28))
    for _, row in ipairs(self.rows) do
      row.modifier.pointer_enabled = self.interactive
    end
  end

  function node:measure(parent)
    return ui.apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
  end

  function node:draw(ass, bounds)
    if self.morph <= 0 and not state.open and
      not state.animation:is_running() and
      not state.width_animation:is_running() and
      not state.height_animation:is_running() then
      state.bounds = nil
      return
    end
    if state.open then draw_node(self.backdrop, ass, bounds) end
    local margin = dp(8)
    local target_x = clamp(state.x, bounds.x + margin,
      math.max(bounds.x + margin, bounds.x2 - self.panel_w - margin))
    local target_y = clamp(state.y, bounds.y + margin,
      math.max(bounds.y + margin, bounds.y2 - self.panel_h - margin))
    local anchor_x = not state.open and state.close_x or state.x
    local anchor_y = not state.open and state.close_y or state.y
    anchor_x, anchor_y = anchor_x or state.x, anchor_y or state.y
    local source_w, source_h = dp(28), dp(28)
    local source_x = clamp(anchor_x - source_w / 2, bounds.x + margin,
      bounds.x2 - source_w - margin)
    local source_y = clamp(anchor_y - source_h / 2, bounds.y + margin,
      bounds.y2 - source_h - margin)
    local surface_w = math.max(source_w, state.width_animation.value)
    local surface_h = math.max(source_h, state.height_animation.value)
    local width_progress = clamp((surface_w - source_w) /
      math.max(dp(1), self.panel_w - source_w), 0, 1)
    local height_progress = clamp((surface_h - source_h) /
      math.max(dp(1), self.panel_h - source_h), 0, 1)
    local surface = Rect({
      x = source_x + (target_x - source_x) * width_progress,
      y = source_y + (target_y - source_y) * height_progress,
      w = surface_w,
      h = surface_h
    })
    self.panel.modifier.fixed_width = surface.w
    self.panel.modifier.fixed_height = surface.h
    state.bounds = draw_node(self.panel, ass, surface)
  end

  return node
end

return context_menu
