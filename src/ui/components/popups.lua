local popups = {}

local function new_chapter_popup(deps)
  local pointer, chapter_state = deps.pointer, deps.state
  local opts, dp, clamp = deps.opts, deps.dp, deps.clamp
  local ass_alpha_for_opacity = deps.ass_alpha_for_opacity
  local truncate_utf8, format_time = deps.truncate_utf8, deps.format_time
  local draw_box, draw_text = deps.draw_box, deps.draw_text
  local default_text_font, render = deps.default_text_font, deps.render
  local Modifier, Rect = deps.Modifier, deps.Rect
  local apply_modifier_size, draw_node = deps.apply_modifier_size, deps.draw_node
  local mouse_in, ChapterHeader = deps.mouse_in, deps.ChapterHeader
  local update_fields = deps.update_fields
  local function ChapterRow(slot, on_selected)
    local node = {
      slot = slot,
      chapter = nil,
      chapter_index = 0,
      selected = false,
      interactive = false,
      text_alpha = "00",
      secondary_alpha = "00",
      hover_alpha = "00",
      selected_alpha = "00",
      modifier = Modifier():fillMaxWidth():height(dp(44))
    }
    node.modifier:clickable({
      name = "chapter-row-slot-" .. tostring(slot),
      enabled = false,
      on_click = function()
        if not node.chapter then return end
        mp.commandv("seek", tonumber(node.chapter.time) or 0, "absolute+exact")
        on_selected()
      end
    })
    function node:update(props)
      self.chapter = props.chapter
      self.chapter_index = props.chapter_index or 0
      self.selected = props.selected == true
      self.interactive = props.interactive == true and props.chapter ~= nil
      self.text_alpha = props.text_alpha
      self.secondary_alpha = props.secondary_alpha
      self.hover_alpha = props.hover_alpha
      self.selected_alpha = props.selected_alpha
      self.modifier.pointer_enabled = self.interactive
    end
    function node:measure(parent)
      if not self.chapter then return {w = 0, h = 0} end
      return apply_modifier_size(self.modifier, {w = 0, h = dp(44)}, parent)
    end
    function node:draw(ass, bounds)
      if not self.chapter then return end
      local hovered = self.interactive and mouse_in(bounds)
      if self.selected then
        draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
             bounds.h / 2, opts.accent_color, self.selected_alpha)
        local indicator_size = dp(6)
        draw_box(ass, bounds.x + dp(14) - indicator_size / 2,
             bounds.y + bounds.h / 2 - indicator_size / 2,
             bounds.x + dp(14) + indicator_size / 2,
             bounds.y + bounds.h / 2 + indicator_size / 2,
             indicator_size / 2,
             opts.accent_color, self.text_alpha)
      elseif hovered then
        draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
             bounds.h / 2, "#FFFFFF", self.hover_alpha)
      end
      local seek_time = tonumber(self.chapter.time) or 0
      local title_size = 24
      local title_available_w = math.max(dp(72), bounds.w - dp(44) - dp(64))
      local max_title_chars = math.max(6, math.floor(
        title_available_w / math.max(1, dp(title_size * 0.35))))
      local title = self.chapter.title
      if type(title) ~= "string" or title:match("^%s*$") then
        title = "Chapter " .. tostring(self.chapter_index)
      end
      title = truncate_utf8(title, max_title_chars)
      draw_text(ass, bounds.x + dp(self.selected and 28 or 16),
            bounds.y + bounds.h / 2,
            title, title_size, "#FFFFFF", self.text_alpha,
            default_text_font, 4)
      draw_text(ass, bounds.x2 - dp(16), bounds.y + bounds.h / 2,
            format_time(seek_time), 24,
            self.selected and opts.accent_color or "#CAC4D0",
            self.selected and self.text_alpha or self.secondary_alpha,
            default_text_font, 6)
    end
    return node
  end

  local function LazyChapterColumn(on_selected)
    local node = {
      rows = {}, items = {}, first_visible_index = 0, visible_count = 1,
      selected_index = -1, row_gap = dp(4), row_height = dp(44),
      interactive = false, text_alpha = "00", secondary_alpha = "00",
      hover_alpha = "00", selected_alpha = "00",
      modifier = Modifier():fillMaxWidth():fillMaxHeight()
    }
    for slot = 1, 16 do node.rows[slot] = ChapterRow(slot, on_selected) end
    function node:update(props)
      update_fields(self, props)
      for slot, row in ipairs(self.rows) do
        local item_index = self.first_visible_index + slot
        local chapter = slot <= self.visible_count and self.items[item_index] or nil
        row:update({
          chapter = chapter,
          chapter_index = item_index,
          selected = item_index - 1 == self.selected_index,
          interactive = self.interactive,
          text_alpha = self.text_alpha,
          secondary_alpha = self.secondary_alpha,
          hover_alpha = self.hover_alpha,
          selected_alpha = self.selected_alpha
        })
      end
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end
    function node:draw(ass, bounds)
      local stride = self.row_height + self.row_gap
      for slot = 1, math.min(self.visible_count, #self.rows) do
        local row = self.rows[slot]
        if not row.chapter then break end
        local y = bounds.y + (slot - 1) * stride
        if y + self.row_height > bounds.y2 + 0.5 then break end
        draw_node(row, ass, Rect({x = bounds.x, y = y, w = bounds.w, h = self.row_height}))
      end
    end
    return node
  end

  local function VerticalScrollbar(on_scroll)
    local node = {
      item_count = 0, visible_count = 1, scroll_index = 0,
      dragging = false,
      interactive = false, track_alpha = "00", thumb_alpha = "00",
      modifier = Modifier():fillMaxWidth():fillMaxHeight()
    }
    local function max_scroll() return math.max(0, node.item_count - node.visible_count) end
    local function metrics(bounds)
      local maximum = max_scroll()
      local thumb_h, thumb_y = bounds.h, bounds.y
      if maximum > 0 then
        thumb_h = math.max(dp(30), bounds.h * node.visible_count / node.item_count)
        thumb_y = bounds.y + (bounds.h - thumb_h) * node.scroll_index / maximum
      end
      return thumb_h, thumb_y
    end
    local function update_from_mouse(box)
      local maximum = max_scroll()
      if maximum <= 0 then return end
      local thumb_h = metrics(box)
      local travel = math.max(1, box.h - thumb_h)
      local ratio = clamp((pointer.y - box.y1 - thumb_h / 2) / travel, 0, 1)
      on_scroll(math.floor(ratio * maximum + 0.5))
    end
    node.modifier:pointerArea({
      name = "chapter-dialog-scrollbar",
      enabled = false,
      on_press = function(box)
        node.dragging = true
        update_from_mouse(box)
      end,
      on_move = function(box)
        if node.dragging then update_from_mouse(box) end
      end,
      on_release = function(box)
        update_from_mouse(box)
        node.dragging = false
      end
    })
    function node:update(props)
      update_fields(self, props)
      self.modifier.pointer_enabled = self.interactive and max_scroll() > 0
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end
    function node:draw(ass, bounds)
      local track_w = dp(4)
      local x1 = bounds.x + (bounds.w - track_w) / 2
      local thumb_h, thumb_y = metrics(bounds)
      draw_box(ass, x1, bounds.y, x1 + track_w, bounds.y2,
           track_w / 2, "#FFFFFF", self.track_alpha)
      draw_box(ass, x1, thumb_y, x1 + track_w, thumb_y + thumb_h,
           track_w / 2, "#FFFFFF", self.thumb_alpha)
    end
    return node
  end

  local function ChapterList(on_selected)
    local node = {
      chapters = {}, interactive = false, text_alpha = "00",
      secondary_alpha = "00", hover_alpha = "00", selected_alpha = "00",
      scrollbar_track_alpha = "00", scrollbar_thumb_alpha = "00",
      modifier = Modifier():fillMaxWidth():fillMaxHeight()
    }
    node.column = LazyChapterColumn(on_selected)
    node.scrollbar = VerticalScrollbar(function(index)
      chapter_state.scroll_index = index
      render()
    end)
    function node:update(props)
      update_fields(self, props)
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end
    function node:draw(ass, bounds)
      local row_height, row_gap = dp(44), dp(4)
      local visible_count = math.max(1, math.floor((bounds.h + row_gap) / (row_height + row_gap)))
      local max_scroll = math.max(0, #self.chapters - visible_count)
      chapter_state.scroll_index = clamp(chapter_state.scroll_index, 0, max_scroll)
      local horizontal_padding = dp(8)
      local scrollbar_touch_w = dp(24)
      local list_x = bounds.x + horizontal_padding
      local list_w = math.max(dp(80), bounds.w - horizontal_padding * 2)
      self.column:update({
        items = self.chapters,
        first_visible_index = chapter_state.scroll_index,
        visible_count = visible_count,
        selected_index = self.selected_index or -1,
        row_height = row_height,
        row_gap = row_gap,
        interactive = self.interactive,
        text_alpha = self.text_alpha,
        secondary_alpha = self.secondary_alpha,
        hover_alpha = self.hover_alpha,
        selected_alpha = self.selected_alpha
      })
      self.scrollbar:update({
        item_count = #self.chapters,
        visible_count = visible_count,
        scroll_index = chapter_state.scroll_index,
        interactive = self.interactive,
        track_alpha = self.scrollbar_track_alpha,
        thumb_alpha = self.scrollbar_thumb_alpha
      })
      draw_node(self.column, ass, Rect({x = list_x, y = bounds.y, w = list_w, h = bounds.h}))
      -- Draw the scrollbar after the rows so it stays above the right padding.
      if max_scroll > 0 then
        draw_node(self.scrollbar, ass, Rect({
          x = bounds.x2 - scrollbar_touch_w,
          y = bounds.y, w = scrollbar_touch_w, h = bounds.h
        }))
      end
    end
    return node
  end

  local function ChapterPopup(on_close)
    local node = {
      width = dp(320), height = dp(400), chapters = {}, interactive = false,
      panel_alpha = "00", text_alpha = "00", secondary_alpha = "00",
      hover_alpha = "00", selected_alpha = "00",
      scrollbar_track_alpha = "00", scrollbar_thumb_alpha = "00",
      modifier = Modifier():clickable({
        name = "chapter-dialog-panel", enabled = false, on_click = function() end
      })
    }
    node.header = ChapterHeader(on_close)
    node.list = ChapterList(on_close)
    function node:update(props)
      update_fields(self, props)
      self.modifier.fixed_width = self.width
      self.modifier.fixed_height = self.height
      self.modifier.pointer_enabled = self.interactive
      local text_opacity = 1 - (tonumber(self.text_alpha, 16) or 255) / 255
      self.header:update({
        alpha = self.text_alpha,
        title_alpha = ass_alpha_for_opacity(text_opacity * 0.70),
        hover_alpha = self.hover_alpha,
        interactive = self.interactive
      })
      self.list:update({
        chapters = self.chapters,
        interactive = self.interactive,
        text_alpha = self.text_alpha,
        secondary_alpha = self.secondary_alpha,
        hover_alpha = self.hover_alpha,
        selected_alpha = self.selected_alpha,
        scrollbar_track_alpha = self.scrollbar_track_alpha,
        scrollbar_thumb_alpha = self.scrollbar_thumb_alpha
      })
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = self.width, h = self.height}, parent)
    end
    function node:draw(ass, bounds)
      draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
           dp(30), "#050708", self.panel_alpha)
      local header_h = dp(56)
      draw_node(self.header, ass, Rect({x = bounds.x, y = bounds.y, w = bounds.w, h = header_h}))
      draw_node(self.list, ass, Rect({
        x = bounds.x, y = bounds.y + header_h + dp(8),
        w = bounds.w,
        h = math.max(0, bounds.h - header_h - dp(16))
      }))
    end
    return node
  end


  return {ChapterPopup = ChapterPopup, VerticalScrollbar = VerticalScrollbar}
end

local function new_track_popup(deps)
  local opts, dp, clamp = deps.opts, deps.dp, deps.clamp
  local truncate_utf8 = deps.truncate_utf8
  local draw_box, draw_rect = deps.draw_box, deps.draw_rect
  local draw_icon = deps.draw_icon
  local draw_text = deps.draw_text
  local draw_loading_shape_morph = deps.draw_loading_shape_morph
  local default_text_font, render = deps.default_text_font, deps.render
  local Modifier, Rect = deps.Modifier, deps.Rect
  local apply_modifier_size, draw_node = deps.apply_modifier_size, deps.draw_node
  local mouse_in, ChapterHeader = deps.mouse_in, deps.ChapterHeader
  local VerticalScrollbar, update_fields = deps.VerticalScrollbar, deps.update_fields
  local subtitle_state, audio_state = deps.subtitle_state, deps.audio_state
  local function TrackRow(slot, on_selected, name_prefix)
    local node = {
      item = nil, active = false, interactive = false,
      text_alpha = "00", secondary_alpha = "00",
      hover_alpha = "00", selected_alpha = "00",
      modifier = Modifier():fillMaxWidth():height(dp(44))
    }
    node.modifier:clickable({
      name = name_prefix .. "-row-slot-" .. tostring(slot), enabled = false,
      on_click = function()
        if node.item then on_selected(node.item) end
      end
    })
    function node:update(props)
      update_fields(self, props)
      self.modifier.pointer_enabled = self.interactive and self.item ~= nil and
        not self.item.separator
    end
    function node:measure(parent)
      if not self.item then return {w = 0, h = 0} end
      return apply_modifier_size(self.modifier, {w = 0, h = dp(44)}, parent)
    end
    function node:draw(ass, bounds)
      if not self.item then return end
      if self.item.separator then
        local center_y = bounds.y + bounds.h / 2
        local label = self.item.label or "Images"
        local line_gap, label_width = dp(10), dp(82)
        draw_rect(ass, bounds.x + dp(12), center_y,
          bounds.x + (bounds.w - label_width) / 2 - line_gap, center_y + dp(1),
          "#CAC4D0", self.secondary_alpha)
        draw_text(ass, bounds.x + bounds.w / 2, center_y,
          label, 22, "#CAC4D0", self.secondary_alpha, default_text_font)
        draw_rect(ass, bounds.x + (bounds.w + label_width) / 2 + line_gap,
          center_y, bounds.x2 - dp(12), center_y + dp(1),
          "#CAC4D0", self.secondary_alpha)
        return
      end
      local hovered = self.interactive and mouse_in(bounds)
      if self.active or hovered then
        draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
          bounds.h / 2, self.active and opts.accent_color or "#FFFFFF",
          self.active and self.selected_alpha or self.hover_alpha)
      end
      if self.active then
        local dot = dp(6)
        draw_box(ass, bounds.x + dp(14) - dot / 2,
          bounds.y + bounds.h / 2 - dot / 2,
          bounds.x + dp(14) + dot / 2,
          bounds.y + bounds.h / 2 + dot / 2, dot / 2,
          opts.accent_color, self.text_alpha)
      end
      local text_x = bounds.x + dp(self.active and 28 or 16)
      local has_details = type(self.item.details) == "string" and
        self.item.details ~= ""
      draw_text(ass, text_x,
        bounds.y + bounds.h / 2 - (has_details and dp(7) or 0),
        truncate_utf8(self.item.label, math.max(8, math.floor(bounds.w / dp(9)))),
        has_details and 20 or 24, "#FFFFFF", self.text_alpha,
        default_text_font, 4)
      if has_details then
        draw_text(ass, text_x, bounds.y + bounds.h / 2 + dp(9),
          truncate_utf8(self.item.details,
            math.max(12, math.floor(bounds.w / dp(7)))),
          17, "#CAC4D0", self.secondary_alpha, default_text_font, 4)
      end
      if self.item.loading then
        draw_loading_shape_morph(ass, bounds.x2 - dp(20),
          bounds.y + bounds.h / 2, dp(22))
      elseif self.item.language and not has_details then
        draw_text(ass, bounds.x2 - dp(16), bounds.y + bounds.h / 2,
          self.item.language, 24,
          self.active and opts.accent_color or "#CAC4D0",
          self.active and self.text_alpha or self.secondary_alpha,
          default_text_font, 6)
      end
    end
    return node
  end

  local function TrackFooterButton(name, label, icon, on_click)
    local node = {
      label = label, interactive = false, text_alpha = "00", hover_alpha = "00",
      modifier = Modifier():fillMaxWidth():height(dp(44)):clickable({
        name = name, enabled = false, on_click = on_click
      })
    }
    function node:update(props)
      update_fields(self, props)
      self.modifier.pointer_enabled = self.interactive
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = parent.w, h = dp(44)}, parent)
    end
    function node:draw(ass, bounds)
      if self.interactive and mouse_in(bounds) then
        draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
          bounds.h / 2, "#FFFFFF", self.hover_alpha)
      end
      local center_x = bounds.x + bounds.w / 2
      draw_icon(ass, center_x - dp(26), bounds.y + bounds.h / 2,
        icon, "#FFFFFF", 24, self.text_alpha)
      draw_text(ass, center_x + dp(10), bounds.y + bounds.h / 2,
        self.label, 22, "#FFFFFF", self.text_alpha, default_text_font)
    end
    return node
  end

  local function TrackPopup(on_close, config)
    local node = {
      width = dp(360), height = dp(300), items = {}, active_id = 0,
      layout_height = nil,
      interactive = false, panel_alpha = "00", text_alpha = "00",
      secondary_alpha = "00", hover_alpha = "00", selected_alpha = "00",
      modifier = Modifier():clickable({
        name = config.name .. "-panel", enabled = false, on_click = function() end
      })
    }
    node.header = ChapterHeader(on_close, config.title, config.action_icon,
      config.right_action)
    if config.footer then
      node.footer = TrackFooterButton(config.name .. "-footer",
        config.footer.label, config.footer.icon or "add", config.footer.on_click)
    end
    if config.secondary_footer then
      node.secondary_footer = TrackFooterButton(config.name .. "-secondary-footer",
        config.secondary_footer.label, config.secondary_footer.icon or "link",
        config.secondary_footer.on_click)
    end
    node.rows = {}
    node.visible_count = 1
    node.max_scroll = 0
    node.scrollbar = VerticalScrollbar(function(index)
      config.state.scroll_index = index
      render()
    end)
    local function select(item)
      local should_close = config.on_select(item)
      if should_close ~= false then on_close() end
    end
    for slot = 1, 16 do
      node.rows[slot] = TrackRow(slot, select, config.name)
    end
    function node:update(props)
      update_fields(self, props)
      self.modifier.fixed_width, self.modifier.fixed_height = self.width, self.height
      self.modifier.pointer_enabled = self.interactive
      self.header:update({alpha = self.text_alpha, hover_alpha = self.hover_alpha,
        interactive = self.interactive})
      local list_height = self.layout_height or self.height
      local footer_height = self.footer and dp(48) or 0
      local visible_count = math.max(1,
        math.floor((list_height - dp(68) - footer_height) / dp(48)))
      local max_scroll = math.max(0, #self.items - visible_count)
      self.visible_count, self.max_scroll = visible_count, max_scroll
      config.state.scroll_index = clamp(config.state.scroll_index, 0, max_scroll)
      for slot, row in ipairs(self.rows) do
        local item = slot <= visible_count and
          self.items[config.state.scroll_index + slot] or nil
        local active = item and (config.is_selected and config.is_selected(item) or
          item.id == self.active_id)
        row:update({item = item, active = active,
          interactive = self.interactive, text_alpha = self.text_alpha,
          secondary_alpha = self.secondary_alpha, hover_alpha = self.hover_alpha,
          selected_alpha = self.selected_alpha})
      end
      self.scrollbar:update({
        item_count = #self.items,
        visible_count = visible_count,
        scroll_index = config.state.scroll_index,
        interactive = self.interactive,
        track_alpha = self.scrollbar_track_alpha,
        thumb_alpha = self.scrollbar_thumb_alpha
      })
      if self.footer then
        self.footer:update({interactive = self.interactive,
          text_alpha = self.text_alpha, hover_alpha = self.hover_alpha})
      end
      if self.secondary_footer then
        self.secondary_footer:update({interactive = self.interactive,
          text_alpha = self.text_alpha, hover_alpha = self.hover_alpha})
      end
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = self.width, h = self.height}, parent)
    end
    function node:draw(ass, bounds)
      draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
        dp(30), "#050708", self.panel_alpha)
      local header_h = dp(56)
      draw_node(self.header, ass, Rect({x = bounds.x, y = bounds.y,
        w = bounds.w, h = header_h}))
      local layout_height = self.layout_height or bounds.h
      local footer_height = self.footer and dp(48) or 0
      local list = Rect({x = bounds.x + dp(8), y = bounds.y + header_h + dp(8),
        w = bounds.w - dp(16),
        h = layout_height - header_h - dp(16) - footer_height})
      for slot, row in ipairs(self.rows) do
        if not row.item then break end
        local y = list.y + (slot - 1) * dp(48)
        if y + dp(44) > list.y2 then break end
        draw_node(row, ass, Rect({x = list.x, y = y, w = list.w, h = dp(44)}))
      end
      if self.max_scroll > 0 then
        draw_node(self.scrollbar, ass, Rect({
          x = bounds.x2 - dp(20), y = list.y,
          w = dp(24), h = list.h
        }))
      end
      if self.footer then
        local footer_x = bounds.x + dp(8)
        local footer_w = bounds.w - dp(16)
        if self.secondary_footer then footer_w = (footer_w - dp(8)) / 2 end
        local footer_y = bounds.y + layout_height - dp(52)
        draw_node(self.footer, ass, Rect({x = footer_x, y = footer_y,
          w = footer_w, h = dp(44)}))
        if self.secondary_footer then
          draw_node(self.secondary_footer, ass, Rect({
            x = footer_x + footer_w + dp(8), y = footer_y,
            w = footer_w, h = dp(44)
          }))
        end
      end
    end
    return node
  end

  local function SubtitlePopup(on_close)
    return TrackPopup(on_close, {
      name = "subtitle-dialog", title = "Subtitles", state = subtitle_state,
      on_select = function(item)
        if item.id == 0 then
          mp.set_property("sid", "no")
        else
          mp.set_property_number("sid", tonumber(item.id))
          mp.set_property_native("sub-visibility", true)
        end
      end
    })
  end

  local function AudioPopup(on_close)
    return TrackPopup(on_close, {
      name = "audio-dialog", title = "Audio", state = audio_state,
      on_select = function(item)
        if item.id == 0 then mp.set_property("aid", "no")
        else mp.set_property_number("aid", tonumber(item.id)) end
      end
    })
  end


  return {TrackPopup = TrackPopup, SubtitlePopup = SubtitlePopup, AudioPopup = AudioPopup}
end

function popups.new(services)
  local state, ui = services.state, services.ui
  local player, navigation = services.player, services.navigation
  local pointer, input, viewport = state.pointer, state.input, state.viewport
  local chapter_state, subtitle_state = state.chapter, state.subtitle
  local audio_state, settings_state, ytdl_state = state.audio, state.settings, state.ytdl
  local opts, msg, utils = services.config.opts, services.platform.msg, services.platform.utils
  local dp, clamp, smooth_step = ui.dp, ui.clamp, ui.smooth_step
  local ass_alpha_for_opacity = ui.alpha
  local truncate_utf8, format_time = ui.truncate_utf8, ui.format_time
  local draw_box, draw_rect, draw_icon = ui.draw_box, ui.draw_rect, ui.draw_icon
  local draw_text, draw_loading_shape_morph = ui.draw_text, ui.draw_loading
  local default_text_font, render = ui.default_text_font, services.effects.render
  local Modifier, Rect = ui.Modifier, ui.Rect
  local apply_modifier_size, measure_node = ui.apply_modifier_size, ui.measure_node
  local draw_node, mouse_in = ui.draw_node, ui.mouse_in
  local set_settings_page = navigation.set_settings_page
  local select_stream_quality = player.select_stream_quality
  local open_subtitle_file_picker = player.open_subtitle_file_picker
  local open_subtitle_link_picker = player.open_subtitle_link_picker
  local attach_ytdl_caption = player.attach_ytdl_caption
  local set_chapter_dialog_open = navigation.set_chapter_open
  local set_subtitle_dialog_open = navigation.set_subtitle_open
  local set_audio_dialog_open = navigation.set_audio_open
  local set_settings_dialog_open = navigation.set_settings_open

  local function update_fields(target, props)
    for key, value in pairs(props) do target[key] = value end
  end

  local function PointerLayer(args)
    local node = {modifier = Modifier():fillMaxWidth():fillMaxHeight()}
    node.modifier:clickable({
      name = args.name, enabled = args.enabled, on_click = args.on_click
    })
    function node:set_enabled(enabled) self.modifier.pointer_enabled = enabled end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end
    function node:draw() end
    return node
  end

  local function PopupHost(args)
    local node = {modifier = Modifier():fillMaxWidth():fillMaxHeight()}
    node.backdrop = PointerLayer({
      name = args.name .. "-backdrop", enabled = false, on_click = args.on_close
    })
    node.popup = args.popup
    function node:update(snapshot)
      local opacity = smooth_step(clamp(args.state.animation.value, 0, 1))
      local interactive = args.state.open
      self.backdrop:set_enabled(args.state.open or opacity > 0)
      args.update_popup(self.popup, snapshot, opacity, interactive)
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end
    function node:draw(ass, bounds)
      local opacity = smooth_step(clamp(args.state.animation.value, 0, 1))
      if opacity <= 0 and not args.state.open then return end
      draw_node(self.backdrop, ass, bounds)
      local anchor = input.hitboxes[args.anchor_name]
      local popup_size = measure_node(self.popup, bounds)
      local margin = dp(12)
      local desired_x = anchor and
        (anchor.x2 - popup_size.w + (args.anchor_offset_x or 0)) or
        (bounds.x + (bounds.w - popup_size.w) / 2)
      local desired_y = anchor and
        (anchor.y1 - popup_size.h - dp(8)) or
        (bounds.y + (bounds.h - popup_size.h) / 2)
      local x = clamp(desired_x, bounds.x + margin,
        bounds.x2 - margin - popup_size.w)
      local y = clamp(desired_y, bounds.y + margin,
        bounds.y2 - margin - popup_size.h)
      local popup_bounds = Rect({x = x, y = y, w = popup_size.w, h = popup_size.h})
      args.state.bounds = popup_bounds
      draw_node(self.popup, ass, popup_bounds)
    end
    return node
  end

  local function popup_visual_props(opacity, interactive)
    return {
      opacity = opacity, interactive = interactive,
      alpha = ass_alpha_for_opacity(opacity),
      text_alpha = ass_alpha_for_opacity(opacity),
      secondary_alpha = ass_alpha_for_opacity(opacity * 0.72),
      hover_alpha = ass_alpha_for_opacity(opacity * 0.18),
      selected_alpha = ass_alpha_for_opacity(opacity * 0.33)
    }
  end

  local function ChapterCloseButton(args)
    local node = {
      alpha = "00",
      hover_alpha = "E6",
      enabled = false,
      on_click = args.on_click,
      icon = args.icon or "close",
      modifier = Modifier():width(dp(36)):height(dp(36))
    }
    node.modifier:clickable({
      name = args.name or "chapter-dialog-close",
      enabled = false,
      on_click = function() if node.enabled and node.on_click then node.on_click() end end
    })
    function node:update(props)
      self.alpha = props.alpha
      self.hover_alpha = props.hover_alpha
      self.enabled = props.enabled
      self.modifier.pointer_enabled = props.enabled
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
    end
    function node:draw(ass, bounds)
      if self.enabled and mouse_in(bounds) then
        draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
             bounds.h / 2, "#FFFFFF", self.hover_alpha)
      end
      draw_icon(ass, bounds.x + bounds.w / 2, bounds.y + bounds.h / 2,
           self.icon, "#FFFFFF", 24, self.alpha)
    end
    return node
  end

  local function ChapterHeader(on_close, title, action_icon, right_action)
    local node = {
      alpha = "00", title_alpha = "00", hover_alpha = "E6", interactive = false,
      title = title or "Chapters",
      action_on_left = action_icon == "arrow_back",
      modifier = Modifier():fillMaxWidth():height(dp(56))
    }
    node.close = ChapterCloseButton({on_click = on_close, icon = action_icon})
    if right_action then
      node.action = ChapterCloseButton({
        name = right_action.name,
        on_click = right_action.on_click,
        icon = right_action.icon
      })
    end
    function node:update(props)
      self.alpha = props.alpha
      self.title_alpha = props.title_alpha or props.alpha
      self.hover_alpha = props.hover_alpha
      self.interactive = props.interactive
      self.close:update({alpha = props.alpha, hover_alpha = props.hover_alpha,
        enabled = props.interactive})
      if self.action then
        self.action:update({alpha = props.alpha, hover_alpha = props.hover_alpha,
          enabled = props.interactive})
      end
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = dp(56)}, parent)
    end
    function node:draw(ass, bounds)
      local title_x = bounds.x + dp(self.action_on_left and 50 or 22)
      draw_text(ass, title_x, bounds.y + bounds.h / 2,
            self.title, 24, "#FFFFFF", self.title_alpha, default_text_font, 4)
      local close_size = dp(36)
      draw_node(self.close, ass, Rect({
        x = self.action_on_left and (bounds.x + dp(6)) or
          (bounds.x2 - dp(12) - close_size),
        y = bounds.y + (bounds.h - close_size) / 2,
        w = close_size,
        h = close_size
      }))
      if self.action then
        draw_node(self.action, ass, Rect({
          x = bounds.x2 - dp(12) - close_size,
          y = bounds.y + (bounds.h - close_size) / 2,
          w = close_size,
          h = close_size
        }))
      end
      if self.action_on_left then
        local header_opacity = 1 - (tonumber(self.alpha, 16) or 255) / 255
        draw_rect(ass, bounds.x, bounds.y2 - dp(1), bounds.x2, bounds.y2,
          "#FFFFFF", ass_alpha_for_opacity(header_opacity * 0.18))
      end
    end
    return node
  end

  local chapter_widgets = new_chapter_popup({
    pointer = pointer, state = chapter_state, opts = opts, dp = dp, clamp = clamp,
    ass_alpha_for_opacity = ass_alpha_for_opacity,
    truncate_utf8 = truncate_utf8, format_time = format_time,
    draw_box = draw_box, draw_text = draw_text, default_text_font = default_text_font,
    render = render, Modifier = Modifier, Rect = Rect,
    apply_modifier_size = apply_modifier_size, draw_node = draw_node,
    mouse_in = mouse_in, ChapterHeader = ChapterHeader,
    update_fields = update_fields
  })
  local ChapterPopup = chapter_widgets.ChapterPopup
  local VerticalScrollbar = chapter_widgets.VerticalScrollbar

  local track_popups = new_track_popup({
    opts = opts, dp = dp, clamp = clamp, truncate_utf8 = truncate_utf8,
    draw_box = draw_box, draw_rect = draw_rect, draw_icon = draw_icon,
    draw_text = draw_text,
    draw_loading_shape_morph = draw_loading_shape_morph,
    default_text_font = default_text_font, render = render,
    Modifier = Modifier, Rect = Rect, apply_modifier_size = apply_modifier_size,
    draw_node = draw_node, mouse_in = mouse_in, ChapterHeader = ChapterHeader,
    VerticalScrollbar = VerticalScrollbar, update_fields = update_fields,
    subtitle_state = subtitle_state, audio_state = audio_state
  })
  local TrackPopup = track_popups.TrackPopup
  local SubtitlePopup, AudioPopup = track_popups.SubtitlePopup, track_popups.AudioPopup

  local function SettingsActionRow(name, icon, on_click)
    local node = {
      icon = icon, label = "", value = "", loading = false,
      interactive = false, text_alpha = "00",
      secondary_alpha = "00", hover_alpha = "00",
      modifier = Modifier():fillMaxWidth():height(dp(52)):clickable({
        name = name, enabled = false, on_click = on_click
      })
    }
    function node:update(props)
      update_fields(self, props)
      self.modifier.pointer_enabled = self.interactive
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = 0, h = dp(52)}, parent)
    end
    function node:draw(ass, bounds)
      if self.interactive and mouse_in(bounds) then
        draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
          bounds.h / 2, "#FFFFFF", self.hover_alpha)
      end
      draw_icon(ass, bounds.x + dp(28), bounds.y + bounds.h / 2,
        self.icon, "#FFFFFF", 24, self.text_alpha)
      draw_text(ass, bounds.x + dp(52), bounds.y + bounds.h / 2,
        self.label, 22, "#FFFFFF", self.text_alpha, default_text_font, 4)
      if self.loading then
        draw_loading_shape_morph(ass, bounds.x2 - dp(24),
          bounds.y + bounds.h / 2, dp(22))
      else
        draw_text(ass, bounds.x2 - dp(16), bounds.y + bounds.h / 2,
          truncate_utf8(self.value, self.max_value_chars or 24),
          20, "#CAC4D0", self.secondary_alpha, default_text_font, 6)
      end
    end
    return node
  end

  local function SpeedPreset(value)
    local node = {
      value = value, speed = 1, interactive = false, text_alpha = "00",
      hover_alpha = "00", selected_alpha = "00",
      modifier = Modifier():width(dp(62)):height(dp(38)):clickable({
        name = "speed-preset-" .. tostring(value), enabled = false,
        on_click = function() mp.set_property_number("speed", value) end
      })
    }
    function node:update(props)
      update_fields(self, props)
      self.modifier.pointer_enabled = self.interactive
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = dp(62), h = dp(38)}, parent)
    end
    function node:draw(ass, bounds)
      local selected = math.abs(self.speed - self.value) < 0.01
      local alpha = selected and self.selected_alpha or
        (self.interactive and mouse_in(bounds) and self.hover_alpha or "D8")
      draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
        bounds.h / 2, selected and opts.accent_color or "#FFFFFF", alpha)
      draw_text(ass, bounds.x + bounds.w / 2, bounds.y + bounds.h / 2,
        string.format("%gx", self.value), 22, "#FFFFFF", self.text_alpha,
        default_text_font)
    end
    return node
  end

  local function SpeedPopup(on_back)
    local node = {
      width = dp(420), height = dp(190), speed = 1, interactive = false,
      panel_alpha = "00", text_alpha = "00", hover_alpha = "00",
      selected_alpha = "00", modifier = Modifier():clickable({
        name = "speed-dialog-panel", enabled = false, on_click = function() end
      })
    }
    node.header = ChapterHeader(on_back, "Playback Speed", "arrow_back")
    node.slider = {dragging = false, modifier = Modifier():pointerArea({
      name = "playback-speed-slider", enabled = false,
      on_press = function(box)
        node.slider.dragging = true
        mp.set_property_number("speed", 0.25 +
          clamp((pointer.x - box.x1) / box.w, 0, 1) * 2.75)
      end,
      on_move = function(box)
        mp.set_property_number("speed", 0.25 +
          clamp((pointer.x - box.x1) / box.w, 0, 1) * 2.75)
      end,
      on_release = function()
        node.slider.dragging = false
      end
    })}
    function node.slider:measure(parent)
      return apply_modifier_size(self.modifier, {w = parent.w, h = dp(36)}, parent)
    end
    function node.slider:draw(ass, bounds)
      local track_y, track_h = bounds.y + bounds.h / 2, dp(4)
      local ratio = clamp((node.speed - 0.25) / 2.75, 0, 1)
      local cx = bounds.x + bounds.w * ratio
      local handle_w = node.slider.dragging and dp(2) or track_h
      local gap = dp(4)
      local gap_left, gap_right = cx - handle_w / 2 - gap,
        cx + handle_w / 2 + gap
      if gap_left > bounds.x then
        draw_rect(ass, bounds.x, track_y - track_h / 2, gap_left,
          track_y + track_h / 2, opts.accent_color, node.text_alpha)
      end
      if gap_right < bounds.x2 then
        draw_rect(ass, gap_right, track_y - track_h / 2, bounds.x2,
          track_y + track_h / 2, "#282828", "99")
      end
      local hovering = mouse_in(bounds)
      local handle_h = dp(hovering and 24 or 22)
      draw_box(ass, cx - handle_w / 2, track_y - handle_h / 2,
        cx + handle_w / 2, track_y + handle_h / 2, handle_w / 2,
        opts.accent_color, node.text_alpha)
    end
    node.presets = {}
    for _, value in ipairs({0.5, 1, 1.5, 2}) do
      node.presets[#node.presets + 1] = SpeedPreset(value)
    end
    function node:update(props)
      update_fields(self, props)
      self.modifier.fixed_width, self.modifier.fixed_height = self.width, self.height
      self.modifier.pointer_enabled = self.interactive
      self.slider.modifier.pointer_enabled = self.interactive
      self.header:update({alpha = self.text_alpha, hover_alpha = self.hover_alpha,
        interactive = self.interactive})
      for _, preset in ipairs(self.presets) do
        preset:update({speed = self.speed, interactive = self.interactive,
          text_alpha = self.text_alpha, hover_alpha = self.hover_alpha,
          selected_alpha = self.selected_alpha})
      end
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = self.width, h = self.height}, parent)
    end
    function node:draw(ass, bounds)
      draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
        dp(30), "#050708", self.panel_alpha)
      draw_node(self.header, ass, Rect({x = bounds.x, y = bounds.y, w = bounds.w, h = dp(56)}))
      draw_text(ass, bounds.x + bounds.w / 2, bounds.y + dp(82),
        string.format("%.2fx", self.speed), 24, "#FFFFFF", self.text_alpha,
        default_text_font)
      draw_node(self.slider, ass, Rect({x = bounds.x + dp(24), y = bounds.y + dp(98),
        w = bounds.w - dp(48), h = dp(36)}))
      local gap, pill_w = dp(8), dp(62)
      local total_w = #self.presets * pill_w + (#self.presets - 1) * gap
      local x = bounds.x + (bounds.w - total_w) / 2
      for _, preset in ipairs(self.presets) do
        draw_node(preset, ass, Rect({x = x, y = bounds.y + dp(138),
          w = pill_w, h = dp(38)}))
        x = x + pill_w + gap
      end
    end
    return node
  end

  local function selected_track_label(items, active_id, fallback)
    for _, item in ipairs(items or {}) do
      if item.id == active_id then return item.label end
    end
    return fallback
  end

  local function open_image_track(item)
    local source = mp.get_property("path")
    if not source or source == "" then return end
    if not source:match("^%a[%w+.-]*://") and
      not source:match("^[/\\]") and not source:match("^%a:[/\\]") then
      source = utils.join_path(mp.get_property("working-directory") or ".", source)
    end

    -- Sandboxed image viewers (Flatpak/Snap in particular) have a private /tmp,
    -- so a host-side /tmp path can disappear from the viewer's point of view.
    -- The user's cache directory is visible through the desktop file portal.
    local temp_dir = os.getenv("XDG_CACHE_HOME")
    if not temp_dir or temp_dir == "" then
      local home = os.getenv("HOME") or mp.get_property("working-directory") or "."
      temp_dir = utils.join_path(home, ".cache")
    end
    temp_dir = utils.join_path(temp_dir, "mpv")
    temp_dir = utils.join_path(temp_dir, "material-osc")
    temp_dir = utils.join_path(temp_dir, "thumbnails")
    local mkdir_result = mp.command_native({
      name = "subprocess", playback_only = false,
      args = {"mkdir", "-p", temp_dir}, capture_stderr = true
    })
    if not mkdir_result or mkdir_result.status ~= 0 then
      msg.error("Could not create image thumbnail directory: " .. temp_dir)
      return
    end
    local video_title = mp.get_property("media-title") or "video"
    video_title = video_title:gsub("[/\\:*?\"<>|%c]", "_")
      :gsub("^%s+", ""):gsub("%s+$", "")
    if video_title == "" then video_title = "video" end
    local output = utils.join_path(temp_dir, string.format(
      "%s-%s.png", video_title, tostring(item.id)))
    local video_index = tonumber(item.video_index)
    if video_index == nil then
      msg.error("Cannot open image track: video stream index is unavailable")
      return
    end

    mp.command_native_async({
      name = "subprocess", playback_only = false,
      capture_stderr = true,
      args = {"ffmpeg", "-v", "error", "-y", "-i", source,
        "-map", "0:v:" .. tostring(video_index), "-frames:v", "1",
        "-f", "image2", output}
    }, function(success, result)
      if not success or not result or result.status ~= 0 then
        msg.error("Could not extract image track: " ..
          tostring(result and result.stderr or "unknown subprocess error"))
        return
      end
      local info = utils.file_info(output)
      if not info or not info.is_file or (tonumber(info.size) or 0) <= 0 then
        msg.error("FFmpeg finished without creating the image: " .. output)
        return
      end
      local os_name = jit and jit.os or ""
      local args
      if os_name == "Windows" then
        args = {"cmd", "/c", "start", "", output}
      elseif os_name == "OSX" then
        args = {"open", output}
      else
        args = {"xdg-open", output}
      end
      mp.command_native_async({name = "subprocess", args = args,
        playback_only = false}, function(open_success, open_result)
        if not open_success or not open_result or open_result.status ~= 0 then
          msg.error("Could not launch the system image viewer")
        end
      end)
    end)
  end

  local function SubtitleAdjustRow(name, label, on_decrease, on_increase)
    local node = {
      label = label, value = "", interactive = false,
      text_alpha = "00", secondary_alpha = "00", hover_alpha = "00",
      modifier = Modifier():fillMaxWidth():height(dp(44))
    }
    local function button(suffix, text, on_click)
      local item = {text = text, modifier = Modifier():width(dp(34)):height(dp(34)):clickable({
        name = name .. "-" .. suffix, enabled = false, on_click = on_click
      })}
      function item:measure(parent)
        return apply_modifier_size(self.modifier, {w = dp(34), h = dp(34)}, parent)
      end
      function item:draw(ass, bounds)
        if node.interactive and mouse_in(bounds) then
          draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
            bounds.h / 2, "#FFFFFF", node.hover_alpha)
        end
        draw_text(ass, bounds.x + bounds.w / 2, bounds.y + bounds.h / 2,
          self.text, 26, "#FFFFFF", node.text_alpha, default_text_font)
      end
      return item
    end
    node.decrease = button("decrease", "−", on_decrease)
    node.increase = button("increase", "+", on_increase)
    function node:update(props)
      update_fields(self, props)
      self.decrease.modifier.pointer_enabled = self.interactive
      self.increase.modifier.pointer_enabled = self.interactive
    end
    function node:measure(parent) return {w = parent.w, h = dp(44)} end
    function node:draw(ass, bounds)
      draw_text(ass, bounds.x + dp(16), bounds.y + bounds.h / 2,
        self.label, 21, "#FFFFFF", self.text_alpha, default_text_font, 4)
      local plus = Rect({x = bounds.x2 - dp(42), y = bounds.y + dp(5), w = dp(34), h = dp(34)})
      local minus = Rect({x = plus.x - dp(42), y = plus.y, w = dp(34), h = dp(34)})
      draw_text(ass, minus.x - dp(8), bounds.y + bounds.h / 2,
        self.value, 19, "#CAC4D0", self.secondary_alpha, default_text_font, 6)
      draw_node(self.decrease, ass, minus)
      draw_node(self.increase, ass, plus)
    end
    return node
  end

  local subtitle_colors = {
    {name = "White", value = "#FFFFFFFF"},
    {name = "Yellow", value = "#FFFFFF00"},
    {name = "Cyan", value = "#FF00FFFF"},
    {name = "Green", value = "#FF80FF80"},
    {name = "Pink", value = "#FFFFB0D8"}
  }
  local subtitle_fonts = {"sans-serif", "Google Sans Flex", "serif", "monospace"}

  local function normalize_subtitle_color(color)
    color = tostring(color or "#FFFFFFFF"):upper()
    if color:match("^#%x%x%x%x%x%x%x%x") then return color:sub(1, 9) end
    return color
  end

  local function cycle_option(items, current, direction, value_of)
    local index = 1
    for i, item in ipairs(items) do
      if value_of(item) == current then index = i break end
    end
    return items[((index - 1 + direction) % #items) + 1]
  end

  local function SubtitleStylePopup(on_back)
    local node = {
      width = dp(360), height = dp(288), interactive = false,
      panel_alpha = "00", text_alpha = "00", secondary_alpha = "00",
      hover_alpha = "00", delay_value = 0, font_size = 38, border_size = 1.65,
      color = "#FFFFFFFF", font = "sans-serif",
      modifier = Modifier():clickable({
        name = "subtitle-style-panel", enabled = false, on_click = function() end
      })
    }
    local function reset_subtitle_style()
      mp.set_property_number("sub-delay", 0)
      mp.set_property_number("sub-font-size", 38)
      mp.set_property_number("sub-border-size", 1.65)
      mp.set_property("sub-color", "#FFFFFFFF")
      mp.set_property("sub-font", "sans-serif")
    end
    node.header = ChapterHeader(on_back, "Subtitle Settings", "arrow_back", {
      name = "subtitle-style-reset",
      icon = "restart_alt",
      on_click = reset_subtitle_style
    })
    node.delay = SubtitleAdjustRow("subtitle-delay", "Timing", 
      function()
        mp.set_property_number("sub-delay", clamp(node.delay_value - 0.1, -10, 10))
      end,
      function()
        mp.set_property_number("sub-delay", clamp(node.delay_value + 0.1, -10, 10))
      end)
    node.font_size_row = SubtitleAdjustRow("subtitle-font-size", "Font size",
      function()
        mp.set_property_number("sub-font-size", clamp(node.font_size - 2, 10, 120))
      end,
      function()
        mp.set_property_number("sub-font-size", clamp(node.font_size + 2, 10, 120))
      end)
    node.border = SubtitleAdjustRow("subtitle-border", "Border",
      function()
        mp.set_property_number("sub-border-size", clamp(node.border_size - 0.5, 0, 10))
      end,
      function()
        mp.set_property_number("sub-border-size", clamp(node.border_size + 0.5, 0, 10))
      end)
    node.color_row = SubtitleAdjustRow("subtitle-color", "Color",
      function()
        local item = cycle_option(subtitle_colors, normalize_subtitle_color(node.color), -1,
          function(v) return v.value end)
        mp.set_property("sub-color", item.value)
      end,
      function()
        local item = cycle_option(subtitle_colors, normalize_subtitle_color(node.color), 1,
          function(v) return v.value end)
        mp.set_property("sub-color", item.value)
      end)
    node.font_row = SubtitleAdjustRow("subtitle-font", "Font",
      function()
        mp.set_property("sub-font", cycle_option(subtitle_fonts, node.font, -1, function(v) return v end))
      end,
      function()
        mp.set_property("sub-font", cycle_option(subtitle_fonts, node.font, 1, function(v) return v end))
      end)
    function node:update(props)
      update_fields(self, props)
      self.modifier.fixed_width, self.modifier.fixed_height = self.width, self.height
      self.modifier.pointer_enabled = self.interactive
      self.header:update({alpha = self.text_alpha, hover_alpha = self.hover_alpha,
        interactive = self.interactive})
      local common = {interactive = self.interactive, text_alpha = self.text_alpha,
        secondary_alpha = self.secondary_alpha, hover_alpha = self.hover_alpha}
      common.value = string.format("%+.1fs", self.delay_value); self.delay:update(common)
      common.value = string.format("%g", self.font_size); self.font_size_row:update(common)
      common.value = string.format("%g", self.border_size); self.border:update(common)
      local color_name = normalize_subtitle_color(self.color)
      for _, item in ipairs(subtitle_colors) do
        if item.value == color_name then color_name = item.name break end
      end
      common.value = color_name; self.color_row:update(common)
      common.value = self.font; self.font_row:update(common)
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = self.width, h = self.height}, parent)
    end
    function node:draw(ass, bounds)
      draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
        dp(30), "#050708", self.panel_alpha)
      draw_node(self.header, ass, Rect({x = bounds.x, y = bounds.y, w = bounds.w, h = dp(56)}))
      local rows = {self.delay, self.font_size_row, self.border, self.color_row, self.font_row}
      local y = bounds.y + dp(60)
      for _, row in ipairs(rows) do
        draw_node(row, ass, Rect({x = bounds.x + dp(8), y = y,
          w = bounds.w - dp(16), h = dp(44)}))
        y = y + dp(44)
      end
    end
    return node
  end

  local function SettingsPopup(on_close)
    local node = {
      width = dp(480), height = dp(260), interactive = false,
      modifier = Modifier():clickable({
        name = "settings-dialog-panel", enabled = false, on_click = function() end
      })
    }
    node.header = ChapterHeader(on_close, "Settings")
    node.video_row = SettingsActionRow("settings-video-row", "videocam",
      function() set_settings_page("video") end)
    node.audio_row = SettingsActionRow("settings-audio-row", "record_voice_over",
      function() set_settings_page("audio") end)
    node.subtitle_row = SettingsActionRow("settings-subtitle-row", "subtitles",
      function() set_settings_page("subtitles") end)
    node.speed_row = SettingsActionRow("settings-speed-row", "speed",
      function() set_settings_page("speed") end)
    node.video = TrackPopup(function() set_settings_page("root") end, {
      name = "settings-video", title = "Video Track", action_icon = "arrow_back",
      state = settings_state,
      on_select = function(item)
        if item.image then
          open_image_track(item)
          return false
        elseif item.stream_quality then select_stream_quality(item)
        else mp.set_property_number("vid", tonumber(item.id)) end
      end
    })
    node.audio = TrackPopup(function() set_settings_page("root") end, {
      name = "settings-audio", title = "Audio Track", action_icon = "arrow_back",
      state = settings_state,
      on_select = function(item)
        if item.id == 0 then mp.set_property("aid", "no")
        else mp.set_property_number("aid", tonumber(item.id)) end
      end
    })
    node.subtitles = TrackPopup(function() set_settings_page("root") end, {
      name = "settings-subtitles", title = "Subtitles", action_icon = "arrow_back",
      footer = {label = "Add", icon = "add", on_click = open_subtitle_file_picker},
      secondary_footer = {label = "Link", icon = "link",
        on_click = open_subtitle_link_picker},
      right_action = {
        name = "settings-subtitles-style",
        icon = "subtitles_gear",
        on_click = function() set_settings_page("subtitle_style") end
      },
      state = settings_state,
      on_select = function(item)
        if item.auto_page then
          set_settings_page("auto_captions")
          return false
        elseif item.id == 0 then mp.set_property("sid", "no")
        else
          mp.set_property_number("sid", tonumber(item.id))
          mp.set_property_native("sub-visibility", true)
        end
      end
    })
    node.auto_captions = TrackPopup(function() set_settings_page("subtitles") end, {
      name = "settings-auto-captions", title = "Auto Captions",
      action_icon = "arrow_back", state = settings_state,
      on_select = function(item)
        attach_ytdl_caption(item)
        return false
      end
    })
    node.speed = SpeedPopup(function() set_settings_page("root") end)
    node.subtitle_style = SubtitleStylePopup(function() set_settings_page("subtitles") end)
    function node:update(props)
      update_fields(self, props)
      self.modifier.fixed_width, self.modifier.fixed_height = self.width, self.height
      self.modifier.pointer_enabled = self.interactive
      local common = {interactive = self.interactive, text_alpha = self.text_alpha,
        secondary_alpha = self.secondary_alpha, hover_alpha = self.hover_alpha,
        selected_alpha = self.selected_alpha}
      self.header:update({alpha = self.text_alpha,
        title_alpha = ass_alpha_for_opacity((self.opacity or 0) * 0.70),
        hover_alpha = self.hover_alpha,
        interactive = self.interactive})
      common.label, common.value = "Video Track (" ..
        tostring(self.video_track_count or #self.video_items) .. ")",
        selected_track_label(self.video_items, self.video_id, "None")
      self.video_row:update(common)
      common.label, common.value = "Audio Track (" ..
        math.max(0, #self.audio_items - 1) .. ")",
        selected_track_label(self.audio_items, self.audio_id, "None")
      self.audio_row:update(common)
      common.label, common.value = "Subtitles (" ..
        tostring(self.subtitle_track_count or math.max(0, #self.subtitle_items - 1)) .. ")",
        selected_track_label(self.subtitle_items, self.subtitle_id, "Off")
      common.max_value_chars = 14
      self.subtitle_row:update(common)
      common.max_value_chars = nil
      common.label, common.value = "Playback Speed", string.format("%gx", self.speed_value)
      self.speed_row:update(common)
      local page_props = {
        interactive = self.interactive, panel_alpha = self.panel_alpha,
        text_alpha = self.text_alpha, secondary_alpha = self.secondary_alpha,
        hover_alpha = self.hover_alpha, selected_alpha = self.selected_alpha,
        scrollbar_track_alpha = self.scrollbar_track_alpha,
        scrollbar_thumb_alpha = self.scrollbar_thumb_alpha
      }
      page_props.width, page_props.height = self.width, self.height
      page_props.layout_height = self.layout_height
      if settings_state.page == "video" then
        page_props.items, page_props.active_id = self.video_items, self.video_id
        self.video:update(page_props)
      elseif settings_state.page == "audio" then
        page_props.items, page_props.active_id = self.audio_items, self.audio_id
        self.audio:update(page_props)
      elseif settings_state.page == "subtitles" then
        page_props.items, page_props.active_id = self.subtitle_items, self.subtitle_id
        self.subtitles:update(page_props)
      elseif settings_state.page == "auto_captions" then
        page_props.items, page_props.active_id = {}, nil
        for _, item in ipairs(self.auto_caption_items or {}) do
          local row_item = {}
          for key, value in pairs(item) do row_item[key] = value end
          row_item.loading = item.id == ytdl_state.caption_loading_id
          page_props.items[#page_props.items + 1] = row_item
        end
        self.auto_captions:update(page_props)
      elseif settings_state.page == "speed" then
        page_props.speed = self.speed_value
        self.speed:update(page_props)
      elseif settings_state.page == "subtitle_style" then
        page_props.delay_value = self.subtitle_delay
        page_props.font_size = self.subtitle_font_size
        page_props.border_size = self.subtitle_border_size
        page_props.color = self.subtitle_color
        page_props.font = self.subtitle_font
        self.subtitle_style:update(page_props)
      end
    end
    function node:measure(parent)
      return apply_modifier_size(self.modifier, {w = self.width, h = self.height}, parent)
    end
    function node:draw(ass, bounds)
      if settings_state.page == "video" then return self.video:draw(ass, bounds) end
      if settings_state.page == "audio" then return self.audio:draw(ass, bounds) end
      if settings_state.page == "subtitles" then return self.subtitles:draw(ass, bounds) end
      if settings_state.page == "auto_captions" then
        return self.auto_captions:draw(ass, bounds)
      end
      if settings_state.page == "speed" then return self.speed:draw(ass, bounds) end
      if settings_state.page == "subtitle_style" then
        return self.subtitle_style:draw(ass, bounds)
      end
      draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
        dp(30), "#050708", self.panel_alpha)
      draw_node(self.header, ass, Rect({x = bounds.x, y = bounds.y, w = bounds.w, h = dp(56)}))
      local y = bounds.y + dp(64)
      local rows = {}
      if #self.video_items > 1 then rows[#rows + 1] = self.video_row end
      rows[#rows + 1] = self.audio_row
      rows[#rows + 1] = self.subtitle_row
      rows[#rows + 1] = self.speed_row
      for _, row in ipairs(rows) do
        draw_node(row, ass, Rect({x = bounds.x + dp(8), y = y,
          w = bounds.w - dp(16), h = dp(52)}))
        y = y + dp(56)
      end
    end
    return node
  end

  local function ChapterDialogHost()
    local close = function() set_chapter_dialog_open(false) end
    return PopupHost({
      name = "chapter-dialog", state = chapter_state,
      anchor_name = "chapter-display", anchor_offset_x = -dp(8), on_close = close,
      popup = ChapterPopup(close),
      update_popup = function(popup, snapshot, opacity, interactive)
        local props = popup_visual_props(opacity, interactive)
        props.width = math.max(dp(160), math.min(dp(320), viewport.w - dp(24)))
        local content_h = dp(72) + #snapshot.chapters * dp(48)
        if #snapshot.chapters > 0 then content_h = content_h - dp(4) end
        props.height = clamp(content_h, dp(116),
          math.max(dp(116), math.min(dp(480), viewport.h - dp(24))))
        props.chapters = snapshot.chapters
        props.selected_index = snapshot.chapter_index or -1
        popup:update(props)
      end
    })
  end

  local function TrackDialogHost(args)
    return PopupHost({
      name = args.name, state = args.state, anchor_name = args.anchor_name,
      on_close = args.close, popup = args.create_popup(args.close),
      update_popup = function(popup, snapshot, opacity, interactive)
        local props = popup_visual_props(opacity, interactive)
        props.width = math.max(dp(220), math.min(dp(420), viewport.w - dp(24)))
        local items = snapshot[args.items_key]
        local content_h = dp(72) + #items * dp(48)
        if #items > 0 then content_h = content_h - dp(4) end
        props.height = clamp(content_h, dp(116),
          math.max(dp(116), math.min(dp(480), viewport.h - dp(24))))
        props.items, props.active_id = items, snapshot[args.active_key]
        popup:update(props)
      end
    })
  end

  local function SettingsDialogHost()
    return PopupHost({
      name = "settings-dialog", state = settings_state,
      anchor_name = "settings-button",
      on_close = function() set_settings_dialog_open(false) end,
      popup = SettingsPopup(function() set_settings_dialog_open(false) end),
      update_popup = function(popup, snapshot, opacity, interactive)
        local video_items = snapshot.video_items or {}
        local audio_items = snapshot.audio_items or {}
        local subtitle_items = snapshot.subtitle_items or {}
        local desired_w = (settings_state.page == "subtitles" or
          settings_state.page == "auto_captions") and dp(420) or dp(320)
        local target_w = math.max(dp(300), math.min(desired_w, viewport.w - dp(24)))
        local item_count = settings_state.page == "video" and #video_items or
          (settings_state.page == "audio" and #audio_items or
            (settings_state.page == "subtitles" and (#subtitle_items +
              (ytdl_state.source == "youtube" and 1 or 0)) or
              (settings_state.page == "auto_captions" and
                #ytdl_state.caption_items or 0)))
        local desired_h = settings_state.page == "root" and
          dp(#video_items > 1 and 292 or 236) or
          (settings_state.page == "speed" and dp(190) or
            (settings_state.page == "subtitle_style" and dp(288) or
              dp(68) + math.max(1, item_count) * dp(48) +
                (settings_state.page == "subtitles" and dp(48) or 0)))
        local max_h = math.max(dp(116), math.min(dp(480), viewport.h - dp(24)))
        if settings_state.page == "video" or settings_state.page == "audio" or
          settings_state.page == "subtitles" or
          settings_state.page == "auto_captions" then
          local whole_rows = math.max(1, math.floor((max_h - dp(68)) / dp(48)))
          max_h = dp(68) + whole_rows * dp(48)
        end
        local target_h = clamp(desired_h, dp(116), max_h)
        if settings_state.transition_phase == "resize" then
          settings_state.width_animation:set_target(target_w)
          settings_state.height_animation:set_target(target_h)
          settings_state.resize_started = true
        elseif not settings_state.transition_phase then
          settings_state.width_animation:snap(target_w)
          settings_state.height_animation:snap(target_h)
        end
        local content_opacity = opacity * settings_state.content_animation.value
        local props = popup_visual_props(content_opacity, interactive)
        props.opacity = opacity
        props.panel_alpha = ass_alpha_for_opacity(opacity * 0.96)
        props.scrollbar_track_alpha = ass_alpha_for_opacity(content_opacity * 0.16)
        props.scrollbar_thumb_alpha = ass_alpha_for_opacity(content_opacity * 0.52)
        props.width = settings_state.width_animation.value
        props.height = settings_state.height_animation.value
        props.layout_height = target_h
        props.video_items = video_items
        props.video_id = snapshot.video_id
        props.video_track_count = snapshot.video_track_count
        props.audio_items = audio_items
        props.audio_id = snapshot.audio_id
        props.subtitle_items = subtitle_items
        props.subtitle_id = snapshot.subtitle_id
        props.auto_caption_items = ytdl_state.caption_items or {}
        props.speed_value = snapshot.speed or 1
        props.subtitle_delay = snapshot.subtitle_delay or 0
        props.subtitle_font_size = snapshot.subtitle_font_size or 38
        props.subtitle_border_size = snapshot.subtitle_border_size or 1.65
        props.subtitle_color = snapshot.subtitle_color or "#FFFFFFFF"
        props.subtitle_font = snapshot.subtitle_font or "sans-serif"
        popup:update(props)
      end
    })
  end

  local SubtitleDialogHost = function()
    return TrackDialogHost({
      name = "subtitle-dialog", state = subtitle_state,
      anchor_name = "subtitles-button", items_key = "subtitle_items",
      active_key = "subtitle_id", create_popup = SubtitlePopup,
      close = function() set_subtitle_dialog_open(false) end
    })
  end
  local AudioDialogHost = function()
    return TrackDialogHost({
      name = "audio-dialog", state = audio_state,
      anchor_name = "audio-button", items_key = "audio_items",
      active_key = "audio_id", create_popup = AudioPopup,
      close = function() set_audio_dialog_open(false) end
    })
  end


  return {
    ChapterDialogHost = ChapterDialogHost,
    SubtitleDialogHost = SubtitleDialogHost,
    AudioDialogHost = AudioDialogHost,
    SettingsDialogHost = SettingsDialogHost
  }
end

return popups
