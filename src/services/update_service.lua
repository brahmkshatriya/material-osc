local update_service = {}

local CURRENT_VERSION = "__MATERIAL_OSC_VERSION__"
local REPOSITORY = "brahmkshatriya/material-osc"
local API_URL = "https://api.github.com/repos/" .. REPOSITORY .. "/releases/latest"
local CHECK_INTERVAL_SECONDS = 2 * 60 * 60

local function is_windows()
  return package.config:sub(1, 1) == "\\"
end

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

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local contents = file:read("*a")
  file:close()
  return contents
end

local function write_file(path, contents)
  local file = io.open(path, "wb")
  if not file then return false end
  local ok = file:write(contents)
  file:close()
  return ok ~= nil
end

function update_service.new(args)
  local mp, utils, msg = args.mp, args.utils, args.msg
  local state = args.state.update
  local service = {current_version = CURRENT_VERSION}
  local preferences_path = mp.command_native({
    "expand-path", "~~/script-opts/material-osc-updater.conf"
  })

  local function render()
    if args.render then args.render() end
  end

  local function subprocess(command, callback, capture_stdout)
    mp.command_native_async({
      name = "subprocess", args = command, playback_only = false,
      capture_stdout = capture_stdout == true, capture_stderr = true
    }, function(success, result)
      local status = result and tonumber(result.status) or -1
      callback(success and status == 0, result or {})
    end)
  end

  local function http_get(url, callback)
    subprocess({"curl", "-fLsS", "--connect-timeout", "8", "--max-time", "15",
      "-H", "Accept: application/vnd.github+json", url}, function(ok, result)
      if ok or not is_windows() then callback(ok, result); return end
      subprocess({"powershell", "-NoProfile", "-Command",
        "(Invoke-WebRequest -UseBasicParsing -Headers @{Accept='application/vnd.github+json'} -Uri $args[0]).Content",
        url}, callback, true)
    end, true)
  end

  local function download(url, path, callback)
    subprocess({"curl", "-fL", "--connect-timeout", "10", "--max-time", "180",
      "-o", path, url}, function(ok, result)
      if ok or not is_windows() then callback(ok, result); return end
      subprocess({"powershell", "-NoProfile", "-Command",
        "Invoke-WebRequest -UseBasicParsing -Uri $args[0] -OutFile $args[1]",
        url, path}, callback)
    end)
  end

  local function ensure_directory(path)
    local directory = utils.split_path(path)
    if not directory or directory == "" or utils.file_info(directory) then return true end
    local command = is_windows() and
      {"powershell", "-NoProfile", "-Command",
        "New-Item -ItemType Directory -Force -LiteralPath $args[0] | Out-Null", directory} or
      {"mkdir", "-p", directory}
    local result = mp.command_native({
      name = "subprocess", args = command, playback_only = false
    })
    return result and tonumber(result.status) == 0
  end

  local function read_preferences()
    local contents = read_file(preferences_path) or ""
    local mode = contents:match("mode%s*=%s*([%a_]+)")
    if mode ~= "auto" and mode ~= "never" and mode ~= "ask" then mode = "ask" end
    local last_check = tonumber(contents:match("last_check%s*=%s*(%d+)")) or 0
    return mode, last_check
  end

  local function save_preferences(mode, last_check)
    if mode ~= "auto" and mode ~= "never" and mode ~= "ask" then return false end
    local contents = "mode=" .. mode .. "\nlast_check=" ..
      tostring(math.max(0, math.floor(tonumber(last_check) or 0))) .. "\n"
    if ensure_directory(preferences_path) and
      write_file(preferences_path, contents) then
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
      if tostring(asset.name or ""):match("^material%-osc%-.+%.zip$") then
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
    http_get(url, function(ok, result)
      callback(ok and result.stdout or release.body)
    end)
  end

  local function replace_file(source, target)
    local contents = read_file(source)
    if not contents then return false, "missing " .. source end
    local temporary, backup = target .. ".update", target .. ".previous"
    if not write_file(temporary, contents) then return false, "cannot write " .. temporary end
    os.remove(backup)
    local had_target = read_file(target) ~= nil
    if had_target and not os.rename(target, backup) then
      os.remove(temporary)
      return false, "cannot replace " .. target
    end
    if not os.rename(temporary, target) then
      if had_target then os.rename(backup, target) end
      os.remove(temporary)
      return false, "cannot install " .. target
    end
    os.remove(backup)
    return true
  end

  local function install_extracted(directory)
    local source_script = utils.join_path(directory, "material-osc.lua")
    local ok, reason = replace_file(source_script, args.script_path)
    if not ok then return false, reason end
    ensure_directory(args.font_dir .. package.config:sub(1, 1) .. "placeholder")
    for _, font in ipairs({"GoogleSansFlex.ttf", "MaterialSymbolsRoundedUnfilled.ttf"}) do
      local source = utils.join_path(utils.join_path(directory, "material-osc"), font)
      local target = utils.join_path(args.font_dir, font)
      if utils.file_info(source) then
        ok, reason = replace_file(source, target)
        if not ok then return false, reason end
      end
    end
    return true
  end

  local function unpack(archive, directory, callback)
    if not ensure_directory(directory .. package.config:sub(1, 1) .. "placeholder") then
      callback(false, "could not create the temporary update directory")
      return
    end
    local command
    if is_windows() then
      command = {"powershell", "-NoProfile", "-Command",
        "Expand-Archive -Force -LiteralPath $args[0] -DestinationPath $args[1]",
        archive, directory}
    else
      command = {"unzip", "-oq", archive, "-d", directory}
    end
    subprocess(command, function(ok, result)
      if not ok and not is_windows() then
        subprocess({"tar", "-xf", archive, "-C", directory}, function(tar_ok, tar_result)
          if not tar_ok then
            callback(false, tar_result.stderr or result.stderr or "could not unpack release")
            return
          end
          callback(install_extracted(directory))
        end)
        return
      end
      if not ok then
        callback(false, result.stderr or "could not unpack release")
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
    local base = os.tmpname()
    os.remove(base)
    local archive, directory = base .. ".zip", base .. "-material-osc"
    download(state.asset_url, archive, function(ok, result)
      if not ok then
        state.busy = false
        state.error = "Download failed. Check your internet connection and try again."
        msg.error("material-osc update download failed: " .. tostring(result.stderr or ""))
        render()
        return
      end
      unpack(archive, directory, function(installed, reason)
        os.remove(archive)
        state.busy = false
        if installed then
          state.done = true
          state.scroll_index = 0
          state.disable_auto_update = state.mode ~= "auto"
        else
          state.error = "Installation failed. " .. tostring(reason or "")
          msg.error("material-osc update installation failed: " .. tostring(reason or ""))
        end
        render()
      end)
    end)
  end

  function service:check()
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
    http_get(API_URL, function(ok, result)
      state.checking = false
      if not ok then
        msg.verbose("material-osc update check failed: " .. tostring(result.stderr or ""))
        return
      end
      local release = utils.parse_json(result.stdout or "")
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

  function service:open_release()
    local url = "https://github.com/" .. REPOSITORY .. "/releases"
    if state.tag and tostring(state.tag) ~= "" then
      url = url .. "/tag/" .. tostring(state.tag)
    end
    local os_name = jit and jit.os or ""
    local command
    if os_name == "Windows" then
      command = {"rundll32", "url.dll,FileProtocolHandler", url}
    elseif os_name == "OSX" then
      command = {"open", url}
    else
      command = {"xdg-open", url}
    end
    subprocess(command, function(ok)
      if not ok then mp.osd_message("Could not open the release page", 2) end
    end)
  end

  return service
end

update_service.is_newer = is_newer

return update_service
