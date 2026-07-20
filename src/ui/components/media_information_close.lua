local media_information_close = {}

function media_information_close.new(services)
  local ui = services.ui
  local size, margin, icon_size = 36, 12, 20
  local node = {
    visible = false,
    modifier = ui.Modifier():fillMaxWidth():fillMaxHeight()
      :drawBehindInteraction(false)
  }

  node.button = {
    modifier = ui.Modifier():width(size):height(size):align({
      horizontal = "ending", vertical = "top"
    }):clickable({
      name = "media-information-close",
      on_click = function()
        if node.visible then services.context_actions:show_media_information() end
      end
    })
  }

  function node.button:measure(parent)
    return ui.apply_modifier_size(self.modifier, {w = size, h = size}, parent)
  end

  function node.button:draw(ass, bounds)
    ui.draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
      bounds.h / 2, "#050708", ui.alpha(0.84), true)
    if ui.mouse_in(bounds) then
      ui.draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
        bounds.h / 2, "#FFFFFF", ui.alpha(0.16), true)
    end
    ui.draw_icon(ass, bounds.x + bounds.w / 2, bounds.y + bounds.h / 2,
      "close", "#FFFFFF", icon_size / ui.dpi_scale(), ui.alpha(1), true)
  end

  function node:update()
    self.visible = services.context_actions:media_information_visible()
    self.button.modifier.pointer_enabled = self.visible
  end

  function node:measure(parent)
    return ui.apply_modifier_size(self.modifier, {w = 0, h = 0}, parent)
  end

  function node:draw(ass, bounds)
    if not self.visible then return end
    ui.draw_node(self.button, ass, ui.Rect({
      x = bounds.x + margin,
      y = bounds.y + margin,
      w = math.max(0, bounds.w - margin * 2),
      h = math.max(0, bounds.h - margin * 2)
    }))
  end

  return node
end

return media_information_close
