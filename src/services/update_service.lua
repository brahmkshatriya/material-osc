local update_service = {}

local CURRENT_VERSION = "__MATERIAL_OSC_VERSION__"
local REPOSITORY = "brahmkshatriya/material-osc"
local API_URL = "https://api.github.com/repos/" .. REPOSITORY .. "/releases/latest"
local CHECK_INTERVAL_SECONDS = 2 * 60 * 60

local function version_parts(value)
  local parts = {}
  value = tostring(value or ""):gsub("^[vV]", ""):match("^[^+-]+") or ""
  for part in value:gmatch("%d+") do parts[#parts + 1] = tonumber(part) end
  return parts
end

local function is_newer(candidate, current)
  local left, right = version_parts(candidate), version_parts(current)
  if #left == 0 or #right == 0 then return false end
  for index = 1, math.max(#left, #right) do
    local a, b = left[index] or 0, right[index] or 0
    if a ~= b then return a > b end
  end
  return false
end

function update_service.new(args)
  local mp, utils, msg = args.mp, args.utils, args.msg
  local filesystem, http = args.filesystem, args.http
  local state = args.state.update
  local service = {current_version = CURRENT_VERSION}
  local preferences_path = mp.command_native({
    "expand-path", "~~/script-opts/material-osc-updater.conf"
  })
  local preferences = args.persistence:key_value(preferences_path, {
    default = function() return {mode = "ask", last_check = "0"} end,
    order = {"mode", "last_check"}
  })

  local function render()
    if args.render then args.render() end
  end

  local function http_get(url, callback)
    return http:get(url, {
      fail = true,
      connect_timeout = 8,
      max_time = 15,
      headers = {"Accept: application/vnd.github+json"}
    }, callback)
  end

  local function download(url, path, callback)
    return http:download(url, path, {
      connect_timeout = 10,
      max_time = 180
    }, callback)
  end

  local function read_preferences()
    local values = preferences:load()
    local mode = values.mode
    if mode ~= "auto" and mode ~= "never" and mode ~= "ask" then mode = "ask" end
    local last_check = tonumber(values.last_check) or 0
    return mode, last_check
  end

  local function save_preferences(mode, last_check)
    if mode ~= "auto" and mode ~= "never" and mode ~= "ask" then return false end
    if preferences:save({
      mode = mode,
      last_check = tostring(math.max(0, math.floor(tonumber(last_check) or 0)))
    }) then
      state.mode = mode
      state.last_check = tonumber(last_check) or 0
      return true
    else
      msg.error("could not save material-osc updater preference")
      return false
    end
  end

  local function save_mode(mode)
    local _, last_check = read_preferences()
    save_preferences(mode, last_check)
  end

  local function close()
    state.open, state.busy, state.bounds = false, false, nil
    mp.disable_key_bindings("material-osc-update-dialog")
    render()
  end

  local function show(release, notes)
    state.version = tostring(release.tag_name or ""):gsub("^[vV]", "")
    state.tag = release.tag_name
    state.notes = notes or release.body or "See the GitHub release for details."
    if state.notes:match("^%s*$") then
      state.notes = "See the GitHub release for details."
    end
    state.asset_url = nil
    for _, asset in ipairs(release.assets or {}) do
      if tostring(asset.name or "") == "material-osc.zip" then
        state.asset_url = asset.browser_download_url
        break
      end
    end
    state.open, state.busy, state.done = true, false, false
    state.scroll_index = 0
    state.error, state.dont_ask = nil, false
    mp.enable_key_bindings("material-osc-update-dialog")
    render()
  end

  local function fetch_notes(release, callback)
    local version = tostring(release.tag_name or ""):gsub("^[vV]", "")
    local url = "https://raw.githubusercontent.com/" .. REPOSITORY .. "/" ..
      tostring(release.tag_name) .. "/updates/" .. version .. ".txt"
    http_get(url, function(ok, response)
      callback(ok and response.body or release.body)
    end)
  end

  local function install_extracted(directory)
    local source_script = filesystem:join(
      filesystem:join(directory, "scripts"), "material-osc.lua")
    local ok, reason = filesystem:replace(source_script, args.script_path)
    if not ok then return false, reason end
    filesystem:ensure_directory(args.font_dir)
    for _, font in ipairs({
      "material-osc_google_sans_flex.ttf", "material-osc_icons.otf"
    }) do
      local source = filesystem:join(
        filesystem:join(directory, "fonts"), font)
      local target = filesystem:join(args.font_dir, font)
      if filesystem:info(source) then
        ok, reason = filesystem:replace(source, target)
        if not ok then return false, reason end
      end
    end
    return true
  end

  local function unpack(archive, directory, callback)
    filesystem:extract_archive(archive, directory, function(ok, _, reason)
      if not ok then
        callback(false, reason)
        return
      end
      callback(install_extracted(directory))
    end)
  end

  function service:close()
    if state.busy then return end
    if state.done then
      save_mode(state.disable_auto_update and "ask" or "auto")
    elseif state.dont_ask then
      save_mode("never")
    end
    close()
  end

  function service:toggle_dont_ask()
    if state.busy or state.done then return end
    state.dont_ask = not state.dont_ask
    render()
  end

  function service:toggle_disable_auto_update()
    if state.busy or not state.done then return end
    state.disable_auto_update = not state.disable_auto_update
    render()
  end

  function service:install(auto)
    if state.busy or state.done then return end
    if state.dont_ask or auto then save_mode("auto") end
    if not state.asset_url then
      state.error = "This release does not include an update archive."
      render()
      return
    end
    state.open, state.busy, state.error = true, true, nil
    mp.enable_key_bindings("material-osc-update-dialog")
    render()
    local base = filesystem:temporary_base()
    local archive, directory = base .. ".zip", base .. "-material-osc"
    download(state.asset_url, archive, function(ok, response)
      if not ok then
        state.busy = false
        state.error = "Download failed. Check your internet connection and try again."
        msg.error("material-osc update download failed: " ..
          tostring(response.stderr or ""))
        render()
        return
      end
      unpack(archive, directory, function(installed, reason)
        filesystem:remove(archive)
        state.busy = false
        if installed then
          state.done = true
          state.scroll_index = 0
          state.disable_auto_update = false
        else
          state.error = "Installation failed. " .. tostring(reason or "")
          msg.error("material-osc update installation failed: " .. tostring(reason or ""))
        end
        render()
      end)
    end)
  end

  function service:check()
    if tostring(args.script_path or ""):match("^/nix/store/") then return end
    local mode, last_check = read_preferences()
    state.mode, state.last_check = mode, last_check
    local source_marker = "__MATERIAL_" .. "OSC_VERSION__"
    if CURRENT_VERSION == source_marker or CURRENT_VERSION == "dev" or
      state.mode == "never" or state.checking then return end
    local now = os.time()
    local elapsed = now - last_check
    if last_check > 0 and elapsed >= 0 and elapsed < CHECK_INTERVAL_SECONDS then
      return
    end
    save_preferences(state.mode, now)
    state.checking = true
    http_get(API_URL, function(ok, response)
      state.checking = false
      if not ok then
        msg.verbose("material-osc update check failed: " ..
          tostring(response.stderr or ""))
        return
      end
      local release = utils.parse_json(response.body or "")
      if type(release) ~= "table" or not is_newer(release.tag_name, CURRENT_VERSION) then return end
      fetch_notes(release, function(notes)
        show(release, notes)
        if state.mode == "auto" then service:install(true) end
      end)
    end)
  end

  function service:start()
    mp.set_key_bindings({{"ESC", function() service:close() end}},
      "material-osc-update-dialog", "force")
    mp.disable_key_bindings("material-osc-update-dialog")
    mp.add_timeout(2, function() service:check() end)
  end

  local function open_url(url, error_message)
    http:open(url, function(ok)
      if not ok then args.toast:error(error_message, {duration = 2}) end
    end)
  end

  function service:open_repository()
    open_url("https://github.com/" .. REPOSITORY,
      "Could not open the material-osc repository")
  end

  function service:open_release()
    local url = "https://github.com/" .. REPOSITORY .. "/releases"
    if state.tag and tostring(state.tag) ~= "" then
      url = url .. "/tag/" .. tostring(state.tag)
    end
    open_url(url, "Could not open the release page")
  end

  return service
end

update_service.is_newer = is_newer

return update_service
