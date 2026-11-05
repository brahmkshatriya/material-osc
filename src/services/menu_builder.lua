-- Builds the context menu from material-osc-menu.conf, or from the default menu
-- below until that file exists. See DEFAULT_CONTENTS for the format.
--
-- Items: {title = "Label\tShortcut", icon, cmd, builtin,
-- type = nil|"submenu"|"separator", state = {"checked", ...}, submenu = {...}}.
-- Other scripts send the same shape to fill a slot: they wait for the
-- "menu-ready <client>" broadcast and send
-- "script-message-to <client> update <tag> <json>".
local menu_builder = {}

menu_builder.FILE = "material-osc-menu.conf"

menu_builder.DEFAULT_CONTENTS = [[
# material-osc context menu
#
#   Title | icon | command
#
# icon is the name of any Material Symbol (fonts.google.com/icons) and can be
# left empty. " > " nests submenus and "-" adds a separator. Changes apply the
# next time the menu opens. Customize is always added as the last item.
#
#   Screenshot | photo_camera | screenshot
#   Audio | volume_up
#   Audio > Mute | | cycle mute #@state=(mute and 'checked')
#   Audio > -
#   Audio > Tracks | | #@tracks/audio
#
# #@ tags make an item dynamic:
#   #@tracks, #@tracks/video, #@tracks/audio, #@tracks/sub,
#   #@tracks/sub-secondary, #@chapters, #@editions, #@playlist,
#   #@audio-devices, #@profiles    list those as a submenu
#   #@state=<expression>           a Lua expression returning checked, disabled
#                                  or hidden; names read mpv properties
#   #@<anything else>              a slot other scripts can fill
#
# @ items are material-osc's own actions. They change with the media and can be
# renamed or get another icon: Save | star | @add-bookmark

@copy-subtitle
@copy-timestamp
@copy-media
-
@ab-loop
@add-bookmark
-
@media-information
@open-media
-
@keybindings
]]

-- long track, chapter and playlist titles are cut at this many characters
local MAX_TITLE_LENGTH = 80

local DYNAMIC_SUBMENUS = {
  ["tracks"] = true, ["tracks/video"] = true, ["tracks/audio"] = true,
  ["tracks/sub"] = true, ["tracks/sub-secondary"] = true,
  ["chapters"] = true, ["editions"] = true, ["playlist"] = true,
  ["audio-devices"] = true, ["profiles"] = true
}

local TRACK_TYPES = {
  ["tracks/video"] = {"video", "vid"},
  ["tracks/audio"] = {"audio", "aid"},
  ["tracks/sub"] = {"sub", "sid"},
  ["tracks/sub-secondary"] = {"sub", "secondary-sid"}
}

-- shorter, more familiar names for common codecs
local CODEC_NAMES = {
  {"mpeg2", "mpeg2"}, {"dvvideo", "dv"}, {"pcm", "pcm"}, {"pgs", "pgs"},
  {"subrip", "srt"}, {"vtt", "vtt"}, {"dvd_sub", "vob"}, {"dvb_sub", "dvb"},
  {"dvb_tele", "teletext"}, {"arib", "arib"}
}

local PROFILE_SKIP = {default = true, encoding = true, libmpv = true}

local function trim(value)
  return (tostring(value or ""):match("^%s*(.-)%s*$"))
end

-- quote a value for an mpv command string
local function quote(value)
  return '"' .. tostring(value):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

local function copy_item(item)
  local copy = {}
  for key, value in pairs(item) do copy[key] = value end
  return copy
end

function menu_builder.new(args)
  local mp, utils, msg = args.mp, args.utils, args.msg
  local service = {started = false, generation = 0}

  local root = {}         -- static tree parsed from the menu file
  local tagged = {}       -- {item = <item in root>, original = {...}, tags = {...}}
  local by_tag = {}       -- tag -> tagged entry (entry.override: "update" data)
  local overrides = {}    -- tag -> "update" data, kept when the file is reloaded
  local contents = nil    -- the text root was parsed from
  local compiled = {}     -- state expression -> function
  local observed = {}     -- property name -> true
  local dirty = true
  local tree = nil

  local function mark_dirty() dirty = true end

  -- reads a property and remembers to rebuild when it changes
  local function read(name)
    if not observed[name] then
      observed[name] = true
      mp.observe_property(name, "native", mark_dirty)
    end
    local value = mp.get_property_native(name)
    return value
  end

  local function shorten(value)
    value = tostring(value or "")
    local limit = MAX_TITLE_LENGTH
    if #value <= limit then return value end
    -- cut on a UTF-8 character boundary
    local count = 0
    for position in value:gmatch("()[%z\1-\127\194-\244][\128-\191]*") do
      if count == limit then return value:sub(1, position - 1) .. "..." end
      count = count + 1
    end
    return value
  end

  -- menu file ----------------------------------------------------------------

  local function read_menu_file()
    local path = mp.find_config_file("script-opts/" .. menu_builder.FILE)
    local file = path and io.open(path, "rb")
    if not file then return menu_builder.DEFAULT_CONTENTS end
    local content = file:read("*a")
    file:close()
    return content or ""
  end

  -- "#@a #@state=(x and 'checked')" -> {"a", "state=(x and 'checked')"}
  local function parse_tags(command)
    local tags = {}
    local start = command:find("#@", 1, true)
    if not start then return tags end
    for tag in (command:sub(start) .. "#@"):gmatch("#@(.-)%s*#@") do
      tag = trim(tag)
      if tag ~= "" then tags[#tags + 1] = tag end
    end
    return tags
  end

  local function add_tags(item, command)
    local tags = parse_tags(command)
    if #tags == 0 then return end
    local entry = {item = item, original = copy_item(item), tags = tags}
    tagged[#tagged + 1] = entry
    for _, tag in ipairs(tags) do
      if not tag:match("^state=") then
        local name = tag:match("^%S+")
        by_tag[name] = entry
        entry.override = overrides[name] or entry.override
      end
    end
  end

  local function parse(content)
    root, tagged, by_tag = {}, {}, {}
    local named = {}
    for line in content:gsub("^\239\187\191", ""):gmatch("[^\r\n]+") do
      line = trim(line)
      if line ~= "" and line:sub(1, 1) ~= "#" then
        local title, icon, command = line:match("^(.-)|(.-)|(.*)$")
        if not title then title, icon = line:match("^(.-)|(.*)$") end
        title, icon, command = trim(title or line), trim(icon), trim(command)
        if icon == "" then icon = nil end

        local parts = {}
        for part in (title .. ">"):gmatch("(.-)>") do parts[#parts + 1] = trim(part) end
        local target, id = root, ""
        for index, name in ipairs(parts) do
          id = id .. "\0" .. name
          local existing = named[id]
          if index < #parts then
            if not existing then
              existing = {title = name}
              target[#target + 1] = existing
              named[id] = existing
            end
            existing.type, existing.cmd = "submenu", nil
            existing.submenu = existing.submenu or {}
            target = existing.submenu
          elseif name == "-" then
            target[#target + 1] = {type = "separator"}
          elseif existing and command == "" then
            -- "Audio | volume_up" sets the icon of the Audio submenu
            existing.icon = icon or existing.icon
          else
            local item_name = name:match("^@[%w-]+$")
            local builtin = command:match("^@([%w-]+)$") or
              (item_name and item_name:sub(2))
            local item = {title = not item_name and name or nil, icon = icon}
            if builtin then
              item.builtin = builtin
            elseif command ~= "" then
              item.cmd = command
            end
            target[#target + 1] = item
            named[id] = named[id] or item
            if item.cmd then add_tags(item, command) end
          end
        end
      end
    end
  end

  -- state expressions --------------------------------------------------------

  -- identifiers that aren't Lua globals read mpv properties ("_" -> "-");
  -- p["name"] reads any property by its exact name
  local properties = setmetatable({}, {
    __index = function(_, name) return read((tostring(name):gsub("_", "-"))) end
  })
  local environment = setmetatable({p = properties}, {
    __index = function(_, name)
      local value = _G[name]
      if value ~= nil then return value end
      return read((tostring(name):gsub("_", "-")))
    end
  })

  local function compile(expression)
    local chunk = compiled[expression]
    if chunk then return chunk end
    local code = "return " .. expression
    local err
    if setfenv then
      chunk, err = loadstring(code, "menu state")
      if chunk then setfenv(chunk, environment) end
    else
      chunk, err = load(code, "menu state", "t", environment)
    end
    if not chunk then
      msg.warn("menu: invalid state expression '" .. expression .. "': " ..
        tostring(err))
      chunk = function() return nil end
    end
    compiled[expression] = chunk
    return chunk
  end

  local function evaluate_state(expression)
    local ok, result = pcall(compile(expression))
    if not ok then
      msg.verbose("menu: state expression '" .. expression .. "' failed: " ..
        tostring(result))
      return nil
    end
    local states = {}
    if type(result) == "string" then
      for state in result:gmatch("[^,%s]+") do states[#states + 1] = state end
    end
    return states
  end

  -- dynamic submenus ---------------------------------------------------------

  local function codec_name(codec)
    codec = tostring(codec or "")
    for _, pair in ipairs(CODEC_NAMES) do
      if codec:find(pair[1], 1, true) then return pair[2] end
    end
    return codec
  end

  local function track_title(track, with_type)
    local kind = tostring(track.type or "")
    local codec = codec_name(track.codec)
    local title = tostring(track.title or "")
    if track.external and title ~= "" then
      local base = tostring(read("filename/no-ext") or "")
      if base ~= "" then
        local escaped = base:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")
        title = title:gsub(escaped .. "%.?", "")
      end
      if title:lower() == codec:lower() then title = "" end
    end
    if title == "" then
      title = kind:sub(1, 1):upper() .. kind:sub(2) .. " " .. tostring(track.id)
    else
      title = shorten(title)
    end

    local hints = {}
    if codec ~= "" then hints[#hints + 1] = codec end
    if track["demux-h"] then
      hints[#hints + 1] = track["demux-w"] and
        (track["demux-w"] .. "x" .. track["demux-h"]) or (track["demux-h"] .. "p")
    end
    if track["demux-fps"] then
      hints[#hints + 1] = string.format("%.5g fps", track["demux-fps"])
    end
    if track["audio-channels"] then
      hints[#hints + 1] = track["audio-channels"] .. " ch"
    end
    if track["demux-samplerate"] then
      hints[#hints + 1] = string.format("%.5g kHz", track["demux-samplerate"] / 1000)
    end
    if track["demux-bitrate"] then
      hints[#hints + 1] = string.format("%.5g kbps", track["demux-bitrate"] / 1000)
    end
    if #hints > 0 then title = title .. " [" .. table.concat(hints, ", ") .. "]" end
    if track.forced then title = title .. " (forced)" end
    if track.external then title = title .. " (external)" end
    if track.default then title = title .. " (*)" end

    title = title
    if with_type then title = kind:sub(1, 1):upper() .. ": " .. title end
    local lang = tostring(track.lang or "")
    if lang ~= "" then title = title .. "\t" .. lang:upper() end
    return title
  end

  local function track_items(kind, property, with_type)
    local items = {}
    local current = tonumber(read(property)) or -1
    for _, track in ipairs(read("track-list") or {}) do
      if track.type == kind then
        local state = {}
        if track.selected then
          state[#state + 1] = "checked"
          -- selected through the other subtitle slot (main vs secondary)
          if track.id ~= current then state[#state + 1] = "disabled" end
        end
        items[#items + 1] = {
          title = track_title(track, with_type),
          cmd = string.format("set %s %d", property, track.id),
          state = state
        }
      end
    end
    if #items > 0 then
      local title = current > 0 and "Off" or "Auto"
      if with_type then title = kind:sub(1, 1):upper() .. ": " .. title end
      items[#items + 1] = {
        title = title,
        cmd = string.format("set %s %s", property, current > 0 and "no" or "auto")
      }
    end
    return items
  end

  local function all_tracks()
    local items = {}
    for _, group in ipairs({{"video", "vid"}, {"audio", "aid"}, {"sub", "sid"}}) do
      local group_items = track_items(group[1], group[2], true)
      if #items > 0 and #group_items > 0 then items[#items + 1] = {type = "separator"} end
      for _, item in ipairs(group_items) do items[#items + 1] = item end
    end
    return items
  end

  local function chapters()
    local items = {}
    local current = tonumber(read("chapter")) or -1
    for index, chapter in ipairs(read("chapter-list") or {}) do
      local title = shorten(chapter.title)
      if title == "" then title = "Chapter " .. index end
      local time = tonumber(chapter.time) or 0
      items[#items + 1] = {
        title = title .. "\t" .. string.format("[%02d:%02d:%02d]",
          math.floor(time / 3600), math.floor(time / 60) % 60, math.floor(time) % 60),
        cmd = string.format("seek %f absolute", time),
        state = index == current + 1 and {"checked"} or {}
      }
    end
    return items
  end

  local function editions()
    local items = {}
    local current = tonumber(read("current-edition")) or -1
    for index, edition in ipairs(read("edition-list") or {}) do
      local title = shorten(edition.title)
      if title == "" then title = "Edition " .. index end
      if edition.default then title = title .. " [default]" end
      items[#items + 1] = {
        title = title,
        cmd = string.format("set edition %d", index - 1),
        state = index == current + 1 and {"checked"} or {}
      }
    end
    return items
  end

  local function audio_devices()
    local items = {}
    local current = read("audio-device")
    for _, device in ipairs(read("audio-device-list") or {}) do
      items[#items + 1] = {
        title = device.description or device.name,
        cmd = "set audio-device " .. quote(device.name),
        state = device.name == current and {"checked"} or {}
      }
    end
    return items
  end

  local function playlist_title(entry, index)
    local title = tostring(entry.title or "")
    local extension = ""
    if entry.filename and entry.filename ~= "" then
      local _, name = utils.split_path(entry.filename)
      local stem, ext = name:match("^(.+)%.([%w_-]+)$")
      if title == "" then title = stem or name end
      extension = ext or ""
    end
    title = title ~= "" and shorten(title) or ("Item " .. index)
    if extension ~= "" then title = title .. "\t" .. extension:upper() end
    return title
  end

  local function playlist()
    local items = {}
    local list = read("playlist") or {}
    if #list == 0 then return items end
    for index, entry in ipairs(list) do
      items[#items + 1] = {
        title = playlist_title(entry, index - 1),
        cmd = string.format("playlist-play-index %d", index - 1),
        state = (entry.playing or entry.current) and {"checked"} or {}
      }
    end
    return items
  end

  local function profiles()
    local items = {}
    for _, profile in ipairs(read("profile-list") or {}) do
      local name = tostring(profile.name or "")
      if name ~= "" and not PROFILE_SKIP[name] and not name:find("gui", 1, true) then
        items[#items + 1] = {
          title = name,
          cmd = "show-text " .. quote(name) .. "; apply-profile " .. quote(name)
        }
      end
    end
    return items
  end

  local function dynamic_submenu(tag)
    if tag == "tracks" then return all_tracks() end
    local track = TRACK_TYPES[tag]
    if track then return track_items(track[1], track[2], false) end
    if tag == "chapters" then return chapters() end
    if tag == "editions" then return editions() end
    if tag == "playlist" then return playlist() end
    if tag == "audio-devices" then return audio_devices() end
    if tag == "profiles" then return profiles() end
  end

  -- building -----------------------------------------------------------------

  local function apply(entry)
    local item = entry.item
    for key in pairs(item) do item[key] = nil end
    for key, value in pairs(entry.override or entry.original) do
      item[key] = value
    end
    if (not item.title or item.title == "") then item.title = entry.original.title end
    item.icon = item.icon or entry.original.icon

    for _, tag in ipairs(entry.tags) do
      local expression = tag:match("^state=(.*)$")
      if expression then
        local states = evaluate_state(expression)
        if states then item.state = states end
      else
        local submenu = dynamic_submenu(tag:match("^%S+"))
        if submenu then
          item.type, item.cmd, item.submenu = "submenu", nil, submenu
        end
      end
    end
  end

  -- commands are compared without whitespace differences and comments
  local function normalize_command(command)
    local text = tostring(command or ""):gsub("%s+#.*$", "")
    return trim(text:gsub("%s+", " "))
  end

  -- shows the key already bound to an item's command next to it
  local function add_shortcuts(items, keys)
    for _, item in ipairs(items) do
      if item.submenu then
        add_shortcuts(item.submenu, keys)
      elseif item.cmd and not tostring(item.title or ""):find("\t", 1, true) then
        item.shortcut = keys[normalize_command(item.cmd)]
      end
    end
  end

  local function bound_keys()
    local keys, priorities = {}, {}
    for _, binding in ipairs(read("input-bindings") or {}) do
      local key, command = binding.key, normalize_command(binding.cmd)
      local priority = tonumber(binding.priority) or 0
      if key and command ~= "" and command ~= "ignore" and
        not key:find("MBTN", 1, true) and
        not key:find("WHEEL", 1, true) and
        (not priorities[command] or priority > priorities[command]) then
        priorities[command] = priority
        keys[command] = args.format_key and args.format_key(key) or key
      end
    end
    return keys
  end

  -- the whole menu, rebuilt only when something it depends on changed
  function service:tree()
    self:start()
    if dirty or not tree then
      dirty = false
      for _, entry in ipairs(tagged) do apply(entry) end
      add_shortcuts(root, bound_keys())
      tree = root
      self.generation = self.generation + 1
    end
    return tree
  end

  -- picks up edits to the menu file
  function service:reload()
    local content = read_menu_file()
    if content == contents then return end
    contents = content
    parse(content)
    mark_dirty()
  end

  -- messaging API for other scripts --------------------------------------------

  local function announce()
    mp.commandv("script-message", "menu-ready", mp.get_script_name())
  end

  function service:start()
    if self.started then return end
    self.started = true
    self:reload()

    -- "get <tag> <client>": reply with the current item for that tag
    mp.register_script_message("get", function(tag, client)
      if not client or client == "" then return end
      self:tree()
      local entry = by_tag[tag]
      local reply = {keyword = tag}
      if entry then reply.item = entry.item else reply.error = "keyword not found" end
      mp.commandv("script-message-to", client, "menu-get-reply",
        utils.format_json(reply))
    end)

    -- "update <tag> <json>": replace the item for that tag
    mp.register_script_message("update", function(tag, json)
      local entry = by_tag[tag]
      if not entry then
        msg.debug("menu: update for unknown tag " .. tostring(tag))
        return
      end
      local data = json and utils.parse_json(json)
      if type(data) ~= "table" or next(data) == nil then
        msg.debug("menu: ignored invalid update for " .. tostring(tag))
        return
      end
      if not data.type or data.type == "" then data.type = entry.original.type end
      entry.override = data
      overrides[tag] = data
      mark_dirty()
    end)

    -- announce now and once more after every script had time to load
    announce()
    mp.add_timeout(1, announce)
  end

  return service
end

return menu_builder
