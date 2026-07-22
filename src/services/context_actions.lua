local context_actions = {}

local function sanitize_configuration(existing, order)
  local allowed = {}
  for _, name in ipairs(order) do
    allowed[name] = true
  end

  local configured, lines = {}, {}
  local removed_unused = false
  for line in (existing .. "\n"):gmatch("(.-)\n") do
    local name = line:match("^%s*([%w_-]+)%s*=")
    if name and not allowed[name] then
      removed_unused = true
    else
      lines[#lines + 1] = line
      if name then configured[name] = true end
    end
  end

  local preserved = table.concat(lines, "\n"):gsub("%s+$", "")
  return preserved, configured, removed_unused
end

function context_actions.new(args)
  local mp, utils = args.mp, args.utils
  local service = {}

  local function is_url(path)
    return type(path) == "string" and path:match("^[%a][%w+.-]*://") ~= nil
  end

  local function media_path()
    local path = mp.get_property("path", "") or ""
    if path == "" or is_url(path) then return path end
    return mp.command_native({"normalize-path", path}) or path
  end

  local function media_information_visible()
    local bindings = mp.get_property_native("input-bindings", {}) or {}
    for _, binding in ipairs(bindings) do
      local command = type(binding) == "table" and binding.cmd or nil
      if type(command) == "string" and
        command:find("script-binding stats/__forced_", 1, true) then
        return true
      end
    end
    return false
  end

  local function copy(value, message)
    if not value or value == "" then return end
    local ok, result = pcall(mp.set_property, "clipboard", value)
    mp.osd_message(ok and result ~= false and message or
      "Clipboard is unavailable", 2)
  end

  local function launch(target, reveal)
    if not target or target == "" then return end
    local os_name = jit and jit.os or ""
    local command
    if os_name == "Windows" then
      command = reveal and {"explorer", "/select," .. target} or
        (is_url(target) and {"rundll32", "url.dll,FileProtocolHandler", target} or
          {"powershell", "-NoProfile", "-Command",
            "Start-Process -FilePath $args[0]", target})
    elseif os_name == "OSX" then
      command = reveal and {"open", "-R", target} or {"open", target}
    else
      local destination = target
      if reveal then destination = select(1, utils.split_path(target)) end
      command = {"xdg-open", destination}
    end
    mp.command_native_async({
      name = "subprocess", args = command, playback_only = false,
      capture_stdout = true, capture_stderr = true
    }, function(success, result)
      if not success or not result or result.status ~= 0 then
        mp.osd_message("Could not open " .. target, 2)
      end
    end)
  end

  function service:copy_subtitle(snapshot)
    copy(snapshot.subtitle_text, "Subtitle text copied")
  end

  function service:copy_timestamp(snapshot)
    local position = math.max(0, snapshot.position or 0)
    local timestamp = args.format_time(position)
    local path = media_path()
    if (snapshot.network or is_url(path)) and path ~= "" then
      local seconds = math.floor(position + 0.5)
      if path:match("youtu%.be/") or path:match("youtube%.com/") then
        local separator = path:find("?", 1, true) and "&" or "?"
        copy(path .. separator .. "t=" .. tostring(seconds) .. "s",
          "Share link copied")
      else
        copy(path .. " · " .. timestamp, "Share text copied")
      end
    else
      copy(timestamp, "Timestamp copied")
    end
  end

  function service:copy_media(snapshot)
    local path = media_path()
    copy(path, (snapshot.network or is_url(path)) and
      "Media link copied" or "Media path copied")
  end

  function service:cycle_ab_loop()
    mp.commandv("ab-loop")
    args.render()
  end

  function service:add_bookmark()
    args.bookmarks:add()
  end

  function service:show_media_information()
    mp.commandv("script-binding", "stats/display-stats-toggle")
    args.render()
  end

  function service:media_information_visible()
    return media_information_visible()
  end

  function service:open_media(snapshot)
    local path = media_path()
    launch(path, not snapshot.network and not is_url(path))
  end

  function service:open_keybindings()
    mp.commandv("script-binding", "select/select-binding")
  end

  function service:open_configurations()
    local config_dir = mp.command_native({"expand-path", "~~home/script-opts"})
    if not config_dir or config_dir == "" then
      mp.osd_message("mpv configuration directory is unavailable", 2)
      return
    end
    if not utils.file_info(config_dir) then
      local os_name = jit and jit.os or ""
      local command = os_name == "Windows" and
        {"powershell", "-NoProfile", "-Command",
          "New-Item -ItemType Directory -Force -LiteralPath $args[0] | Out-Null",
          config_dir} or
        {"mkdir", "-p", config_dir}
      local result = mp.command_native({
        name = "subprocess", args = command, playback_only = false,
        capture_stdout = true, capture_stderr = true
      })
      if not result or result.status ~= 0 then
        mp.osd_message("Could not create script-opts directory", 2)
        return
      end
    end

    local config_path = utils.join_path(config_dir, "material-osc.conf")
    local config_info = utils.file_info(config_path)
    local existing = ""
    if config_info then
      local file = io.open(config_path, "rb")
      if file then existing = file:read("*a") or ""; file:close() end
    end
    local order = {
      "dpi_scale",
      "accent_color",
      "context_menu",
      "tooltip",
      "mouse_timeout",
      "show_on_mouse_move",
      "single_click_actions_enabled",
      "seeking_zone_percentage",
      "seek_step_seconds",
      "show_mini_seekbar",
      "force_window_controls",
      "max_volume_percentage",
      "directory_playlist",
      "directory_playlist_sort"
    }
    local preserved, configured, removed_unused =
      sanitize_configuration(existing, order)
    local missing = {}
    for _, name in ipairs(order) do
      if not configured[name] then missing[#missing + 1] = name end
    end
    if #missing > 0 or removed_unused then
      local function config_value(value)
        if type(value) == "boolean" then return value and "yes" or "no" end
        local text = tostring(value)
        if text:find("#", 1, true) then return '"' .. text .. '"' end
        return text
      end
      local lines = {}
      if preserved ~= "" then
        lines[#lines + 1] = preserved
        lines[#lines + 1] = ""
      else
        lines[#lines + 1] = "# material-osc configuration"
        lines[#lines + 1] = "# Changes are applied to running mpv instances."
        lines[#lines + 1] = ""
      end
      for _, name in ipairs(missing) do
        lines[#lines + 1] = name .. "=" .. config_value(args.opts[name])
      end
      local file = io.open(config_path, "wb")
      if not file then
        mp.osd_message("Could not create material-osc.conf", 2)
        return
      end
      file:write(table.concat(lines, "\n"), "\n")
      file:close()
    end
    launch(config_path, false)
  end

  function service:items(snapshot)
    local items = {}
    local network = snapshot.network or is_url(media_path())
    local function item(label, icon, action)
      items[#items + 1] = {label = label, icon = icon, action = action}
    end
    local function separator() items[#items + 1] = {separator = true} end
    if type(snapshot.subtitle_text) == "string" and
      snapshot.subtitle_text:match("%S") then
      item("Copy Subtitle Text", "subtitles", function()
        self:copy_subtitle(snapshot)
      end)
    end
    local timestamp = args.format_time(snapshot.position or 0)
    item(network and ("Share at " .. timestamp) or
      ("Copy Timestamp · " .. timestamp), "schedule", function()
        self:copy_timestamp(snapshot)
      end)
    item(network and "Share" or "Copy Media Path", "link", function()
      self:copy_media(snapshot)
    end)
    separator()
    local loop_label = not snapshot.ab_loop_a and "Set A–B Loop Start" or
      (not snapshot.ab_loop_b and "Set A–B Loop End" or "Clear A–B Loop")
    item(loop_label, "repeat", function() self:cycle_ab_loop() end)
    item("Add Bookmark", "bookmark_add", function() self:add_bookmark() end)
    separator()
    local media_information_open = media_information_visible()
    item(media_information_open and "Hide Media Information" or
      "Media Information",
      media_information_open and "visibility_off" or "info",
      function() self:show_media_information() end)
    item(network and "Open in Browser" or "Reveal in File Manager",
      network and "open_in_new" or "folder_open", function()
        self:open_media(snapshot)
      end)
    separator()
    item("Keybindings", "keyboard", function() self:open_keybindings() end)
    item("Configurations", "settings", function() self:open_configurations() end)
    return items
  end

  return service
end

context_actions.sanitize_configuration = sanitize_configuration

return context_actions
