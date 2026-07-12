local renderer = {}

function renderer.new(args)
  local runtime, opts = args.runtime, args.opts
  local service = {
    default_text_font = "Google Sans Flex",
    icon_text_size = 30,
    normal_text_size = 24
  }

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
    local r, g, b = hex:match("#?(%x%x)(%x%x)(%x%x)")
    if not r then return "FFFFFF" end
    return b .. g .. r
  end

  function service:fade_alpha(alpha)
    local base = tonumber(alpha or "00", 16) or 0
    local opacity = self:clamp(runtime.controller.opacity.value, 0, 1)
    return string.format("%02X", math.floor(255 - (255 - base) * opacity + 0.5))
  end

  function service:alpha(opacity)
    return string.format("%02X",
      math.floor(255 - 255 * self:clamp(opacity, 0, 1) + 0.5))
  end

  function service:draw_box(ass, x1, y1, x2, y2, radius, color, alpha)
    if x2 <= x1 or y2 <= y1 then return end
    ass:new_event(); ass:pos(x1, y1); ass:an(7)
    ass:append(string.format("{\\1c&H%s&\\1a&H%s&\\bord0\\shad0}",
      self:ass_color(color), self:fade_alpha(alpha)))
    ass:draw_start()
    ass:round_rect_cw(0, 0, x2 - x1, y2 - y1, radius or 0)
    ass:draw_stop()
  end

  function service:draw_rect(ass, x1, y1, x2, y2, color, alpha)
    if x2 <= x1 or y2 <= y1 then return end
    self:draw_box(ass, x1, y1, x2, y2,
      math.min(x2 - x1, y2 - y1) / 2, color, alpha)
  end

  function service:draw_text(ass, x, y, value, size, color, alpha, font, alignment, bold)
    ass:new_event(); ass:pos(x, y); ass:an(alignment or 5)
    ass:append(string.format("{\\bord0\\shad0\\fs%d\\fn%s%s\\1c&H%s&\\1a&H%s&}",
      self:scale_font(size or 22), font or self.default_text_font,
      bold and "\\b1" or "", self:ass_color(color or "#FFFFFF"),
      self:fade_alpha(alpha)))
    ass:append(mp.command_native({"escape-ass", value or ""}))
  end

  function service:draw_icon(ass, x, y, icon, color, size, alpha)
    self:draw_text(ass, x, y, icon, size or self.icon_text_size, color, alpha,
      "Material Symbols Rounded")
  end

  return service
end

return renderer
