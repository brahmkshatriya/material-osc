local context_menu = {}

-- delay before hovering a row opens/closes submenus (like native menus)
local HOVER_DELAY = 0.2
-- submenu open animation length
local SUBMENU_DURATION = 0.18

function context_menu.new(services)
  local state, ui = services.state.context_menu, services.ui
  local actions = services.context_actions
  local menu_items = services.menu_items
  local opts = services.config.opts
  local render = services.effects.render
  local render_all = services.effects.render_all or render
  local dp, clamp = ui.dp, ui.clamp
  local Modifier, Rect = ui.Modifier, ui.Rect
  local draw_node = ui.draw_node
  local separator_h = dp(1)
  local node = {
    -- levels[1] is the root panel, levels[k] the submenu at state.path[k - 1]
    levels = {}, panels = {}, rows = {}, anchors = {},
    -- per submenu level: which submenu is shown and when it started opening
    opened = {},
    panel_w = dp(330), panel_h = 0,
    morph = 0, content_opacity = 0, interactive = false, was_open = false,
    animation_frame = nil,
    modifier = Modifier():fillMaxWidth():fillMaxHeight():drawBehindInteraction(false)
  }
  state.path = state.path or {}
  state.scrolls = state.scrolls or {}
  local hover = {timer = nil, target = nil}

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

  -- submenu path helpers --------------------------------------------------

  local function prefix(depth, extra)
    local path = {}
    for index = 1, depth do path[index] = state.path[index] end
    if extra then path[#path + 1] = extra end
    return path
  end

  local function same_path(a, b)
    if #a ~= #b then return false end
    for index = 1, #a do
      if a[index] ~= b[index] then return false end
    end
    return true
  end

  local function is_prefix(short, long)
    if #short > #long then return false end
    for index = 1, #short do
      if short[index] ~= long[index] then return false end
    end
    return true
  end

  local function cancel_hover()
    if hover.timer then hover.timer:kill() end
    hover.timer, hover.target = nil, nil
  end

  local function set_path(path)
    cancel_hover()
    if same_path(path, state.path) then return end
    local common = 0
    while common < #path and common < #state.path and
      path[common + 1] == state.path[common + 1] do
      common = common + 1
    end
    -- levels whose content changed start scrolled to the top
    for level = common + 2, math.max(#path, #state.path) + 1 do
      state.scrolls[level] = nil
    end
    state.path = path
    render_all()
  end

  local function request_path(path)
    if same_path(path, state.path) then
      cancel_hover()
      return
    end
    if hover.target and same_path(hover.target, path) then return end
    cancel_hover()
    hover.target = path
    hover.timer = mp.add_timeout(HOVER_DELAY, function()
      hover.timer, hover.target = nil, nil
      if state.open then set_path(path) end
    end)
  end

  local function scroll(level, direction)
    local layout = node.levels[level]
    if not layout then return end
    local value = clamp((state.scrolls[level] or 0) + direction, 0,
      layout.max_scroll)
    if value == (state.scrolls[level] or 0) then return end
    state.scrolls[level] = value
    render()
  end

  -- keeps frames coming while a submenu animates (one request per frame)
  local function request_animation_frame()
    if node.animation_frame then return end
    node.animation_frame = mp.add_timeout(1 / 120, function()
      node.animation_frame = nil
      render()
    end)
  end

  -- arrow keys move between the rows of a panel and scroll at its edges
  local function move_focus(level, index, delta)
    local target = node.rows[level] and node.rows[level][index + delta]
    if target and target.item then
      services.state.input.keyboard_focus = target.modifier.pointer_name
    else
      scroll(level, delta)
    end
  end

  -- rows and panels ---------------------------------------------------------

  local function MenuRow(level, index)
    local row
    row = {
      item = nil, level = level, opacity = 1,
      modifier = Modifier():fillMaxWidth():height(dp(32)):clickable({
        name = "context-menu-item-" .. level .. "-" .. index,
        on_click = function()
          local item = row.item
          if not item or item.disabled then return end
          if item.submenu then
            -- open right away (and toggle closed on a second click)
            if state.path[level] == item.submenu_index then
              set_path(prefix(level - 1))
            else
              set_path(prefix(level - 1, item.submenu_index))
            end
            return
          end
          if item.action then item.action() end
          services.close_context_menu()
        end,
        on_scroll_up = function() scroll(level, -1) end,
        on_scroll_down = function() scroll(level, 1) end,
        on_keyboard_up = function() move_focus(level, index, -1) end,
        on_keyboard_down = function() move_focus(level, index, 1) end,
        on_keyboard_right = function()
          local item = row.item
          if item and item.submenu and not item.disabled then
            set_path(prefix(level - 1, item.submenu_index))
          end
        end,
        on_keyboard_left = function()
          if level == 1 then return end
          -- back to the row that opened this submenu
          local submenu_index = state.path[level - 1]
          for _, parent in ipairs(node.rows[level - 1] or {}) do
            if parent.item and parent.item.submenu_index == submenu_index then
              services.state.input.keyboard_focus = parent.modifier.pointer_name
            end
          end
          set_path(prefix(level - 2))
        end
      })
    }
    function row:measure(parent)
      local layout = node.levels[self.level]
      return ui.apply_modifier_size(self.modifier,
        {w = 0, h = layout and layout.row_h or dp(32)}, parent)
    end
    function row:draw(ass, bounds)
      local item = self.item
      local layout = node.levels[self.level]
      if not item or not layout then return end
      local base_opacity = node.content_opacity * self.opacity
      local opacity = base_opacity * (item.disabled and 0.4 or 1)
      local hovered = node.interactive and not item.disabled and
        ui.mouse_in(bounds)
      local active = item.submenu and state.path[self.level] == item.submenu_index
      if hovered or active then
        ui.draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
          bounds.h / 2, "#FFFFFF",
          ui.alpha(base_opacity * (hovered and 0.15 or 0.10)),
          true, node.clip_bounds)
      end
      if hovered and not services.state.input.keyboard_focus then
        -- hovering opens this row's submenu, or closes deeper submenus
        request_path(item.submenu and
          prefix(self.level - 1, item.submenu_index) or prefix(self.level - 1))
      end
      if active then node.anchors[self.level] = bounds end
      local center_y = bounds.y + bounds.h / 2
      local icon = item.icon or (item.checked and "check")
      if icon then
        ui.draw_icon(ass, bounds.x + layout.icon_x, center_y, icon,
          item.checked and opts.accent_color or "#CAC4D0", layout.icon_size,
          ui.alpha(opacity), true, node.clip_bounds)
      end
      local text_x = bounds.x + layout.text_inset
      local trailing = layout.end_inset
      if item.submenu then
        ui.draw_icon(ass, bounds.x2 - layout.end_inset - dp(4), center_y,
          "chevron_right", "#CAC4D0", layout.icon_size - 2,
          ui.alpha(opacity), true, node.clip_bounds)
        trailing = layout.end_inset + dp(20)
      end
      if item.shortcut and item.shortcut ~= "" then
        ui.draw_text(ass, bounds.x2 - trailing, center_y, item.shortcut,
          layout.shortcut_size, "#CAC4D0", ui.alpha(opacity * 0.8),
          ui.default_text_font, 6, nil, true, node.clip_bounds)
        trailing = trailing +
          ui.text_width(item.shortcut, layout.shortcut_size) + dp(14)
      end
      ui.draw_text(ass, text_x, center_y,
        ui.truncate_to_width(item.label,
          math.max(0, bounds.x2 - trailing - text_x), layout.text_size),
        layout.text_size, "#FFFFFF", ui.alpha(opacity), ui.default_text_font,
        4, nil, true, node.clip_bounds)
    end
    return row
  end

  local function row_at(level, index)
    node.rows[level] = node.rows[level] or {}
    local row = node.rows[level][index]
    if not row then
      row = MenuRow(level, index)
      node.rows[level][index] = row
    end
    row.modifier.pointer_enabled = node.interactive
    return row
  end

  local function panel_at(level)
    local panel = node.panels[level]
    if panel then return panel end
    panel = {
      modifier = Modifier():clickable({
        name = "context-menu-panel-" .. level, on_click = function() end,
        on_scroll_up = function() scroll(level, -1) end,
        on_scroll_down = function() scroll(level, 1) end
      })
    }
    function panel:measure(parent)
      return ui.apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end
    function panel:draw() end
    node.panels[level] = panel
    return panel
  end

  -- content_opacity: extra fade for this panel's content (submenu animation)
  local function draw_level(ass, level, bounds, radius, shell_opacity,
      content_opacity)
    local layout = node.levels[level]
    local padding, gap = layout.padding, layout.gap
    local panel = panel_at(level)
    panel.modifier.fixed_width, panel.modifier.fixed_height = bounds.w, bounds.h
    panel.modifier.pointer_enabled = node.interactive
    draw_node(panel, ass, bounds)
    node.clip_bounds = bounds
    ui.draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2, radius,
      "#050708", ui.alpha(shell_opacity), true)
    -- keep a pending "close deeper menus" request from firing while the
    -- pointer is already inside the deepest open submenu
    if level == #state.path + 1 and level > 1 and hover.target and
      not is_prefix(state.path, hover.target) and ui.mouse_in(bounds) then
      cancel_hover()
    end

    local y, row_index = bounds.y + padding, 1
    local bottom = bounds.y2 - padding
    local first = (state.scrolls[level] or 0) + 1
    for item_index = first, #layout.items do
      local item = layout.items[item_index]
      local height = item.separator and separator_h or layout.row_h
      if y + height > bottom + 0.5 then break end
      if item.separator then
        ui.draw_box(ass, bounds.x + padding + dp(4), y,
          bounds.x2 - padding - dp(4), y + separator_h,
          separator_h / 2, "#FFFFFF",
          ui.alpha(node.content_opacity * content_opacity * 0.15),
          true, node.clip_bounds)
      else
        local row = row_at(level, row_index)
        row.item = item
        row.opacity = content_opacity
        row.modifier.fixed_height = layout.row_h
        draw_node(row, ass, Rect({
          x = bounds.x + padding, y = y,
          w = bounds.w - padding * 2, h = layout.row_h
        }))
        row_index = row_index + 1
      end
      y = y + height + (item.separator and layout.separator_gap or gap)
    end
    for index = row_index, #(node.rows[level] or {}) do
      node.rows[level][index].item = nil
    end

    if layout.max_scroll > 0 then
      local track_h = bounds.h - padding * 2
      local visible = math.max(0.1, 1 - layout.max_scroll / #layout.items)
      local thumb_h = math.max(dp(20), track_h * visible)
      local thumb_y = bounds.y + padding +
        (track_h - thumb_h) * (state.scrolls[level] or 0) / layout.max_scroll
      ui.draw_box(ass, bounds.x2 - dp(4), thumb_y, bounds.x2 - dp(1.5),
        thumb_y + thumb_h, dp(1.25), "#FFFFFF",
        ui.alpha(node.content_opacity * content_opacity * 0.3), true, bounds)
    end
  end

  -- items and layout --------------------------------------------------------

  local function input_conf_enabled()
    return opts.context_menu_items == "input_conf" and menu_items and
      menu_items:available()
  end

  local function input_conf_items(path)
    local entries = menu_items:level(path)
    if not entries or #entries == 0 then return nil end
    local items = {}
    for _, entry in ipairs(entries) do
      if entry.separator then
        items[#items + 1] = entry
      else
        local item = {
          label = entry.label, shortcut = entry.shortcut,
          checked = entry.checked, disabled = entry.disabled,
          submenu = entry.submenu_index ~= nil,
          submenu_index = entry.submenu_index
        }
        if not item.submenu and entry.command and entry.command ~= "" then
          item.action = function() mp.command(entry.command) end
        end
        items[#items + 1] = item
      end
    end
    return items
  end

  -- compact: the dense layout of the input.conf menu; otherwise material's
  -- own menu metrics
  local function measure_level(items, compact)
    local layout = {
      items = items, has_icons = not compact, max_scroll = 0,
      padding = dp(compact and 6 or 8), gap = dp(compact and 0 or 4),
      separator_gap = dp(compact and 4 or 4),
      text_size = compact and 18 or 20, shortcut_size = compact and 15 or 17,
      icon_size = compact and 19 or 22, icon_x = dp(compact and 18 or 22),
      end_inset = dp(compact and 12 or 14)
    }
    local widest = 0
    for _, item in ipairs(items) do
      if item.icon or item.checked then layout.has_icons = true end
      if not item.separator then
        local width = ui.text_width(item.label or "", layout.text_size)
        if item.shortcut and item.shortcut ~= "" then
          width = width + ui.text_width(item.shortcut, layout.shortcut_size) +
            dp(14)
        end
        if item.submenu then width = width + dp(20) end
        widest = math.max(widest, width)
      end
    end
    layout.text_inset = layout.has_icons and dp(compact and 38 or 46) or
      dp(compact and 14 or 16)
    local viewport = services.state.viewport
    local max_w = math.max(dp(160), viewport.w - dp(16))
    if compact then
      local chrome = layout.padding * 2 + layout.text_inset +
        layout.end_inset + dp(8)
      layout.w = math.min(max_w, clamp(widest + chrome, dp(180), dp(400)))
    else
      layout.w = math.max(dp(220), math.min(dp(330), max_w))
    end

    local rows, separators = 0, 0
    for _, item in ipairs(items) do
      if item.separator then separators = separators + 1
      else rows = rows + 1 end
    end
    local available_h = math.max(dp(32), viewport.h - dp(16))
    local gaps = 0
    for index = 1, #items - 1 do
      gaps = gaps + (items[index].separator and layout.separator_gap or layout.gap)
    end
    local fixed = layout.padding * 2 + separators * separator_h + gaps
    -- shrink rows to fit (down to 28dp), then scroll whatever still overflows
    layout.row_h = math.min(dp(compact and 32 or 42),
      math.max(dp(compact and 28 or 32), (available_h - fixed) / math.max(1, rows)))
    local content_h = fixed + rows * layout.row_h
    layout.h = math.min(content_h, available_h)
    if content_h > available_h then
      local room = available_h - layout.padding * 2
      local used, first = 0, #items + 1
      for index = #items, 1, -1 do
        local item = items[index]
        local height = (item.separator and separator_h or layout.row_h) +
          (index < #items and
            (item.separator and layout.separator_gap or layout.gap) or 0)
        if used + height > room then break end
        used, first = used + height, index
      end
      layout.max_scroll = math.max(0, first - 1)
    end
    return layout
  end

  local function layout_levels(snapshot)
    local levels = {}
    if input_conf_enabled() then
      for level = 1, #state.path + 1 do
        local items = input_conf_items(prefix(level - 1))
        if not items then
          -- the submenu disappeared (menu data changed): close from here
          for index = #state.path, math.max(1, level - 1), -1 do
            state.path[index] = nil
          end
          break
        end
        levels[level] = measure_level(items, true)
      end
    end
    if not levels[1] then
      state.path = {}
      levels[1] = measure_level(actions:items(snapshot), false)
    end
    for level, layout in ipairs(levels) do
      state.scrolls[level] = clamp(state.scrolls[level] or 0, 0, layout.max_scroll)
    end
    node.levels = levels
    node.panel_w, node.panel_h = levels[1].w, levels[1].h
  end

  -- submenu open progress (0..1, eased) for the panel at level
  local function submenu_progress(level, now)
    local key = table.concat(prefix(level - 1), "/")
    local opened = node.opened[level]
    if not opened or opened.key ~= key then
      opened = {key = key, started = now}
      node.opened[level] = opened
    end
    local t = clamp((now - opened.started) / SUBMENU_DURATION, 0, 1)
    -- ease out cubic
    return 1 - (1 - t) * (1 - t) * (1 - t), t < 1
  end

  -- node --------------------------------------------------------------------

  function node:update(snapshot, refresh_items)
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
    if state.open and not self.was_open then
      -- every opening starts at the root menu
      cancel_hover()
      state.path, state.scrolls = {}, {}
      self.opened = {}
      refresh_items = true
    elseif not state.open and self.was_open then
      cancel_hover()
    end
    self.was_open = state.open
    if refresh_items ~= false or not self.levels[1] then layout_levels(snapshot) end
    self.morph = clamp(state.animation.value, 0, 1)
    local content_progress = clamp((self.morph - 0.62) / 0.38, 0, 1)
    content_progress = content_progress * content_progress *
      (3 - 2 * content_progress)
    self.content_opacity = self.morph * content_progress
    self.interactive = state.open and self.morph > 0.9
    self.backdrop.modifier.pointer_enabled = state.open
    state.width_animation:set_target(state.open and self.panel_w or dp(28))
    state.height_animation:set_target(state.open and self.panel_h or dp(28))
  end

  function node:measure(parent)
    return ui.apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
  end

  function node:draw(ass, bounds)
    if self.morph <= 0 and not state.open and
      not state.animation:is_running() and
      not state.width_animation:is_running() and
      not state.height_animation:is_running() then
      state.bounds, state.keyboard_bounds = nil, nil
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

    -- root panel morphs open from the click point
    self.anchors = {}
    local compact = self.levels[1].padding < dp(8)
    local root_radius = compact and (dp(10) + dp(8) * self.morph) or
      (dp(14) + dp(14) * self.morph)
    local shell_opacity = state.open and
      (0.53 + self.morph * 0.39) or self.morph * 0.92
    draw_level(ass, 1, surface, root_radius, shell_opacity, 1)
    state.bounds = surface
    state.keyboard_bounds = nil

    -- open submenus cascade beside the row that opened them, growing out of
    -- that row while sliding away from the parent
    for level = #self.levels + 1, #self.opened do self.opened[level] = nil end
    if self.content_opacity <= 0 then return end
    local now = mp.get_time()
    local animating = false
    local parent = surface
    for level = 2, #self.levels do
      local layout = self.levels[level]
      local anchor = self.anchors[level - 1] or parent
      local gap = dp(4)
      local x = parent.x2 + gap
      local direction = 1
      if x + layout.w > bounds.x2 - margin then
        x = parent.x - layout.w - gap
        direction = -1
      end
      x = clamp(x, bounds.x + margin,
        math.max(bounds.x + margin, bounds.x2 - layout.w - margin))
      local y = clamp(anchor.y - layout.padding, bounds.y + margin,
        math.max(bounds.y + margin, bounds.y2 - layout.h - margin))
      local progress, running = submenu_progress(level, now)
      animating = animating or running
      -- start as a strip the size of the anchor row, then expand
      local start_h = math.min(layout.h, anchor.h + layout.padding * 2)
      local start_y = clamp(anchor.y - layout.padding, bounds.y + margin,
        math.max(bounds.y + margin, bounds.y2 - start_h - margin))
      local w = layout.w * (0.85 + 0.15 * progress)
      local rect = Rect({
        x = direction > 0 and x - dp(10) * (1 - progress) or
          x + (layout.w - w) + dp(10) * (1 - progress),
        y = start_y + (y - start_y) * progress,
        w = w,
        h = start_h + (layout.h - start_h) * progress
      })
      local radius = dp(10) + dp(8) * progress
      local content = clamp((progress - 0.35) / 0.65, 0, 1)
      draw_level(ass, level, rect, radius,
        0.92 * self.content_opacity * clamp(progress * 1.6, 0, 1), content)
      -- keep cascading from the final position so deeper panels don't drift
      parent = Rect({x = x, y = y, w = layout.w, h = layout.h})
      -- the arrow keys move inside the deepest open submenu
      state.keyboard_bounds = rect
    end
    if animating then request_animation_frame() end
  end

  return node
end

return context_menu
