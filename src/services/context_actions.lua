local context_actions = {}
local config_schema = require "src.config.schema"
local menu_builder = require "src.services.menu_builder"
local windows_command = require "src.platform.windows_command"

function context_actions.new(args)
  local mp = args.mp
  local filesystem, http = args.filesystem, args.http
  local process, runtime = args.process, args.runtime
  local properties = args.properties
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
    local bindings
    if properties then
      bindings = properties["input-bindings"] or {}
    else
      bindings = mp.get_property_native("input-bindings", {}) or {}
    end
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
    value = tostring(value or "")
    if value == "" then return end

    local called, native_ok = pcall(mp.set_property, "clipboard/text", value)
    if called and native_ok == true then
      args.toast:success(message, {icon = "content_copy", duration = 2})
      return
    end

    if not process or not runtime then
      args.toast:error("Clipboard is unavailable", {duration = 2})
      return
    end

    local commands
    if runtime.is_windows then
      commands = {{
        command = windows_command.powershell(
          "Set-Clipboard -Value $argument1", {value})
      }}
    elseif runtime.is_macos then
      commands = {{command = {"pbcopy"}, stdin_data = value}}
    else
      commands = {
        {command = {"wl-copy", "--", value}},
        {command = {"xclip", "-selection", "clipboard", "-in"},
          stdin_data = value},
        {command = {"xsel", "--clipboard", "--input"},
          stdin_data = value}
      }
    end

    local index = 0
    local function try_next()
      index = index + 1
      local candidate = commands[index]
      if not candidate then
        args.toast:error("Clipboard is unavailable", {duration = 2})
        return
      end
      process:run_async(candidate.command, {
        stdin_data = candidate.stdin_data,
        capture_stdout = false,
        capture_stderr = true
      }, function(ok)
        if ok then
          args.toast:success(message, {icon = "content_copy", duration = 2})
        else
          try_next()
        end
      end)
    end
    try_next()
  end

  local function launch(target, reveal)
    if not target or target == "" then return end
    if is_url(target) then
      http:open(target, function(ok)
        if not ok then
          args.toast:error("Could not open " .. target, {duration = 2})
        end
      end)
      return
    end
    filesystem:open(target, {reveal = reveal}, function(ok, _, resolved_path)
      if not ok then
        args.toast:error(
          "Could not open " .. resolved_path, {duration = 2})
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

  local function script_opts_path(name)
    local config_dir = mp.command_native({"expand-path", "~~home/script-opts"})
    if not config_dir or config_dir == "" then
      args.toast:error(
        "mpv configuration directory is unavailable", {duration = 2})
      return nil
    end
    local ready, reason = filesystem:ensure_directory(config_dir)
    if not ready then
      if args.msg then
        args.msg.error("could not create script-opts directory: " ..
          tostring(reason or "unknown error"))
      end
      args.toast:error(
        "Could not create script-opts directory", {duration = 2})
      return nil
    end
    return filesystem:normalize(filesystem:join(config_dir, name))
  end

  function service:open_configurations()
    local config_path = script_opts_path("material-osc.conf")
    if not config_path then return end
    local existing = filesystem:read(config_path) or ""
    local contents, changed =
      config_schema.render_configuration(existing, args.opts)
    if changed and not filesystem:write_atomic(config_path, contents) then
      args.toast:error("Could not create material-osc.conf", {duration = 2})
      return
    end
    launch(config_path, false)
  end

  function service:open_menu_file()
    local menu_path = script_opts_path(menu_builder.FILE)
    if not menu_path then return end
    if not filesystem:read(menu_path) and
      not filesystem:write_atomic(menu_path, menu_builder.DEFAULT_CONTENTS) then
      args.toast:error("Could not create " .. menu_builder.FILE, {duration = 2})
      return
    end
    launch(menu_path, false)
  end

  -- material-osc's own menu items, the "@name" entries of the menu file
  local builtins = {
    ["copy-subtitle"] = function(snapshot)
      if type(snapshot.subtitle_text) ~= "string" or
        not snapshot.subtitle_text:match("%S") then return nil end
      return "Copy Subtitle Text", "subtitles",
        function() service:copy_subtitle(snapshot) end
    end,
    ["copy-timestamp"] = function(snapshot, network)
      local timestamp = args.format_time(snapshot.position or 0)
      return network and ("Share at " .. timestamp) or
        ("Copy Timestamp · " .. timestamp), "schedule",
        function() service:copy_timestamp(snapshot) end
    end,
    ["copy-media"] = function(snapshot, network)
      return network and "Share" or "Copy Media Path", "link",
        function() service:copy_media(snapshot) end
    end,
    ["ab-loop"] = function(snapshot)
      return not snapshot.ab_loop_a and "Set A–B Loop Start" or
        (not snapshot.ab_loop_b and "Set A–B Loop End" or "Clear A–B Loop"),
        "repeat", function() service:cycle_ab_loop() end
    end,
    ["add-bookmark"] = function()
      return "Add Bookmark", "bookmark_add",
        function() service:add_bookmark() end
    end,
    ["media-information"] = function()
      local open = media_information_visible()
      return open and "Hide Media Information" or "Media Information",
        open and "visibility_off" or "info",
        function() service:show_media_information() end
    end,
    ["open-media"] = function(snapshot, network)
      return network and "Open in Browser" or "Reveal in File Manager",
        network and "open_in_new" or "folder_open",
        function() service:open_media(snapshot) end
    end
  }
  local always_available = {
    keybindings = function()
      return "Keybindings", "keyboard", function() service:open_keybindings() end
    end,
    customize = function()
      return "Customize", "settings", function()
        service:open_configurations()
        service:open_menu_file()
      end
    end
  }

  local network_snapshot, network

  -- Returns the item, which is nil when it doesn't apply to the current media,
  -- and whether that name exists at all.
  function service:builtin(name, snapshot)
    local build = always_available[name]
    if not build then
      build = builtins[name]
      if not build then return nil, false end
      if (snapshot.playlist_count or 0) == 0 then return nil, true end
    end
    if network_snapshot ~= snapshot then
      network_snapshot = snapshot
      network = snapshot.network or is_url(media_path())
    end
    local label, icon, action = build(snapshot, network)
    if not label then return nil, true end
    return {label = label, icon = icon, action = action}, true
  end

  return service
end

context_actions.sanitize_configuration = config_schema.sanitize

return context_actions
