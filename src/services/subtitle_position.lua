local subtitle_position = {}

local function contains(values, wanted)
  for _, value in ipairs(values or {}) do
    if value == wanted then return true end
  end
  return false
end

function subtitle_position.new(args)
  local mp = args.mp
  local offset_property = "sub-margin-y-offset"
  local has_offset_property = contains(
    mp.get_property_native("property-list", {}), offset_property)
  local property = has_offset_property and offset_property or "sub-margin-y"
  local baseline = mp.get_property_number(property, 0) or 0
  local service = {
    property = property,
    baseline = baseline,
    last_value = nil,
    last_margin = nil
  }

  local function set_number(value)
    value = math.floor(value * 100 + 0.5) / 100
    if service.last_value ~= nil and
      math.abs(service.last_value - value) < 0.005 then return end
    mp.set_property_number(property, value)
    service.last_value = value
  end

  local function publish_margin(bottom)
    bottom = math.floor(bottom * 10000 + 0.5) / 10000
    if service.last_margin ~= nil and
      math.abs(service.last_margin - bottom) < 0.00005 then return end
    mp.set_property_native("user-data/osc/margins", {
      l = 0, r = 0, t = 0, b = bottom
    })
    service.last_margin = bottom
  end

  function service:update(controller_height, opacity, viewport_height)
    viewport_height = math.max(1, tonumber(viewport_height) or 1)
    controller_height = math.max(0, tonumber(controller_height) or 0)
    opacity = math.max(0, math.min(1, tonumber(opacity) or 0))
    local occupied_pixels = controller_height * opacity
    publish_margin(occupied_pixels / viewport_height)

    local offset = 0
    if mp.get_property("sub-align-y", "bottom") == "bottom" then
      offset = occupied_pixels
      if mp.get_property_native("sub-scale-by-window") ~= false then
        offset = offset * 720 / viewport_height
      end
    end
    set_number(baseline + offset)
  end

  function service:dispose()
    local current = mp.get_property_number(property)
    if self.last_value == nil or current == nil or
      math.abs(current - self.last_value) < 0.01 then
      mp.set_property_number(property, baseline)
    end
    mp.set_property_native("user-data/osc/margins", {
      l = 0, r = 0, t = 0, b = 0
    })
    self.last_value, self.last_margin = nil, nil
  end

  return service
end

return subtitle_position
