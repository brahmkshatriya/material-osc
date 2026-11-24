local subtitle_position = {}

function subtitle_position.new(args)
  local mp = args.mp
  local property = "sub-pos"
  local offset_animation = args.animation.spring({
    initial = 0,
    stiffness = args.spring_stiffness or 420,
    damping = args.spring_damping or 32,
    clock = function() return mp.get_time() end
  })
  local service = {
    property = property,
    baseline = mp.get_property_number(property, 100) or 100,
    last_value = nil,
    last_margin = nil,
    offset_animation = offset_animation,
    initialized = false,
    enabled = args.enabled ~= false
  }
  -- sub-pos from mpv's config, before anything moves it
  service.configured = service.baseline

  local function set_number(value)
    value = math.floor(value * 100 + 0.5) / 100
    if service.last_value ~= nil and
      math.abs(service.last_value - value) < 0.005 then return end
    service.last_value = value
    mp.set_property_number(property, value)
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

  local function observe_position(_, value)
    value = tonumber(value)
    if value == nil then return end
    if service.last_value == nil or
      math.abs(value - service.last_value) >= 0.01 then
      service.baseline = value
    end
  end
  mp.observe_property(property, "native", observe_position)

  -- the user's chosen position; the lift above the OSC is applied on top
  function service:set_baseline(value)
    self.baseline = value
    set_number(value)
  end

  function service:set_enabled(enabled)
    enabled = enabled ~= false
    if self.enabled == enabled then return false end
    self.enabled = enabled
    if not enabled then
      set_number(self.baseline)
      publish_margin(0)
      self.initialized = false
      self.offset_animation:snap(0)
    end
    return true
  end

  function service:update(controller_height, visibility_target, viewport_height,
      now, enabled)
    self:set_enabled(enabled)
    if not self.enabled then return end
    viewport_height = math.max(1, tonumber(viewport_height) or 1)
    controller_height = math.max(0, tonumber(controller_height) or 0)
    visibility_target = math.max(
      0, math.min(1, tonumber(visibility_target) or 0))
    now = tonumber(now) or mp.get_time()
    local desired_pixels = controller_height * visibility_target
    self.initialized = true
    self.offset_animation:set_target(desired_pixels)
    self.offset_animation:update(now)
    local occupied_pixels = self.offset_animation.value
    publish_margin(occupied_pixels / viewport_height)

    local value = self.baseline
    local sid = mp.get_property_native("sid")
    local subtitle_selected =
      sid ~= nil and sid ~= false and sid ~= "no" and sid ~= 0
    if subtitle_selected and
      mp.get_property("sub-align-y", "bottom") == "bottom" then
      local adjusted = math.max(
        0, 100 - occupied_pixels * 100 / viewport_height)
      -- below mpv's bottom (sub-pos > 100), rise only as far as the OSC shows
      local shown = controller_height > 0 and
        math.min(1, occupied_pixels / controller_height) or 0
      adjusted = adjusted + math.max(0, self.baseline - 100) * (1 - shown)
      if self.baseline >= adjusted then value = adjusted end
    end
    set_number(value)
  end

  function service:is_running()
    return self.enabled and self.initialized and
      self.offset_animation:is_running()
  end

  function service:dispose()
    mp.unobserve_property(observe_position)
    local current = mp.get_property_number(property)
    if self.last_value == nil or current == nil or
      math.abs(current - self.last_value) < 0.01 then
      mp.set_property_number(property, self.baseline)
    end
    mp.set_property_native("user-data/osc/margins", {
      l = 0, r = 0, t = 0, b = 0
    })
    self.last_value, self.last_margin = nil, nil
    self.initialized = false
    self.offset_animation:snap(0)
  end

  return service
end

return subtitle_position
