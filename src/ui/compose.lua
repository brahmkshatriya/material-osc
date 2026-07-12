local compose = {}

local function RectangleShape()
  return {kind = "rectangle"}
end

local function RoundedCornerShape(args)
  return {
    kind = "rounded",
    radius = args and args.radius,
    percent = args and args.percent
  }
end

function compose.new(deps)
  local runtime = deps.runtime
  local dp = deps.dp
  local mouse_in = deps.mouse_in
  local draw_box = deps.draw_box
  local draw_icon = deps.draw_icon
  local draw_text = deps.draw_text
  local text_intrinsic_width = deps.text_intrinsic_width
  local request_tooltip = deps.request_tooltip
  local default_text_font = deps.default_text_font
  local icon_text_size = deps.icon_text_size
  local normal_text_size = deps.normal_text_size

  local function Rect(args)
    return {
      x = args.x,
      y = args.y,
      w = args.w,
      h = args.h,
      x1 = args.x,
      y1 = args.y,
      x2 = args.x + args.w,
      y2 = args.y + args.h
    }
  end

  local function auto_pointer_name()
    runtime.input.next_id = runtime.input.next_id + 1
    return "pointer-" .. runtime.input.next_id
  end

  local function Modifier()
    local modifier = {
      padding_starting = 0,
      padding_top = 0,
      padding_ending = 0,
      padding_bottom = 0,
      align_horizontal = "starting",
      align_vertical = "top"
    }

    function modifier:width(value)
      self.fixed_width = value
      return self
    end

    function modifier:height(value)
      self.fixed_height = value
      return self
    end

    function modifier:fillMaxWidth()
      self.fill_max_width = true
      return self
    end

    function modifier:fillMaxHeight()
      self.fill_max_height = true
      return self
    end

    function modifier:padding(args)
      self.padding_starting = self.padding_starting +
                    (args.starting or args.horizontal or
                      args.all or 0)
      self.padding_top = self.padding_top +
                   (args.top or args.vertical or args.all or 0)
      self.padding_ending = self.padding_ending +
                    (args.ending or args.horizontal or args.all or
                      0)
      self.padding_bottom = self.padding_bottom +
                    (args.bottom or args.vertical or args.all or 0)
      return self
    end

    function modifier:background(args)
      self.background_color = args.color
      self.background_alpha = args.alpha or "00"
      self.background_shape = args.shape or RectangleShape()
      return self
    end

    function modifier:align(args)
      self.align_horizontal = args.horizontal or self.align_horizontal
      self.align_vertical = args.vertical or self.align_vertical
      return self
    end

    function modifier:clickable(args)
      args = args or {}
      self.pointer_name = args.name or auto_pointer_name()
      self.pointer_action = args.on_click
      self.pointer_press_action = args.on_press
      self.pointer_release_action = args.on_release
      self.pointer_move_action = args.on_move
      self.pointer_double_action = args.on_double
      self.pointer_scroll_up_action = args.on_scroll_up
      self.pointer_scroll_down_action = args.on_scroll_down
      self.pointer_enabled = args.enabled ~= false
      return self
    end

    function modifier:pointerArea(args)
      args = args or {}
      self.pointer_name = args.name or auto_pointer_name()
      self.pointer_action = args.on_click
      self.pointer_press_action = args.on_press
      self.pointer_release_action = args.on_release
      self.pointer_move_action = args.on_move
      self.pointer_double_action = args.on_double
      self.pointer_scroll_up_action = args.on_scroll_up
      self.pointer_scroll_down_action = args.on_scroll_down
      self.pointer_enabled = args.enabled ~= false
      self.pointer_extend_x = args.extend_x or 0
      self.pointer_extend_y = args.extend_y or 0
      return self
    end

    function modifier:hoverIndication(args)
      self.hover_indication = true
      self.hover_color = args and args.color or "#FFFFFF"
      self.hover_alpha = args and args.alpha or "E6"
      self.hover_inset = args and args.inset or dp(0)
      return self
    end

    function modifier:drawBehindInteraction(value)
      self.draw_own_interaction = value ~= false
      return self
    end

    return modifier
  end

  local function apply_modifier_size(modifier, intrinsic, parent)
    local horizontal_padding = modifier.padding_starting +
                     modifier.padding_ending
    local vertical_padding = modifier.padding_top + modifier.padding_bottom
    local width = modifier.fixed_width or intrinsic.w
    local height = modifier.fixed_height or intrinsic.h

    if modifier.fill_max_width and parent then
      width = parent.w - modifier.padding_starting - modifier.padding_ending
    end

    if modifier.fill_max_height and parent then
      height = parent.h - modifier.padding_top - modifier.padding_bottom
    end

    return {
      w = math.max(0, width + horizontal_padding),
      h = math.max(0, height + vertical_padding)
    }
  end

  local function place_with_modifier(modifier, size, parent)
    local x = parent.x
    local y = parent.y

    if modifier.align_horizontal == "center" then
      x = parent.x + (parent.w - size.w) / 2
    elseif modifier.align_horizontal == "ending" then
      x = parent.x + parent.w - size.w
    end

    if modifier.align_vertical == "center" then
      y = parent.y + (parent.h - size.h) / 2
    elseif modifier.align_vertical == "bottom" then
      y = parent.y + parent.h - size.h
    end

    return Rect({x = x, y = y, w = size.w, h = size.h})
  end

  local function content_bounds(bounds, modifier)
    return Rect({
      x = bounds.x + modifier.padding_starting,
      y = bounds.y + modifier.padding_top,
      w = math.max(0, bounds.w - modifier.padding_starting -
               modifier.padding_ending),
      h = math.max(0,
             bounds.h - modifier.padding_top - modifier.padding_bottom)
    })
  end

  local function measure_node(node, parent)
    return node:measure(parent or Rect({x = 0, y = 0, w = 0, h = 0}))
  end

  local function interaction_bounds(bounds, modifier)
    local extend_x = modifier.pointer_extend_x or 0
    local extend_y = modifier.pointer_extend_y or 0
    return Rect({
      x = bounds.x - extend_x,
      y = bounds.y - extend_y,
      w = bounds.w + extend_x * 2,
      h = bounds.h + extend_y * 2
    })
  end

  local function shape_radius(shape, bounds)
    if not shape or shape.kind == "rectangle" then return 0 end
    if shape.percent then
      return math.min(bounds.w, bounds.h) * shape.percent / 100
    end
    return shape.radius or 0
  end

  local function draw_modifier_background(ass, bounds, modifier)
    if not modifier.background_color then return end
    draw_box(ass, bounds.x, bounds.y, bounds.x2, bounds.y2,
         shape_radius(modifier.background_shape, bounds),
         modifier.background_color, modifier.background_alpha)
  end

  local function draw_modifier_interaction(ass, bounds, modifier)
    local pointer = modifier.pointer_name and
              interaction_bounds(bounds, modifier) or bounds

    if modifier.pointer_name then
      pointer.name = modifier.pointer_name
      pointer.enabled = modifier.pointer_enabled
      runtime.input.hitboxes[modifier.pointer_name] = pointer
      runtime.input.order[#runtime.input.order + 1] = modifier.pointer_name
      pointer.on_click = modifier.pointer_action
      pointer.on_press = modifier.pointer_press_action
      pointer.on_release = modifier.pointer_release_action
      pointer.on_move = modifier.pointer_move_action
      pointer.on_double = modifier.pointer_double_action
      pointer.on_scroll_up = modifier.pointer_scroll_up_action
      pointer.on_scroll_down = modifier.pointer_scroll_down_action
    end

    if modifier.hover_indication and modifier.pointer_enabled ~= false and
      mouse_in(pointer) then
      local inset = modifier.hover_inset or 0
      draw_box(ass, bounds.x + inset, bounds.y + inset, bounds.x2 - inset,
           bounds.y2 - inset, (bounds.h - inset * 2) / 2,
           modifier.hover_color, modifier.hover_alpha)
    end
  end

  local function draw_node(node, ass, parent)
    local measured = node:measure(parent)
    local bounds = place_with_modifier(node.modifier, measured, parent)
    draw_modifier_background(ass, bounds, node.modifier)
    if node.modifier.draw_own_interaction ~= false then
      draw_modifier_interaction(ass, bounds, node.modifier)
    end
    node:draw(ass, bounds)
    return bounds
  end

  local function IconButton(args)
    local node = {
      icon = args.icon,
      tooltip = args.tooltip,
      size = args.size or icon_text_size,
      enabled = args.enabled ~= false,
      on_click = args.on_click,
      on_scroll_up = args.on_scroll_up,
      on_scroll_down = args.on_scroll_down
    }

    node.modifier = args.modifier or Modifier():padding({all = dp(2)}):clickable({
      name = args.name,
      enabled = node.enabled,
      on_click = function()
        if node.enabled and node.on_click then node.on_click() end
      end,
      on_scroll_up = function()
        if node.enabled and node.on_scroll_up then node.on_scroll_up() end
      end,
      on_scroll_down = function()
        if node.enabled and node.on_scroll_down then node.on_scroll_down() end
      end
    }):hoverIndication()

    function node:update(props)
      if props.icon ~= nil then self.icon = props.icon end
      if props.tooltip ~= nil or props.clear_tooltip then self.tooltip = props.tooltip end
      if props.enabled ~= nil then
        self.enabled = props.enabled
        self.modifier.pointer_enabled = props.enabled
      end
      if props.on_click ~= nil then self.on_click = props.on_click end
    end

    function node:measure(parent)
      local size = dp(self.size)
      return apply_modifier_size(self.modifier, {w = size, h = size}, parent)
    end

    function node:draw(ass, bounds)
      draw_icon(ass, bounds.x + bounds.w / 2, bounds.y + bounds.h / 2,
            self.icon, "#FFFFFF", self.size)
      if self.tooltip and self.enabled and mouse_in(bounds) then
        request_tooltip(self.tooltip, bounds)
      end
    end

    return node
  end

  local function TextItem(args)
    local node = {
      text = args.text or "",
      size = args.size or normal_text_size,
      color = args.color or "#FFFFFF",
      alpha = args.alpha,
      alignment = args.alignment,
      modifier = args.modifier or Modifier()
    }

    function node:update(props)
      if props.text ~= nil then self.text = props.text end
      if props.color ~= nil then self.color = props.color end
      if props.alpha ~= nil then self.alpha = props.alpha end
    end

    function node:measure(parent)
      return apply_modifier_size(self.modifier, {
        w = text_intrinsic_width(self.text, self.size),
        h = dp(self.size)
      }, parent)
    end

    function node:draw(ass, bounds)
      draw_text(ass, bounds.x + bounds.w / 2, bounds.y + bounds.h / 2,
            self.text, self.size, self.color, self.alpha,
            default_text_font, self.alignment)
    end

    return node
  end

  local function Visibility(args)
    local node = {
      visible = args.visible ~= false,
      child = args.child,
      modifier = args.modifier or Modifier():drawBehindInteraction(false)
    }

    function node:set_visible(visible) self.visible = visible == true end

    function node:measure(parent)
      if not self.visible then return {w = 0, h = 0} end
      local size = measure_node(self.child, parent)
      return apply_modifier_size(self.modifier, size, parent)
    end

    function node:draw(ass, bounds)
      if self.visible then draw_node(self.child, ass, bounds) end
    end

    return node
  end

  local function Row(args)
    local node = {
      children = args.children or {},
      gap = args.gap or 0,
      modifier = args.modifier or Modifier():drawBehindInteraction(false)
    }

    function node:measure(parent)
      local width, height, visible_children = 0, 0, 0
      for _, child in ipairs(self.children) do
        local size = measure_node(child, parent)
        if size.w > 0 or size.h > 0 then
          if visible_children > 0 then width = width + self.gap end
          width = width + size.w
          height = math.max(height, size.h)
          visible_children = visible_children + 1
        end
      end
      return apply_modifier_size(self.modifier, {w = width, h = height}, parent)
    end

    function node:draw(ass, bounds)
      local content = content_bounds(bounds, self.modifier)
      local x, visible_children = content.x, 0
      for _, child in ipairs(self.children) do
        local size = measure_node(child, content)
        if size.w > 0 or size.h > 0 then
          if visible_children > 0 then x = x + self.gap end
          local child_bounds = Rect({
            x = x,
            y = content.y + (content.h - size.h) / 2,
            w = size.w,
            h = size.h
          })
          draw_modifier_background(ass, child_bounds, child.modifier)
          draw_modifier_interaction(ass, child_bounds, child.modifier)
          child:draw(ass, child_bounds)
          x = x + size.w
          visible_children = visible_children + 1
        end
      end
    end

    return node
  end

  local function Column(args)
    local node = {
      children = args.children or {},
      gap = args.gap or 0,
      modifier = args.modifier or Modifier():drawBehindInteraction(false)
    }

    function node:measure(parent)
      local width, height, visible_children = 0, 0, 0
      for _, child in ipairs(self.children) do
        local size = measure_node(child, parent)
        if size.w > 0 or size.h > 0 then
          if visible_children > 0 then height = height + self.gap end
          width = math.max(width, size.w)
          height = height + size.h
          visible_children = visible_children + 1
        end
      end
      return apply_modifier_size(self.modifier, {w = width, h = height}, parent)
    end

    function node:draw(ass, bounds)
      local content = content_bounds(bounds, self.modifier)
      local y, visible_children = content.y, 0
      for _, child in ipairs(self.children) do
        local size = measure_node(child, content)
        if size.w > 0 or size.h > 0 then
          if visible_children > 0 then y = y + self.gap end
          local child_bounds = place_with_modifier(child.modifier, size, Rect({
            x = content.x, y = y, w = content.w, h = size.h
          }))
          draw_modifier_background(ass, child_bounds, child.modifier)
          draw_modifier_interaction(ass, child_bounds, child.modifier)
          child:draw(ass, child_bounds)
          y = y + size.h
          visible_children = visible_children + 1
        end
      end
    end

    return node
  end

  local function Pill(args)
    local child = Row({
      children = args.children,
      gap = dp(4),
      modifier = Modifier():padding({
        horizontal = dp(args.horizontal_padding or 4),
        vertical = dp(4)
      })
    })
    local modifier = args.modifier or Modifier()
    if not args.no_background and not modifier.background_color then
      modifier:background({
        color = "#050708",
        alpha = "78",
        shape = RoundedCornerShape({percent = 50})
      })
    end

    local node = {child = child, modifier = modifier:drawBehindInteraction(false)}

    function node:measure(parent)
      return apply_modifier_size(self.modifier, measure_node(self.child, parent), parent)
    end

    function node:draw(ass, bounds)
      self.child:draw(ass, content_bounds(bounds, self.modifier))
    end

    return node
  end


  return {
    Rect = Rect,
    RectangleShape = RectangleShape,
    RoundedCornerShape = RoundedCornerShape,
    Modifier = Modifier,
    apply_modifier_size = apply_modifier_size,
    place_with_modifier = place_with_modifier,
    content_bounds = content_bounds,
    measure_node = measure_node,
    draw_modifier_background = draw_modifier_background,
    draw_modifier_interaction = draw_modifier_interaction,
    draw_node = draw_node,
    IconButton = IconButton,
    TextItem = TextItem,
    Visibility = Visibility,
    Row = Row,
    Column = Column,
    Pill = Pill
  }
end

return compose
