-- Builds the right-click menu from "#menu:" comments in input.conf:
--
--   s       screenshot     #menu: Video > Take Screenshot
--   _       ignore         #menu: Video > -
--   _       ignore         #menu: Tracks #@tracks
--   Space   cycle pause    #menu: Pause #@state=(pause and 'checked')
--
-- " > " nests submenus, "-" is a separator and the key (unless "_") is shown
-- as the shortcut. "#@" tags make an entry dynamic:
--   tracks, tracks/video, tracks/audio, tracks/sub, tracks/sub-secondary,
--   chapters, editions, playlist, audio-devices, profiles
--                     turn the entry into a generated submenu
--   state=<lua expr>  evaluated against mpv properties (pause, idle_active,
--                     p["sub-visibility"], ...); returns states such as
--                     "checked", "disabled" or "hidden" (comma separated)
--   anything else     a slot other scripts fill: they wait for the
--                     "menu-ready <client>" broadcast and send
--                     "script-message-to <client> update <tag> <json>"
--
-- Items: {title = "Label\tShortcut", cmd, type = nil|"submenu"|"separator",
-- state = {"checked", ...}, submenu = {...}}. Scripts send the same shape.
local menu_builder = {}

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
  local opts = args.opts or {}
  local service = {started = false}

  local root = {}         -- static tree parsed from input.conf
  local tagged = {}       -- {item = <item in root>, original = {...}, tags = {...}}
  local by_tag = {}       -- tag -> tagged entry (entry.override: "update" data)
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

  local function max_title_length()
    return tonumber(opts.menu_max_title_length) or 80
  end

  local function shorten(value)
    value = tostring(value or "")
    local limit = max_title_length()
    if limit <= 0 or #value <= limit then return value end
    -- cut on a UTF-8 character boundary
    local count = 0
    for position in value:gmatch("()[%z\1-\127\194-\244][\128-\191]*") do
      if count == limit then return value:sub(1, position - 1) .. "..." end
      count = count + 1
    end
    return value
  end

  -- input.conf ---------------------------------------------------------------

  local function read_input_conf()
    local configured = mp.get_property("input-conf", "") or ""
    if configured:sub(1, 9) == "memory://" then return configured:sub(10) end
    if configured == "" then configured = "~~/input.conf" end
    local path = mp.command_native({"expand-path", configured})
    local file = path and io.open(path, "rb")
    if not file then
      msg.verbose("menu: cannot read " .. tostring(path))
      return nil
    end
    local content = file:read("*a")
    file:close()
    return content
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

  local function parse(content)
    root, tagged, by_tag = {}, {}, {}
    local submenus = {}
    for line in content:gmatch("[^\r\n]+") do
      local key, command = line:match("^%s*([^%s#]%S*)%s+(.-)%s*$")
      local title = command and command:match("#menu:%s*(.*)$")
      if title then
        -- anything after another "#" is a comment or a tag, not the title
        title = trim(title:match("^(.-)%s*#") or title)
        local parts = {}
        for part in (title .. ">"):gmatch("(.-)>") do parts[#parts + 1] = trim(part) end
        if #parts == 1 and parts[1] == "" then parts = {} end

        local target, id = root, ""
        for index, name in ipairs(parts) do
          if index < #parts then
            id = id .. "\0" .. name
            if not submenus[id] then
              submenus[id] = {}
              target[#target + 1] = {type = "submenu", title = name,
                submenu = submenus[id]}
            end
            target = submenus[id]
          elseif name == "-" then
            target[#target + 1] = {type = "separator"}
          else
            local item = {title = name, cmd = command}
            if key ~= "_" then item.title = item.title .. "\t" .. key end
            target[#target + 1] = item
            local tags = parse_tags(command)
            if #tags > 0 then
              local entry = {item = item, original = copy_item(item), tags = tags}
              tagged[#tagged + 1] = entry
              for _, tag in ipairs(tags) do
                -- scripts address an entry by its tag ("cache_cleaner"), also
                -- when the line has a trailing comment after it
                if not tag:match("^state=") then
                  by_tag[tag] = entry
                  by_tag[tag:match("^%S+")] = entry
                end
              end
            end
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
    local first, last = 1, #list
    local limit = tonumber(opts.menu_max_playlist_items) or 20
    if limit > 0 and #list > limit then
      local position = tonumber(read("playlist-playing-pos")) or -1
      if position < 0 then position = tonumber(read("playlist-pos")) or 0 end
      local before = math.floor(limit / 2)
      first = position + 1 - before
      last = first + limit - 1
      if first < 1 then first, last = 1, limit end
      if last > #list then first, last = #list - limit + 1, #list end
    end
    if first > 1 then
      items[#items + 1] = {title = "...\t[" .. (first - 1) .. "]", cmd = "ignore"}
    end
    for index = first, last do
      local entry = list[index]
      items[#items + 1] = {
        title = playlist_title(entry, index - 1),
        cmd = string.format("playlist-play-index %d", index - 1),
        state = (entry.playing or entry.current) and {"checked"} or {}
      }
    end
    if last < #list then
      items[#items + 1] = {title = "...\t[" .. (#list - last) .. "]", cmd = "ignore"}
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

  -- the whole menu, rebuilt only when something it depends on changed
  function service:tree()
    self:start()
    if dirty or not tree then
      dirty = false
      for _, entry in ipairs(tagged) do apply(entry) end
      tree = root
    end
    return tree
  end

  function service:available()
    return #root > 0
  end

  -- messaging API for other scripts --------------------------------------------

  local function announce()
    mp.commandv("script-message", "menu-ready", mp.get_script_name())
  end

  function service:start()
    if self.started then return end
    self.started = true
    local content = read_input_conf()
    if content then parse(content) end
    dirty = true

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
      mark_dirty()
    end)

    -- announce now and once more after every script had time to load
    announce()
    mp.add_timeout(1, announce)
  end

  return service
end

return menu_builder
