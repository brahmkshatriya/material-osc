local keybinding_hints = {}

local MATCHERS = {
  pause = function(command)
    return command:match("^cycle%s+pause") or
      command:match("^cycle%-values%s+pause")
  end,
  mute = function(command)
    return command:match("^cycle%s+mute") or
      command:match("^cycle%-values%s+mute")
  end,
  ["volume-up"] = function(command)
    local amount = command:match(
      "^add%s+volume%s+([%+%-]?[%d%.]+)")
    return amount and tonumber(amount) and tonumber(amount) > 0
  end,
  ["volume-down"] = function(command)
    local amount = command:match(
      "^add%s+volume%s+([%+%-]?[%d%.]+)")
    return amount and tonumber(amount) and tonumber(amount) < 0
  end,
  ["speed-up"] = function(command)
    local amount = command:match(
      "^add%s+speed%s+([%+%-]?[%d%.]+)")
    if amount and tonumber(amount) then return tonumber(amount) > 0 end
    local factor = command:match(
      "^multiply%s+speed%s+([%d%.]+)")
    return factor and tonumber(factor) and tonumber(factor) > 1
  end,
  ["speed-down"] = function(command)
    local amount = command:match(
      "^add%s+speed%s+([%+%-]?[%d%.]+)")
    if amount and tonumber(amount) then return tonumber(amount) < 0 end
    local numerator, denominator = command:match(
      "^multiply%s+speed%s+([%d%.]+)%s*/%s*([%d%.]+)")
    if numerator and denominator and tonumber(denominator) ~= 0 then
      return tonumber(numerator) / tonumber(denominator) < 1
    end
    local factor = command:match(
      "^multiply%s+speed%s+([%d%.]+)")
    return factor and tonumber(factor) and tonumber(factor) < 1
  end,
  ontop = function(command)
    return command:match("^cycle%s+ontop") or
      command:match("^cycle%-values%s+ontop")
  end,
  fullscreen = function(command)
    return command:match("^cycle%s+fullscreen") or
      command:match("^cycle%-values%s+fullscreen")
  end,
  screenshot = function(command)
    return command == "screenshot" or command:match("^screenshot[%s%-]")
  end,
  subtitles = function(command)
    return command:match("^cycle%s+sub%-visibility") or
      command:match("^cycle%-values%s+sub%-visibility")
  end,
  ["playlist-next"] = function(command)
    return command:match("^playlist%-next")
  end,
  ["playlist-prev"] = function(command)
    return command:match("^playlist%-prev")
  end,
  ["open-settings"] = function(command)
    return command:find(
      "script-binding material_osc/material-osc-open-settings", 1, true)
  end,
  ["open-playlist"] = function(command)
    return command:find(
      "script-binding material_osc/material-osc-open-playlist", 1, true)
  end,
  ["temporary-speed"] = function(command)
    return command:find("hold-double-speed", 1, true) ~= nil
  end
}

local LABELS = {
  SPACE = "Space", ENTER = "Enter", KP_ENTER = "Enter", ESC = "Esc",
  LEFT = "←", RIGHT = "→", UP = "↑", DOWN = "↓",
  PGUP = "PgUp", PGDWN = "PgDn", HOME = "Home", END = "End",
  BS = "Backspace", DEL = "Delete", INS = "Insert",
  CTRL = "Ctrl", ALT = "Alt", SHIFT = "Shift", META = "Meta"
}

local PREFERRED_KEYS = {
  pause = "SPACE", mute = "m", ["volume-up"] = "0", ["volume-down"] = "9",
  ["speed-up"] = "]", ["speed-down"] = "[",
  ["temporary-speed"] = "c",
  fullscreen = "f", screenshot = "s", ontop = "T",
  subtitles = "v", ["playlist-next"] = ">", ["playlist-prev"] = "<",
  ["open-settings"] = "Ctrl+,", ["open-playlist"] = "Alt+p"
}

-- These bindings are registered by material-osc itself. Some mpv versions do
-- not expose script-owned weak bindings through input-bindings immediately, so
-- keep their declared defaults available for the corresponding tooltips.
local SCRIPT_DEFAULT_KEYS = {
  ["open-settings"] = "Ctrl+,",
  ["open-playlist"] = "Alt+p",
  ["temporary-speed"] = "c"
}

local function normalize_command(command)
  command = tostring(command or ""):gsub("^%s+", "")
  while true do
    local stripped
    for _, prefix in ipairs({"no-osd", "osd-auto", "osd-bar", "async"}) do
      local pattern = "^" .. prefix:gsub("%-", "%%-") .. "%s+"
      if command:match(pattern) then
        stripped = command:gsub(pattern, "", 1)
        break
      end
    end
    if not stripped then break end
    command = stripped
  end
  return command
end

local function keyboard_key(key)
  local upper = tostring(key or ""):upper()
  return upper ~= "" and not upper:find("MBTN", 1, true) and
    not upper:find("WHEEL", 1, true) and
    not upper:find("MOUSE", 1, true) and
    not upper:find("GAMEPAD", 1, true)
end

local function labels_for_key(key)
  local parts = {}
  for part in tostring(key):gmatch("[^+]+") do
    local upper = part:upper()
    parts[#parts + 1] = LABELS[upper] or
      (#part == 1 and part:upper() or part)
  end
  return {table.concat(parts, " + ")}
end

function keybinding_hints.new(args)
  local service = {}
  local cached_bindings, cached_at

  local function current_bindings()
    local now = args.now and args.now() or nil
    if not cached_bindings or not now or not cached_at or
      now - cached_at >= 0.5 then
      cached_bindings = args.bindings() or {}
      cached_at = now
    end
    return cached_bindings
  end

  function service:for_action(action)
    local matcher = MATCHERS[action]
    if not matcher then return nil end
    local best, best_score
    for index, binding in ipairs(current_bindings()) do
      local key = type(binding) == "table" and binding.key or nil
      local command = type(binding) == "table" and
        normalize_command(binding.cmd) or ""
      if keyboard_key(key) and matcher(command) then
        local priority = tonumber(binding.priority) or 0
        local strong = binding.is_weak == false and 1 or 0
        local preferred = tostring(key) == PREFERRED_KEYS[action] and 1 or 0
        local score = priority * 10000 + strong * 1000 +
          preferred * 100 - index / 10000
        if not best_score or score > best_score then
          best, best_score = key, score
        end
      end
    end
    if not best then best = SCRIPT_DEFAULT_KEYS[action] end
    if not best then return nil end
    return {key = best, labels = labels_for_key(best)}
  end

  return service
end

return keybinding_hints
