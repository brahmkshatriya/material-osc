local animation = {}

local function default_clock()
  return mp.get_time()
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

function animation.lerp(from, to, progress)
  return from + (to - from) * progress
end

function animation.smooth_step(progress)
  return progress * progress * (3 - 2 * progress)
end

function animation.spring(args)
  args = args or {}
  local clock = args.clock or default_clock
  local value = {
    value = args.initial or 0,
    target = args.initial or 0,
    velocity = 0,
    stiffness = args.stiffness or 360,
    damping = args.damping or 24,
    epsilon = args.epsilon or 0.001,
    velocity_epsilon = args.velocity_epsilon or 0.01,
    last_update = clock()
  }

  function value:set_target(target) self.target = target end

  function value:snap(target)
    self.value, self.target, self.velocity = target, target, 0
    self.last_update = clock()
  end

  function value:update(now)
    local dt = clamp(now - self.last_update, 0, 1 / 30)
    self.last_update = now
    -- Keep spring response independent from the overlay refresh rate. A
    -- single 60 Hz Euler step adds enough numerical damping to erase the
    -- overshoot that was visible when mpv drove the OSC at 120/240 Hz.
    local steps = math.max(1, math.ceil(dt * 240))
    local step = dt / steps
    for _ = 1, steps do
      local acceleration = self.stiffness * (self.target - self.value) -
        self.damping * self.velocity
      self.velocity = self.velocity + acceleration * step
      self.value = self.value + self.velocity * step
    end

    if math.abs(self.target - self.value) < self.epsilon and
      math.abs(self.velocity) < self.velocity_epsilon then
      self.value, self.velocity = self.target, 0
    end
    return self.value
  end

  function value:is_running()
    return self.value ~= self.target or self.velocity ~= 0
  end

  return value
end

function animation.tween(args)
  args = args or {}
  local clock = args.clock or default_clock
  local value = {
    value = args.initial or 0,
    from = args.initial or 0,
    target = args.initial or 0,
    started_at = clock(),
    duration = args.duration or 0.18,
    running = false
  }

  function value:set_target(target, now, duration)
    now = now or clock()
    if target == self.target and self.running then return end
    if target == self.value and not self.running then
      self.target = target
      return
    end
    self.from, self.target, self.started_at = self.value, target, now
    self.duration, self.running = duration or self.duration, true
  end

  function value:snap(target)
    self.value, self.from, self.target = target, target, target
    self.running = false
  end

  function value:update(now)
    if not self.running then return self.value end
    local progress = clamp((now - self.started_at) / math.max(0.001, self.duration), 0, 1)
    local eased = progress * progress * (3 - 2 * progress)
    self.value = self.from + (self.target - self.from) * eased
    if progress >= 1 then self.value, self.running = self.target, false end
    return self.value
  end

  function value:is_running() return self.running end

  return value
end

return animation
