local media_title = {}

local PYTHON_SCRIPT = table.concat({
  "import json, sys",
  "from guessit import guessit",
  "print(json.dumps(dict(guessit(sys.argv[1])), default=str))"
}, "; ")

local function first(value)
  if type(value) == "table" then return value[1] end
  return value
end

local function text(value)
  value = first(value)
  if value == nil then return nil end
  value = tostring(value):match("^%s*(.-)%s*$")
  return value ~= "" and value or nil
end

local function index_text(value)
  value = first(value)
  local number = tonumber(value)
  if number and number >= 0 and number == math.floor(number) then
    return string.format("%02d", number)
  end
  return text(value)
end

local function index_range(value)
  if type(value) ~= "table" then return index_text(value) end
  local first_index, last_index = index_text(value[1]), index_text(value[#value])
  if not first_index then return nil end
  if not last_index or last_index == first_index then return first_index end
  return first_index .. "-" .. last_index
end

function media_title.format(guess)
  if type(guess) ~= "table" then return nil end
  local title = text(guess.title)
  if not title then return nil end

  local kind = text(guess.type)
  local year = text(guess.year)
  if kind == "movie" and year then title = title .. " (" .. year .. ")" end

  if kind == "episode" then
    local season = index_text(guess.season)
    local episode = index_range(guess.episode)
    if season and episode then
      local first_episode, last_episode = episode:match("^([^-]+)%-(.+)$")
      title = title .. " - S" .. season .. "E" ..
        (first_episode and (first_episode .. "-E" .. last_episode) or episode)
    elseif episode then
      title = title .. " - Ep. " .. episode
    end
    local episode_title = text(guess.episode_title)
    if episode_title then title = title .. " - " .. episode_title end
  end

  local part = text(guess.part)
  local disc = text(guess.cd)
  if part then title = title .. " (Part " .. part .. ")"
  elseif disc then title = title .. " (CD " .. disc .. ")" end
  return title
end

local function is_local(path)
  return type(path) == "string" and path ~= "" and path ~= "-" and
    path:match("^[%a][%w+.-]*://") == nil
end

local function copy(values)
  local result = {}
  for index, value in ipairs(values) do result[index] = value end
  return result
end

function media_title.new(args)
  local mp, process, utils = args.mp, args.process, args.utils
  local candidates = args.runtime.is_windows and {
    {"py", "-3"}, {"python"}, {"python3"}
  } or {{"python3"}, {"python"}}
  local python_command
  local unavailable = false
  local service = {}

  local function parse(candidate, filename, callback)
    local command = copy(candidate)
    command[#command + 1] = "-c"
    command[#command + 1] = PYTHON_SCRIPT
    command[#command + 1] = filename
    process:run_async(command, {capture_size = 1024 * 1024}, function(ok, result)
      local parsed = ok and utils.parse_json(result.stdout or "") or nil
      callback(type(parsed) == "table" and parsed or nil)
    end)
  end

  local function guess(filename, callback)
    if unavailable then return callback(nil) end
    if python_command then return parse(python_command, filename, callback) end
    local index = 0
    local function try_next()
      index = index + 1
      local candidate = candidates[index]
      if not candidate then
        unavailable = true
        if args.msg then
          args.msg.verbose("guessit is unavailable; using mpv media titles")
        end
        return callback(nil)
      end
      parse(candidate, filename, function(parsed)
        if not parsed then return try_next() end
        python_command = candidate
        callback(parsed)
      end)
    end
    try_next()
  end

  function service:load()
    if args.enabled and not args.enabled() then return end
    local path = mp.get_property("path", "") or ""
    if not is_local(path) then return end
    local forced = mp.get_property("force-media-title", "") or ""
    if forced:match("%S") then return end
    local filename = mp.get_property("filename", "") or ""
    if filename == "" then filename = path:match("([^/\\]+)$") or path end
    -- look the title up in the background so the file isn't held back
    guess(filename, function(guessed)
      local title = media_title.format(guessed)
      if not title or mp.get_property("path", "") ~= path then return end
      -- something else forced a title while the lookup ran
      if (mp.get_property("force-media-title", "") or ""):match("%S") then return end
      mp.set_property("file-local-options/force-media-title", title)
    end)
  end

  function service:register()
    mp.add_hook("on_load", 10, function() self:load() end)
  end

  return service
end

return media_title
