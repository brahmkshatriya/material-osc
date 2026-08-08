local context_actions = {}
local config_schema = require "src.config.schema"
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

  function service:open_configurations()
    local config_dir = mp.command_native({"expand-path", "~~home/script-opts"})
    if not config_dir or config_dir == "" then
      args.toast:error(
        "mpv configuration directory is unavailable", {duration = 2})
      return
    end
    local ready, reason = filesystem:ensure_directory(config_dir)
    if not ready then
      if args.msg then
        args.msg.error("could not create script-opts directory: " ..
          tostring(reason or "unknown error"))
      end
      args.toast:error(
        "Could not create script-opts directory", {duration = 2})
      return
    end

    local config_path = filesystem:normalize(
      filesystem:join(config_dir, "material-osc.conf"))
    local existing = filesystem:read(config_path) or ""
    local contents, changed =
      config_schema.render_configuration(existing, args.opts)
    if changed and not filesystem:write_atomic(config_path, contents) then
      args.toast:error("Could not create material-osc.conf", {duration = 2})
      return
    end
    launch(config_path, false)
  end

  function service:items(snapshot)
    local items = {}
    local function item(label, icon, action)
      items[#items + 1] = {label = label, icon = icon, action = action}
    end
    local function separator() items[#items + 1] = {separator = true} end
    local function add_settings_items()
      item("Keybindings", "keyboard", function() self:open_keybindings() end)
      item("Configurations", "settings",
        function() self:open_configurations() end)
    end
    if (snapshot.playlist_count or 0) == 0 then
      add_settings_items()
      return items
    end

    local network = snapshot.network or is_url(media_path())
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
    add_settings_items()
    return items
  end

  return service
end

context_actions.sanitize_configuration = config_schema.sanitize

return context_actions
