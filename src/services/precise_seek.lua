-- Precise seeking (YouTube-style): pull up while dragging the seekbar to
-- switch to a zoomed-in timeline. The main video shows the exact frame live.
-- After releasing, the mode stays open: two-finger horizontal swipes step
-- through time, vertical swipes and the arrow keys step single frames,
-- dragging on the video scrubs finely, a click or Enter confirms and Esc
-- cancels back to where precise seeking started.
local precise_seek = {}

local BINDING_PREFIX = "material-osc-precise-"

function precise_seek.new(args)
  local mp, runtime, opts = args.mp, args.runtime, args.opts
  local state = runtime.seek.precise
  local service = {}
  local bindings = {}

  local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
  end

  local function duration()
    return tonumber(runtime.snapshot.duration) or
      mp.get_property_number("duration", 0) or 0
  end

  function service:active() return state.active == true end

  -- position currently shown: the pending target, else the playback position
  function service:position()
    return state.target or mp.get_property_number("time-pos", 0) or 0
  end

  -- seconds covered by one pixel of the seekbar while zoomed in
  function service:seconds_per_pixel()
    local span = math.min(tonumber(opts.precise_seek_span) or 30, duration())
    return span / math.max(1, state.bar_width or 1)
  end

  local function seek_to(position)
    local total = duration()
    if total <= 0 then return end
    position = clamp(position, 0, total)
    state.target = position
    if runtime.seek.dragging then runtime.seek.position = position end
    -- mpv coalesces queued seeks, so only the latest target is decoded
    mp.commandv("seek", string.format("%.6f", position), "absolute+exact")
    args.render_dynamic()
  end

  function service:seek_to(position) seek_to(position) end

  -- jump to the time under x on the filmstrip (centered on the playhead)
  function service:jump_to_x(x)
    if not state.strip_center then return end
    seek_to(self:position() + (x - state.strip_center) * self:seconds_per_pixel())
  end

  function service:step_seconds(delta)
    seek_to(self:position() + delta)
  end

  -- frame steps issued while one is still decoding would be merged by mpv,
  -- so queue them and send the total once the current step has landed
  function service:step_frames(frames)
    if frames == 0 then return end
    state.target = nil
    -- a step that cannot move (e.g. at the first frame) never reports back
    if state.stepping and mp.get_time() - (state.step_started or 0) < 1 then
      state.pending_frames = (state.pending_frames or 0) + frames
      return
    end
    state.stepping, state.step_started = true, mp.get_time()
    -- the seek flag steps frames without briefly resuming playback
    mp.commandv("frame-step", tostring(frames), "seek")
    args.render_dynamic()
  end

  mp.register_event("playback-restart", function()
    if not state.stepping then return end
    state.stepping = false
    local pending = state.pending_frames or 0
    state.pending_frames = 0
    if pending ~= 0 and state.active then service:step_frames(pending) end
  end)

  -- fine scrubbing: horizontal pointer movement relative to where it started.
  -- invert: dragging the filmstrip moves it like film (left = later)
  function service:begin_scrub(x, invert)
    state.scrub = {
      x = x, position = self:position(), moved = false, invert = invert == true
    }
  end

  function service:scrub_to(x)
    local scrub = state.scrub
    if not scrub then return end
    if not scrub.moved and math.abs(x - scrub.x) < 3 then return end
    scrub.moved = true
    local direction = scrub.invert and -1 or 1
    seek_to(scrub.position + direction * (x - scrub.x) * self:seconds_per_pixel())
  end

  -- returns true when the pointer actually scrubbed (not just a click)
  function service:end_scrub()
    local scrub = state.scrub
    state.scrub = nil
    return scrub ~= nil and scrub.moved
  end

  -- input while active ----------------------------------------------------

  local function add_binding(key, handler, complex)
    local name = BINDING_PREFIX .. key:lower()
    mp.add_forced_key_binding(key, name, handler,
      complex and {complex = true, repeatable = true} or {repeatable = true})
    bindings[#bindings + 1] = name
  end

  local function wheel_seconds(direction)
    return function(event)
      if event.event == "up" then return end
      local scale = tonumber(event.scale) or 1
      if scale <= 0 then scale = 1 end
      local invert = opts.precise_seek_invert_swipe and -1 or 1
      service:step_seconds(direction * invert * scale *
        (tonumber(opts.precise_seek_step) or 2))
    end
  end

  -- vertical swipes report many small deltas: accumulate them into frames
  local function wheel_frames(direction)
    return function(event)
      if event.event == "up" then return end
      local scale = tonumber(event.scale) or 1
      if scale <= 0 then scale = 1 end
      state.frame_acc = (state.frame_acc or 0) + direction * scale
      local frames = state.frame_acc >= 0 and math.floor(state.frame_acc) or
        math.ceil(state.frame_acc)
      if frames ~= 0 then
        state.frame_acc = state.frame_acc - frames
        service:step_frames(frames)
      end
    end
  end

  local function bind_keys()
    -- swiping two fingers right (WHEEL_LEFT on Windows touchpads) moves
    -- forward, matching the regular seekbar swipe in input.conf
    add_binding("WHEEL_LEFT", wheel_seconds(1), true)
    add_binding("WHEEL_RIGHT", wheel_seconds(-1), true)
    add_binding("WHEEL_UP", wheel_frames(1), true)
    add_binding("WHEEL_DOWN", wheel_frames(-1), true)
    add_binding("RIGHT", function() service:step_frames(1) end)
    add_binding("LEFT", function() service:step_frames(-1) end)
    add_binding("Shift+RIGHT", function()
      service:step_seconds(tonumber(opts.precise_seek_step) or 2)
    end)
    add_binding("Shift+LEFT", function()
      service:step_seconds(-(tonumber(opts.precise_seek_step) or 2))
    end)
    add_binding("ENTER", function() service:exit(true) end)
    add_binding("KP_ENTER", function() service:exit(true) end)
    add_binding("ESC", function() service:exit(false) end)
  end

  local function unbind_keys()
    for _, name in ipairs(bindings) do mp.remove_key_binding(name) end
    bindings = {}
  end

  -- lifecycle ---------------------------------------------------------------

  function service:enter(position, bar_width)
    if state.active or duration() <= 0 then return false end
    state.active = true
    state.bar_width = bar_width
    state.origin = mp.get_property_number("time-pos", 0) or 0
    state.was_paused = mp.get_property_native("pause") == true
    state.frame_acc = 0
    state.target = nil
    mp.set_property_bool("pause", true)
    if service.on_active_changed then service.on_active_changed(true) end
    bind_keys()
    if position then seek_to(position) end
    args.render()
    return true
  end

  -- confirm: keep the new position (resume if it was playing)
  -- cancel: return to where precise seeking started
  function service:exit(confirm)
    if not state.active then return end
    state.active = false
    state.scrub = nil
    state.stepping, state.pending_frames = false, 0
    unbind_keys()
    if service.on_active_changed then service.on_active_changed(false) end
    if not confirm and state.origin then
      mp.commandv("seek", string.format("%.6f", state.origin), "absolute+exact")
    end
    state.target = nil
    if not state.was_paused then mp.set_property_bool("pause", false) end
    args.render()
  end

  -- resuming playback by any other means (space, play button) confirms
  mp.observe_property("pause", "bool", function(_, paused)
    if state.active and paused == false then
      state.was_paused = true
      service:exit(true)
    end
  end)
  mp.register_event("end-file", function()
    if state.active then
      state.was_paused = true
      service:exit(true)
    end
  end)

  return service
end

return precise_seek
