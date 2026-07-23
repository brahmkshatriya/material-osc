local renderer = {}

function renderer.new(args)
  local runtime, opts = args.runtime, args.opts
  local color_cache = {}
  local escaped_text_cache, escaped_text_cache_size = {}, 0
  local frame_alpha_cache, frame_fade_cache = {}, {}
  local clip_stack = {}
  local service = {
    default_text_font = "Google Sans Flex",
    icon_text_size = 30,
    normal_text_size = 24
  }

  function service:begin_frame()
    frame_alpha_cache, frame_fade_cache = {}, {}
    clip_stack = {}
  end

  function service:clamp(value, minimum, maximum)
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
  end

  function service:dpi_scale()
    if opts.dpi_scale ~= "auto" then
      return self:clamp(tonumber(opts.dpi_scale) or 1, 0.5, 4)
    end
    return self:clamp(runtime.viewport.dpi or 1, 0.5, 4)
  end

  function service:dp(value) return value * self:dpi_scale() end

  function service:scale_font(value)
    return math.max(1, math.floor(self:dp(value) + 0.5))
  end

  function service:ass_color(hex)
    local cached = color_cache[hex]
    if cached then return cached end
    local r, g, b = hex:match("#?(%x%x)(%x%x)(%x%x)")
    if not r then return "FFFFFF" end
    local converted = b .. g .. r
    color_cache[hex] = converted
    return converted
  end

  function service:fade_alpha(alpha)
    alpha = alpha or "00"
    local cached = frame_fade_cache[alpha]
    if cached then return cached end
    local base = tonumber(alpha or "00", 16) or 0
    local opacity = self:clamp(runtime.controller.opacity.value, 0, 1)
    local converted =
      string.format("%02X", math.floor(255 - (255 - base) * opacity + 0.5))
    frame_fade_cache[alpha] = converted
    return converted
  end

  function service:alpha(opacity)
    local cached = frame_alpha_cache[opacity]
    if cached then return cached end
    local converted = string.format("%02X",
      math.floor(255 - 255 * self:clamp(opacity, 0, 1) + 0.5))
    frame_alpha_cache[opacity] = converted
    return converted
  end

  local function escape_ass(value)
    value = tostring(value or "")
    local cached = escaped_text_cache[value]
    if cached then return cached end
    local escaped = value:gsub("\\", "\\\226\129\160")
      :gsub("{", "\\{")
      :gsub("\n", "\\N")
      :gsub("\\N ", "\\N\\h")
      :gsub("^ ", "\\h")
    if escaped_text_cache_size >= 512 then
      escaped_text_cache, escaped_text_cache_size = {}, 0
    end
    escaped_text_cache[value] = escaped
    escaped_text_cache_size = escaped_text_cache_size + 1
    return escaped
  end

  function service:push_clip(bounds)
    if not bounds then return end
    local current = clip_stack[#clip_stack]
    if current then
      bounds = {
        x1 = math.max(current.x1, bounds.x1),
        y1 = math.max(current.y1, bounds.y1),
        x2 = math.min(current.x2, bounds.x2),
        y2 = math.min(current.y2, bounds.y2)
      }
    end
    clip_stack[#clip_stack + 1] = bounds
  end

  function service:pop_clip()
    clip_stack[#clip_stack] = nil
  end

  local function append_clip(ass, bounds)
    local active = clip_stack[#clip_stack]
    if active and bounds then
      bounds = {
        x1 = math.max(active.x1, bounds.x1),
        y1 = math.max(active.y1, bounds.y1),
        x2 = math.min(active.x2, bounds.x2),
        y2 = math.min(active.y2, bounds.y2)
      }
    else
      bounds = bounds or active
    end
    if not bounds then return end
    ass:append(string.format("{\\clip(%d,%d,%d,%d)}",
      math.floor(bounds.x1), math.floor(bounds.y1),
      math.ceil(bounds.x2), math.ceil(bounds.y2)))
  end

  function service:draw_box(ass, x1, y1, x2, y2, radius, color, alpha,
      ignore_controller_fade, clip_bounds)
    if x2 <= x1 or y2 <= y1 then return end
    ass:new_event(); ass:pos(x1, y1); ass:an(7)
    local rendered_alpha = ignore_controller_fade and (alpha or "00") or
      self:fade_alpha(alpha)
    ass:append(string.format("{\\1c&H%s&\\1a&H%s&\\bord0\\shad0}",
      self:ass_color(color), rendered_alpha))
    append_clip(ass, clip_bounds)
    ass:draw_start()
    ass:round_rect_cw(0, 0, x2 - x1, y2 - y1, radius or 0)
    ass:draw_stop()
  end

  function service:draw_round_box(ass, x1, y1, x2, y2,
      top_radius, bottom_radius, color, alpha)
    if x2 <= x1 or y2 <= y1 then return end
    local width, height = x2 - x1, y2 - y1
    local maximum = math.min(width / 2, height / 2)
    local top = self:clamp(top_radius or 0, 0, maximum)
    local bottom = self:clamp(bottom_radius or top, 0, maximum)
    local kappa = 0.5522847498
    ass:new_event(); ass:pos(x1, y1); ass:an(7)
    ass:append(string.format("{\\1c&H%s&\\1a&H%s&\\bord0\\shad0}",
      self:ass_color(color), self:fade_alpha(alpha)))
    append_clip(ass)
    ass:draw_start()
    ass:move_to(top, 0)
    ass:line_to(width - top, 0)
    ass:bezier_curve(width - top + top * kappa, 0,
      width, top - top * kappa, width, top)
    ass:line_to(width, height - bottom)
    ass:bezier_curve(width, height - bottom + bottom * kappa,
      width - bottom + bottom * kappa, height, width - bottom, height)
    ass:line_to(bottom, height)
    ass:bezier_curve(bottom - bottom * kappa, height,
      0, height - bottom + bottom * kappa, 0, height - bottom)
    ass:line_to(0, top)
    ass:bezier_curve(0, top - top * kappa,
      top - top * kappa, 0, top, 0)
    ass:draw_stop()
  end

  function service:draw_rect(ass, x1, y1, x2, y2, color, alpha)
    if x2 <= x1 or y2 <= y1 then return end
    self:draw_box(ass, x1, y1, x2, y2,
      math.min(x2 - x1, y2 - y1) / 2, color, alpha)
  end

  function service:draw_boxes(ass, boxes, color, alpha)
    if not boxes or #boxes == 0 then return end
    ass:new_event(); ass:pos(0, 0); ass:an(7)
    ass:append(string.format("{\\1c&H%s&\\1a&H%s&\\bord0\\shad0}",
      self:ass_color(color), self:fade_alpha(alpha)))
    append_clip(ass)
    ass:draw_start()
    for _, box in ipairs(boxes) do
      if box.x2 > box.x1 and box.y2 > box.y1 then
        ass:round_rect_cw(box.x1, box.y1, box.x2, box.y2,
          box.radius or 0)
      end
    end
    ass:draw_stop()
  end

  function service:draw_text(ass, x, y, value, size, color, alpha, font, alignment,
      bold, ignore_controller_fade, clip_bounds)
    ass:new_event(); ass:pos(x, y); ass:an(alignment or 5)
    local rendered_alpha = ignore_controller_fade and (alpha or "00") or
      self:fade_alpha(alpha)
    ass:append(string.format("{\\bord0\\shad0\\fs%d\\fn%s%s\\1c&H%s&\\1a&H%s&}",
      self:scale_font(size or 22), font or self.default_text_font,
      bold and "\\b1" or "", self:ass_color(color or "#FFFFFF"),
      rendered_alpha))
    append_clip(ass, clip_bounds)
    ass:append(escape_ass(value))
  end

  function service:draw_shadowed_text(ass, x, y, value, size, color, alpha, font, alignment)
    local text_size = self:scale_font(size or 22)
    local text_font = font or self.default_text_font
    local escaped_value = escape_ass(value)
    ass:new_event()
    ass:pos(x + self:dp(1.2), y + self:dp(1.5))
    ass:an(alignment or 5)
    ass:append(string.format(
      "{\\bord1.4\\blur4\\shad0\\fs%d\\fn%s\\1c&H000000&\\3c&H000000&\\1a&H%s&\\3a&H%s&}",
      text_size, text_font, self:fade_alpha("58"), self:fade_alpha("58")))
    append_clip(ass)
    ass:append(escaped_value)
    self:draw_text(ass, x, y, value, size, color, alpha, font, alignment)
  end

  function service:draw_icon(ass, x, y, icon, color, size, alpha,
      ignore_controller_fade, clip_bounds)
    self:draw_text(ass, x, y, icon, size or self.icon_text_size, color, alpha,
      "Material Symbols Rounded", nil, nil, ignore_controller_fade, clip_bounds)
  end

  return service
end

return renderer
