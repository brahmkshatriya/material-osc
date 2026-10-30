local schema = {}

local function number(options)
  return function(value)
    value = tonumber(value) or options.default
    if options.min then value = math.max(options.min, value) end
    if options.max then value = math.min(options.max, value) end
    return value
  end
end

local function enum(default, values)
  local accepted = {}
  for _, value in ipairs(values) do accepted[value] = true end
  return function(value)
    value = tostring(value or default):lower()
    return accepted[value] and value or default
  end
end

local function csv(pattern)
  return function(value)
    local entries, seen = {}, {}
    for raw in tostring(value or ""):gmatch(pattern) do
      local entry = raw:lower():match("^%s*(.-)%s*$")
      if entry ~= "" and not seen[entry] then
        seen[entry] = true
        entries[#entries + 1] = entry
      end
    end
    return table.concat(entries, ",")
  end
end

local definitions = {
  {name = "dpi_scale", default = "auto", group = "appearance"},
  {name = "vidscale", default = "no", group = "appearance",
    normalize = enum("no", {"shrink", "yes", "no"})},
  {name = "vidscale_reference", default = 720, group = "appearance",
    normalize = number({default = 720, min = 100})},
  {name = "vidscale_min", default = 0.35, group = "appearance",
    normalize = number({default = 0.35, min = 0.1, max = 1})},
  {name = "accent_color", default = "#00bbff", group = "appearance"},
  {name = "context_menu", default = true, group = "appearance"},
  {name = "tooltip", default = true, group = "appearance"},
  {name = "show_mini_seekbar", default = false, group = "appearance"},
  {name = "show_empty_screen", default = true, group = "appearance"},
  {name = "screenshot_button", default = true, group = "appearance"},
  {name = "pip_button", default = true, group = "appearance"},
  {name = "ontop_button", default = false, group = "appearance"},
  {name = "info_button", default = false, group = "appearance"},
  {name = "prev_next_beside_play", default = false, group = "appearance"},
  {name = "info_mbtn_left_command",
    default = "script-binding stats/display-page-1-toggle", group = "appearance"},
  {name = "window_controls", default = "auto", group = "appearance",
    normalize = enum("auto", {"auto", "yes", "no"})},

  {name = "mouse_timeout", default = 2, group = "behavior"},
  {name = "show_on_mouse_move", default = false, group = "behavior"},
  {name = "single_click_actions_enabled", default = true, group = "behavior"},
  {name = "drag_border", default = 16, group = "behavior",
    normalize = number({default = 16, min = 0})},
  {name = "seeking_zone_percentage", default = 15, group = "behavior",
    normalize = number({default = 15, min = 0, max = 50})},
  {name = "seek_step_seconds", default = 5, group = "behavior"},
  {name = "live_edge_offset_seconds", default = 2, group = "behavior",
    normalize = function(value)
      value = tonumber(value) or 2
      return value < 0 and -1 or value
    end},
  {name = "temporary_speed", default = 2, group = "behavior",
    normalize = number({default = 2, min = 0.01})},
  {name = "show_remaining_time", default = false, group = "behavior"},
  {name = "adjust_time_with_speed", default = true, group = "behavior"},
  {name = "adjust_subtitle_position", default = true, group = "behavior"},
  {name = "max_volume_percentage", default = 150, group = "behavior",
    normalize = number({default = 150, min = 100})},
  {name = "skip_intro_outro_chapters", default = "ask", group = "behavior",
    normalize = enum("ask", {"yes", "no", "ask"})},
  {name = "skip_intro_detection_texts",
    default = "intro,introduction,opening,op,opening theme", group = "behavior",
    normalize = csv("[^,]+")},
  {name = "skip_outro_detection_texts",
    default = "outro,ending,end credits,credits,closing,ed", group = "behavior",
    normalize = csv("[^,]+")},

  {name = "force_hwdec", default = false, group = "mpv"},
  {name = "force_display_resample", default = "auto", group = "mpv",
    normalize = enum("auto", {"auto", "yes", "no"})},
  {name = "force_force_window", default = "auto", group = "mpv",
    normalize = enum("auto", {"auto", "yes", "no"})},
  {name = "force_geometry", default = "auto", group = "mpv",
    normalize = enum("auto", {"auto", "yes", "no"})},
  {name = "force_disable_auto_resize", default = "auto", group = "mpv",
    normalize = enum("auto", {"auto", "yes", "no"})},
  {name = "directory_playlist", default = true, group = "playlist"},
  {name = "directory_playlist_sort", default = "name", group = "playlist",
    normalize = enum("name", {"name", "newest", "oldest"})},

  {name = "youtube_quality", default = "auto", group = "youtube",
    normalize = function(value)
      local height = tostring(value or "auto"):lower():match("^(%d+)p?$")
      return height and tostring(math.max(1, math.floor(tonumber(height)))) or
        "auto"
    end},
  {name = "sponsorblock_should_use", default = true, group = "sponsorblock"},
  {name = "sponsorblock_auto_skip_categories", default = "sponsor",
    group = "sponsorblock", normalize = csv("[%w_]+"),
    comment = "# SponsorBlock categories: sponsor,selfpromo,exclusive_access," ..
      "interaction,intro,outro,preview,hook,music_offtopic,poi_highlight,filler"},
  {name = "sponsorblock_ignore_categories",
    default = "interaction,preview,hook,exclusive_access", group = "sponsorblock",
    normalize = csv("[%w_]+")},
  {name = "sponsorblock_multicolored_segments", default = true,
    group = "sponsorblock"},
  {name = "sponsorblock_show_submit", default = true, group = "sponsorblock"},
  {name = "sponsorblock_show_voting", default = true, group = "sponsorblock"}
}

local by_name = {}
for _, definition in ipairs(definitions) do by_name[definition.name] = definition end

function schema.defaults()
  local values = {}
  for _, definition in ipairs(definitions) do
    values[definition.name] = definition.default
  end
  return values
end

function schema.normalize(values)
  for _, definition in ipairs(definitions) do
    local value = values[definition.name]
    if type(definition.default) == "string" and type(value) == "string" then
      local quote = value:sub(1, 1)
      if (quote == '"' or quote == "'") and value:sub(-1) == quote then
        value = value:sub(2, -2)
      end
    end
    values[definition.name] = definition.normalize and
      definition.normalize(value) or value
  end
  return values
end

function schema.sanitize(contents)
  local configured, lines, removed = {}, {}, false
  for line in (tostring(contents or "") .. "\n"):gmatch("(.-)\n") do
    local name = line:match("^%s*([%w_-]+)%s*=")
    if name and not by_name[name] then
      removed = true
    else
      lines[#lines + 1] = line
      if name then configured[name] = true end
    end
  end
  return table.concat(lines, "\n"):gsub("%s+$", ""), configured, removed
end

local function serialize(value)
  if type(value) == "boolean" then return value and "yes" or "no" end
  local text = tostring(value)
  if text:find("#", 1, true) then return '"' .. text .. '"' end
  return text
end

function schema.render_configuration(existing, values)
  local preserved, configured, removed = schema.sanitize(existing)
  local missing = {}
  for _, definition in ipairs(definitions) do
    if not configured[definition.name] then missing[#missing + 1] = definition end
  end
  if #missing == 0 and not removed then return existing, false end
  local lines = {}
  if preserved ~= "" then
    lines[#lines + 1] = preserved
    lines[#lines + 1] = ""
  else
    lines[#lines + 1] = "# material-osc configuration"
    lines[#lines + 1] = "# Changes are applied to running mpv instances."
    lines[#lines + 1] = ""
  end
  local comments = {}
  for _, definition in ipairs(missing) do
    if definition.comment and not comments[definition.comment] and
      not preserved:find(definition.comment, 1, true) then
      lines[#lines + 1] = definition.comment
      comments[definition.comment] = true
    end
    lines[#lines + 1] = definition.name .. "=" ..
      serialize(values[definition.name])
  end
  return table.concat(lines, "\n") .. "\n", true
end

schema.definitions = definitions

return schema
