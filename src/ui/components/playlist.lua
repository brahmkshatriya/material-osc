local playlist = {}

function playlist.new(services, trailing)
  local state, ui = services.state, services.ui
  local playlist_state, pointer = state.playlist, state.pointer
  local dp, clamp = ui.dp, ui.clamp
  local alpha = ui.alpha
  local draw_box, draw_rect = ui.draw_box, ui.draw_rect
  local draw_round_box = ui.draw_round_box
  local draw_icon, draw_text = ui.draw_icon, ui.draw_text
  local Modifier, Rect = ui.Modifier, ui.Rect
  local apply_modifier_size, measure_node = ui.apply_modifier_size, ui.measure_node
  local draw_node = ui.draw_node
  local push_clip, pop_clip = ui.push_clip, ui.pop_clip
  local mouse_in, render = ui.mouse_in, services.effects.render
  local default_text_font = ui.default_text_font
  local truncate_to_width = ui.truncate_to_width
  local is_render_pass = ui.is_render_pass
  local set_open = services.navigation.set_playlist_open

  local function move_target_from_pointer()
    local bounds = playlist_state.list_bounds
    local snapshot = state.snapshot or {}
    local count = snapshot.playlist_count or 0
    if not bounds or count == 0 then return nil end
    local row_h = dp(52)
    local relative = math.floor((pointer.y - bounds.y) / row_h)
    return clamp(playlist_state.scroll_index + relative + 1, 1, count)
  end

  local function PlaylistRow(slot)
    local node = {
      slot = slot, item = nil, index = nil, interactive = false,
      text_alpha = "00", secondary_alpha = "00", hover_alpha = "00",
      selected_alpha = "00", modifier = Modifier():fillMaxWidth():height(dp(52))
    }
    node.modifier:pointerArea({
      name = "playlist-row-" .. tostring(slot), enabled = false,
      on_keyboard = function()
        if node.index then mp.commandv("playlist-play-index", node.index - 1) end
      end,
      on_press = function()
        if not node.item or not node.index then return end
        playlist_state.drag_from = node.index
        playlist_state.drag_to = node.index
        playlist_state.drag_start_y = pointer.y
        render()
      end,
      on_move = function()
        local target = move_target_from_pointer()
        if target then playlist_state.drag_to = target; render() end
      end,
      on_release = function()
        local from = playlist_state.drag_from
        local target = move_target_from_pointer() or playlist_state.drag_to
        local moved = playlist_state.drag_start_y and
          math.abs(pointer.y - playlist_state.drag_start_y) >= dp(5)
        playlist_state.drag_from, playlist_state.drag_to = nil, nil
        playlist_state.drag_start_y = nil
        if from and target and moved and from ~= target then
          -- mpv indices are zero based. playlist-move places the source at
          -- the target entry; using count is supported for an end drop.
          local destination = target - 1
          if from < target then destination = target end
          mp.commandv("playlist-move", from - 1, destination)
        elseif from then
          mp.commandv("playlist-play-index", from - 1)
        end
        render()
      end
    })

    function node:update(props)
      for key, value in pairs(props) do self[key] = value end
      self.modifier.pointer_enabled = self.interactive and self.item ~= nil
    end
    function node:measure(parent)
      if not self.item then return {w = 0, h = 0} end
      return apply_modifier_size(self.modifier, {w = 0, h = dp(52)}, parent)
    end
    function node:draw(ass, bounds)
      if not self.item then return end
      local dragging = playlist_state.drag_from == self.index
      local hovered = self.interactive and mouse_in(bounds)
      if self.item.current or dragging then
        draw_box(ass, bounds.x, bounds.y + dp(2), bounds.x2, bounds.y2 - dp(2),
          dp(24), self.item.current and services.config.opts.accent_color or "#FFFFFF",
          dragging and self.hover_alpha or self.selected_alpha)
      elseif hovered then
        draw_box(ass, bounds.x, bounds.y + dp(2), bounds.x2, bounds.y2 - dp(2),
          dp(24), "#FFFFFF", self.hover_alpha)
      end
      draw_icon(ass, bounds.x + dp(20), bounds.y + bounds.h / 2,
        "drag_indicator", "#CAC4D0", 22, self.secondary_alpha)
      if self.item.current then
        draw_icon(ass, bounds.x + dp(48), bounds.y + bounds.h / 2,
          "play_arrow", "#FFFFFF", 22, self.text_alpha)
      else
        draw_text(ass, bounds.x + dp(48), bounds.y + bounds.h / 2,
          tostring(self.index), 19, "#CAC4D0", self.secondary_alpha,
          default_text_font)
      end
      local title = self.item.title or ("Item " .. tostring(self.index))
      local title_x = bounds.x + dp(68)
      title = truncate_to_width(title,
        math.max(0, bounds.x2 - dp(16) - title_x), 22)
      draw_text(ass, title_x, bounds.y + bounds.h / 2,
        title, 22, "#FFFFFF", self.text_alpha, default_text_font, 4)
    end
    return node
  end

  local function FooterButton(name, icon, tooltip, on_click, shortcut,
      tooltip_allow_when_suppressed, icon_size)
    local node = ui.IconButton({name = name, icon = icon, tooltip = tooltip,
      on_click = on_click, shortcut = shortcut,
      tooltip_allow_when_suppressed = tooltip_allow_when_suppressed,
      icon_size = icon_size, horizontal_padding = 6})
    return node
  end

  local function AddMediaButton(name, icon, label, on_click)
    local node = {
      icon = icon, label = label, opacity = 0, interactive = false,
      modifier = Modifier():fillMaxWidth():height(dp(40)):clickable({
        name = name, enabled = false, on_click = on_click
      }):hoverIndication({alpha = "D2", inset = dp(2)})
    }
    function node:update(opacity, interactive)
      self.opacity, self.interactive = opacity, interactive
      self.modifier.pointer_enabled = interactive
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = dp(40)}, parent)
    end
    function node:draw(ass, bounds)
      draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2, bounds.h / 2,
        "#FFFFFF", alpha(self.opacity * 0.12))
      local icon_size, label_size, gap = 22, 22, dp(4)
      local label_width = ui.text_width(self.label, label_size)
      local content_width = dp(icon_size) + gap + label_width
      local icon_x = bounds.x + (bounds.w - content_width) / 2 +
        dp(icon_size) / 2
      draw_icon(ass, icon_x, bounds.y + bounds.h / 2,
        self.icon, "#FFFFFF", icon_size, alpha(self.opacity))
      draw_text(ass, icon_x + dp(icon_size) / 2 + gap,
        bounds.y + bounds.h / 2,
        self.label, label_size, "#FFFFFF", alpha(self.opacity),
        default_text_font, 4)
    end
    return node
  end

  local function PlaylistScrollbar()
    local node = {
      item_count = 0, visible_count = 1, interactive = false, opacity = 0,
      modifier = Modifier():fillMaxWidth():fillMaxHeight()
    }
    local function maximum_scroll()
      return math.max(0, node.item_count - node.visible_count)
    end
    local function thumb_metrics(bounds)
      local maximum = maximum_scroll()
      local thumb_h = bounds.h
      if node.item_count > 0 then
        thumb_h = math.max(dp(32), bounds.h * node.visible_count / node.item_count)
      end
      local travel = math.max(0, bounds.h - thumb_h)
      local thumb_y = bounds.y
      if maximum > 0 then
        thumb_y = bounds.y + travel * playlist_state.scroll_index / maximum
      end
      return thumb_h, thumb_y
    end
    local function update_from_pointer(bounds)
      local maximum = maximum_scroll()
      if maximum <= 0 then return end
      local thumb_h = thumb_metrics(bounds)
      local travel = math.max(1, bounds.h - thumb_h)
      local ratio = clamp((pointer.y - bounds.y - thumb_h / 2) / travel, 0, 1)
      playlist_state.scroll_index = math.floor(ratio * maximum + 0.5)
      render()
    end
    node.modifier:pointerArea({
      name = "playlist-scrollbar", enabled = false,
      on_press = function(bounds)
        playlist_state.dragging_scroll = true
        update_from_pointer(bounds)
      end,
      on_move = function(bounds)
        if playlist_state.dragging_scroll then update_from_pointer(bounds) end
      end,
      on_release = function(bounds)
        update_from_pointer(bounds)
        playlist_state.dragging_scroll = false
      end
    })
    function node:update(props)
      for key, value in pairs(props) do self[key] = value end
      self.modifier.pointer_enabled = self.interactive and maximum_scroll() > 0
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end
    function node:draw(ass, bounds)
      if maximum_scroll() <= 0 then return end
      local hovered = self.interactive and mouse_in(bounds)
      local track_w = dp(4)
      local thumb_w = (hovered or playlist_state.dragging_scroll) and dp(7) or dp(6)
      local center_x = bounds.x + bounds.w / 2
      local thumb_h, thumb_y = thumb_metrics(bounds)
      draw_box(ass, center_x - track_w / 2, bounds.y,
        center_x + track_w / 2, bounds.y2, track_w / 2,
        "#FFFFFF", alpha(self.opacity * 0.14))
      draw_box(ass, center_x - thumb_w / 2, thumb_y,
        center_x + thumb_w / 2, thumb_y + thumb_h, thumb_w / 2,
        "#FFFFFF", alpha(self.opacity * (hovered and 0.82 or 0.58)))
    end
    return node
  end

  local function ExpandedContent()
    local node = {
      snapshot = {}, opacity = 0, interactive = false, visible_rows = 1,
      modifier = Modifier():fillMaxWidth():fillMaxHeight():clickable({
        name = "playlist-surface", enabled = false, on_click = function() end
      })
    }
    node.rows = {}
    for slot = 1, 18 do node.rows[slot] = PlaylistRow(slot) end
    node.scrollbar = PlaylistScrollbar()
    node.add_files = AddMediaButton("playlist-add-files", "add",
      "File(s)", services.player.append_media_files)
    node.add_link = AddMediaButton("playlist-add-link", "link",
      "Link", services.player.append_media_link)
    node.shuffle = FooterButton("playlist-shuffle", "shuffle", "Shuffle",
      function()
        local shuffled = playlist_state.shuffled == true
        mp.commandv(shuffled and "playlist-unshuffle" or "playlist-shuffle")
        playlist_state.shuffled = not shuffled
        render()
      end, nil, true, 28)
    node.loop = FooterButton("playlist-loop", "repeat", "Loop: off",
      function()
        local mode = (state.snapshot or {}).playlist_loop_mode or "off"
        if mode == "off" then
          mp.set_property("loop-file", "no")
          mp.set_property("loop-playlist", "inf")
        elseif mode == "all" then
          mp.set_property("loop-playlist", "no")
          mp.set_property("loop-file", "inf")
        else
          mp.set_property("loop-file", "no")
          mp.set_property("loop-playlist", "no")
        end
      end, nil, true, 28)

    function node:update(snapshot, opacity, interactive, visible_rows)
      self.snapshot, self.opacity = snapshot, opacity
      self.interactive = interactive
      self.visible_rows = visible_rows or 1
      self.shuffle:update({
        icon = snapshot.playlist_shuffled and "shuffle_on" or "shuffle",
        tooltip = snapshot.playlist_shuffled and "Turn Shuffle Off" or "Shuffle",
        alpha = alpha(opacity)
      })
      local loop_mode = snapshot.playlist_loop_mode or "off"
      self.loop:update({
        icon = loop_mode == "one" and "repeat_one_on" or
          (loop_mode == "all" and "repeat_on" or "repeat"),
        tooltip = loop_mode == "one" and "Loop: Current Item" or
          (loop_mode == "all" and "Loop: Playlist" or "Loop: Off"),
        alpha = alpha(opacity)
      })
      self.shuffle.modifier.pointer_enabled = interactive
      self.loop.modifier.pointer_enabled = interactive
      self.add_files:update(opacity, interactive)
      self.add_link:update(opacity, interactive)
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end
    function node:draw(ass, bounds)
      local text_alpha = alpha(self.opacity)
      local secondary_alpha = alpha(self.opacity * 0.70)
      local hover_alpha = alpha(self.opacity * 0.16)
      local selected_alpha = alpha(self.opacity * 0.30)

      local header_h, footer_h = dp(56), dp(43)
      local padding, footer_gap, button_gap = dp(8), dp(8), dp(4)
      local header = Rect({x = bounds.x, y = bounds.y,
        w = bounds.w, h = header_h})
      local button_w = math.max(0,
        (header.w - padding * 2 - button_gap) / 2)
      local button_parent = Rect({
        x = header.x, y = header.y, w = button_w, h = header.h
      })
      local files_size = measure_node(self.add_files, button_parent)
      local link_size = measure_node(self.add_link, button_parent)
      local button_y = header.y + (header.h - files_size.h) / 2
      draw_node(self.add_files, ass, Rect({
        x = header.x + padding, y = button_y,
        w = button_w, h = files_size.h
      }))
      draw_node(self.add_link, ass, Rect({
        x = header.x + padding + button_w + button_gap, y = button_y,
        w = button_w, h = link_size.h
      }))
      draw_rect(ass, header.x, header.y2 - dp(1), header.x2, header.y2,
        "#FFFFFF", alpha(self.opacity * 0.16))

      local list_area = Rect({x = bounds.x + padding,
        y = bounds.y + header_h + padding,
        w = bounds.w - padding * 2,
        h = math.max(0,
          bounds.h - header_h - footer_h - padding - footer_gap)})
      local row_h = dp(52)
      -- Row capacity belongs to the fully expanded panel. Deriving it from
      -- the animated height makes a settling spring briefly add a scrollbar.
      local visible = self.visible_rows
      local items = self.snapshot.playlist_items or {}
      local has_scrollbar = #items > visible
      local scrollbar_w = has_scrollbar and dp(20) or 0
      local list_bounds = Rect({x = list_area.x, y = list_area.y,
        w = list_area.w - scrollbar_w, h = list_area.h})
      playlist_state.list_bounds = list_bounds
      playlist_state.scroll_index = clamp(playlist_state.scroll_index, 0,
        math.max(0, #items - visible))
      -- The row count is based on the final panel height so it stays stable
      -- throughout the spring. Clip that fixed layout to the live list
      -- viewport so rows cannot pass through the footer while morphing.
      push_clip(list_area)
      for slot, row in ipairs(self.rows) do
        local index = playlist_state.scroll_index + slot
        local row_bounds = Rect({x = list_bounds.x,
          y = list_bounds.y + (slot - 1) * row_h,
          w = list_bounds.w, h = row_h})
        local row_fully_visible = row_bounds.y >= list_bounds.y and
          row_bounds.y2 <= list_bounds.y2
        row:update({item = slot <= visible and items[index] or nil, index = index,
          interactive = self.interactive and row_fully_visible,
          text_alpha = text_alpha,
          secondary_alpha = secondary_alpha, hover_alpha = hover_alpha,
          selected_alpha = selected_alpha})
        if slot <= visible and row.item then
          draw_node(row, ass, row_bounds)
        end
      end
      if playlist_state.drag_to then
        local slot = playlist_state.drag_to - playlist_state.scroll_index
        if slot >= 1 and slot <= visible then
          local y = list_bounds.y + (slot - 1) * row_h
          draw_rect(ass, list_bounds.x + dp(8), y, list_bounds.x2 - dp(8),
            y + dp(2), services.config.opts.accent_color, text_alpha)
        end
      end
      node.scrollbar:update({item_count = #items, visible_count = visible,
        interactive = self.interactive, opacity = self.opacity})
      if has_scrollbar then
        draw_node(node.scrollbar, ass, Rect({x = list_area.x2 - scrollbar_w,
          y = list_area.y, w = scrollbar_w, h = list_area.h}))
      end
      pop_clip()

      local footer = Rect({x = bounds.x, y = bounds.y2 - footer_h,
        w = bounds.w, h = footer_h})
      local button_size = measure_node(self.loop, footer)
      local button_gap = 0
      local button_y = footer.y + dp(5)
      local loop_x = footer.x2 - dp(5) - button_size.w
      draw_rect(ass, footer.x, footer.y, footer.x2,
        footer.y + dp(1), "#FFFFFF", alpha(self.opacity * 0.16))
      draw_node(self.shuffle, ass, Rect({x = loop_x - button_size.w - button_gap,
        y = button_y,
        w = button_size.w, h = button_size.h}))
      draw_node(self.loop, ass, Rect({x = loop_x, y = button_y,
        w = button_size.w, h = button_size.h}))
    end
    return node
  end

  local function Backdrop()
    local node = {modifier = Modifier():fillMaxWidth():fillMaxHeight():clickable({
      name = "playlist-backdrop", enabled = false,
      on_click = function() set_open(false) end
    })}
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end
    function node:draw() end
    return node
  end

  local function previous_item()
    local snapshot = state.snapshot or {}
    if snapshot.playlist_looping and (snapshot.playlist_pos or -1) <= 0 then
      mp.commandv("playlist-play-index", (snapshot.playlist_count or 1) - 1)
    else
      mp.commandv("playlist-prev", "weak")
    end
  end

  local function next_item()
    local snapshot = state.snapshot or {}
    if snapshot.playlist_looping and
      (snapshot.playlist_pos or -1) >= (snapshot.playlist_count or 0) - 1 then
      mp.commandv("playlist-play-index", 0)
    else
      mp.commandv("playlist-next", "weak")
    end
  end

  local function PlaylistControl()
    local node = {
      snapshot = {}, morph = 0, content_opacity = 0, interactive = false,
      panel_width = dp(380), panel_height = dp(460),
      trailing = trailing,
      modifier = Modifier():fillMaxWidth():height(dp(44))
    }
    node.backdrop = Backdrop()
    node.content = ExpandedContent()
    node.playlist = FooterButton("playlist-button", "playlist_play", "Playlist",
      function() set_open(not playlist_state.open) end, "open-playlist", true)
    node.previous = FooterButton("playlist-previous", "skip_previous", "Previous",
      previous_item, "playlist-prev", true)
    node.next = FooterButton("playlist-next", "skip_next", "Next", next_item,
      "playlist-next", true)

    -- previous/next move beside play/pause with prev_next_beside_play
    local function footer_buttons()
      if services.config.opts.prev_next_beside_play then return {node.playlist} end
      return {node.playlist, node.previous, node.next}
    end

    function node:update(snapshot)
      self.snapshot = snapshot
      self.morph = clamp(playlist_state.animation.value, 0, 1)
      self.controls_opacity = clamp(
        playlist_state.controls_opacity.value, 0, 1)
      if playlist_state.open then playlist_state.handoff = false end
      local content_progress = clamp((self.morph - 0.62) / 0.38, 0, 1)
      content_progress = content_progress * content_progress *
        (3 - 2 * content_progress)
      self.content_opacity = self.morph * content_progress
      self.interactive = playlist_state.open and self.morph > 0.9
      local morphing = playlist_state.open or
        playlist_state.animation:is_running() or
        playlist_state.width_animation:is_running() or
        playlist_state.height_animation:is_running()
      self.backdrop.modifier.pointer_enabled = morphing
      self.content.modifier.pointer_enabled = morphing
      self.panel_width = math.max(dp(260), math.min(dp(380), state.viewport.w - dp(24)))
      local row_h, panel_chrome = dp(52), dp(115)
      local maximum_h = math.max(panel_chrome + row_h,
        math.min(dp(520), state.viewport.h - dp(24)))
      local maximum_rows = math.max(1, math.floor((maximum_h - panel_chrome) / row_h))
      local item_count = snapshot.playlist_count or 0
      local visible_rows = math.min(math.max(1, item_count), maximum_rows)
      self.panel_height = panel_chrome + visible_rows * row_h
      local target_width =
        playlist_state.open and self.panel_width or
        dp(services.config.opts.prev_next_beside_play and 42 or 134)
      local target_height =
        playlist_state.open and self.panel_height or dp(42)
      if morphing then
        playlist_state.width_animation:set_target(target_width)
        playlist_state.height_animation:set_target(target_height)
      else
        -- Hidden geometry is not visible, so settling two springs here only
        -- burns frames during startup and after the close animation.
        playlist_state.width_animation:snap(target_width)
        playlist_state.height_animation:snap(target_height)
      end

      local count, position = snapshot.playlist_count or 0, snapshot.playlist_pos or -1
      local wraps = snapshot.playlist_looping == true
      self.playlist:update({
        icon = "playlist_play",
        transition_icon = "menu_open",
        transition_progress = self.morph,
        alpha = alpha(self.controls_opacity),
        tooltip = self.morph < 0.5 and "Playlist" or "Collapse"
      })
      self.previous:update({
        alpha = alpha(self.controls_opacity),
        enabled = count > 1 and position >= 0 and (wraps or position > 0)
      })
      self.next:update({
        alpha = alpha(self.controls_opacity),
        enabled = count > 1 and position >= 0 and (wraps or position < count - 1)
      })
      -- These are the same controls in both states, so their moving hitboxes
      -- remain live throughout the spring (including a mid-flight reversal).
      self.playlist.modifier.pointer_enabled = true
      self.previous.modifier.pointer_enabled = self.previous.enabled
      self.next.modifier.pointer_enabled = self.next.enabled
      if morphing or self.morph > 0 then
        self.content:update(snapshot, self.content_opacity, self.interactive,
          visible_rows)
      else
        self.content.modifier.pointer_enabled = false
      end
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = dp(44)}, parent)
    end

    local function control_metrics(bounds)
      local button = measure_node(node.playlist, bounds)
      local gap, padding = 0, dp(4)
      local count = #footer_buttons()
      -- a lone playlist button sits in a circle, like the play button
      local width = count == 1 and button.h + padding * 2 or
        button.w * count + gap * (count - 1) + padding * 2
      return button.w, button.h,
        Rect({x = bounds.x, y = bounds.y, w = width, h = button.h + padding * 2})
    end

    local function draw_control_buttons(ass, source, target, progress)
      local button_w, button_h = measure_node(node.playlist, source).w,
        measure_node(node.playlist, source).h
      local from_y, to_y = source.y + dp(4), target.y2 - dp(38)
      local y = from_y + (to_y - from_y) * progress
      local buttons = footer_buttons()
      for index, button in ipairs(buttons) do
        -- The pill and expanded footer share the same controls. Keep their
        -- horizontal centers fixed so opening only lifts them vertically.
        local x = #buttons == 1 and source.x + (source.w - button_w) / 2 or
          source.x + dp(4) + (index - 1) * button_w
        draw_node(button, ass, Rect({x = x, y = y, w = button_w, h = button_h}))
      end
    end

    function node:draw(ass, bounds)
      local _, _, source = control_metrics(bounds)
      local trailing_size = self.trailing and
        measure_node(self.trailing, bounds) or {w = 0, h = 0}
      local trailing_bounds = Rect({
        x = bounds.x2 - trailing_size.w,
        y = bounds.y + (bounds.h - trailing_size.h) / 2,
        w = trailing_size.w,
        h = trailing_size.h
      })
      local morphing = playlist_state.animation:is_running() or
        playlist_state.width_animation:is_running() or
        playlist_state.height_animation:is_running()
      if is_render_pass("interaction") then
        if self.morph == 0 and not playlist_state.open and
          not morphing then
          draw_control_buttons(ass, source, source, 0)
        end
        if trailing_size.w > 0 then
          draw_node(self.trailing, ass, trailing_bounds)
        end
        return
      end
      if not is_render_pass("base") then return end
      playlist_state.anchor_bounds = source
      if self.morph == 0 and not playlist_state.open and
        not morphing then
        draw_box(ass, source.x, source.y, source.x2, source.y2,
          source.h / 2, "#050708",
          alpha(self.controls_opacity * (1 - 0x58 / 255)))
        draw_control_buttons(ass, source, source, 0)
      end
      local title = self.snapshot.media_title or ""
      local title_x = bounds.x + source.w + dp(12)
      local trailing_gap = trailing_size.w > 0 and dp(12) or dp(8)
      local available = math.max(0,
        trailing_bounds.x - title_x - trailing_gap)
      title = truncate_to_width(title, available, 24)
      ui.draw_shadowed_text(ass, title_x, bounds.y + bounds.h / 2,
        title, 24, "#FFFFFF", alpha(self.controls_opacity),
        default_text_font, 4)
      if trailing_size.w > 0 then
        draw_node(self.trailing, ass, trailing_bounds)
      end
    end

    function node:draw_expanded(ass, bounds)
      local source = playlist_state.anchor_bounds or Rect({
        x = bounds.x + dp(12), y = bounds.y2 - dp(54),
        w = dp(services.config.opts.prev_next_beside_play and 42 or 134), h = dp(42)
      })
      if self.morph <= 0 and not playlist_state.open and
        not playlist_state.animation:is_running() and
        not playlist_state.width_animation:is_running() and
        not playlist_state.height_animation:is_running() then
        if not playlist_state.handoff then
          -- The modal overlay is updated one frame before the retained base
          -- layer. Keep an identical collapsed pill here for that handoff
          -- frame; the queued full render replaces it without a blank flash.
          playlist_state.handoff = true
          draw_box(ass, source.x, source.y, source.x2, source.y2,
            source.h / 2, "#050708", "58")
          draw_control_buttons(ass, source, source, 0)
        else
          playlist_state.handoff = false
          playlist_state.bounds, playlist_state.list_bounds = nil, nil
        end
        return
      end
      playlist_state.handoff = false
      draw_node(self.backdrop, ass, bounds)
      local margin = dp(12)
      local target_x = clamp(source.x, bounds.x + margin,
        bounds.x2 - margin - self.panel_width)
      local target_y = clamp(source.y2 - self.panel_height, bounds.y + margin,
        bounds.y2 - margin - self.panel_height)
      local target = Rect({x = target_x, y = target_y,
        w = self.panel_width, h = self.panel_height})
      local width_range = math.max(dp(1), target.w - source.w)
      local height_range = math.max(dp(1), target.h - source.h)
      local width_progress =
        (playlist_state.width_animation.value - source.w) / width_range
      local height_progress =
        (playlist_state.height_animation.value - source.h) / height_range
      local control_progress = clamp(math.min(width_progress, height_progress), 0, 1)
      local surface = Rect({
        x = source.x + (target.x - source.x) * width_progress,
        y = source.y + (target.y - source.y) * height_progress,
        w = playlist_state.width_animation.value,
        h = playlist_state.height_animation.value
      })
      playlist_state.bounds = surface
      -- The playlist morphs back into a persistent pill, unlike the context
      -- menu which closes into empty space. Preserve the pill's base opacity
      -- throughout the handoff so it never dims and then pops back in.
      local shell_opacity = 0.65 + self.morph * 0.27
      local top_radius = dp(21) + dp(9) * control_progress
      local bottom_radius = dp(21)
      draw_round_box(ass, surface.x, surface.y, surface.x2, surface.y2,
        top_radius, bottom_radius, "#050708", alpha(shell_opacity))
      push_clip(surface)
      draw_node(self.content, ass, surface)
      pop_clip()
      draw_control_buttons(ass, source, target, control_progress)
    end
    return node
  end

  return PlaylistControl()
end

return playlist
