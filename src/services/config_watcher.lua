local config_watcher = {}

local function decode(value, default)
  value = tostring(value or ""):match("^%s*(.-)%s*$") or ""
  local quote = value:sub(1, 1)
  if (quote == '"' or quote == "'") and value:sub(-1) == quote then
    value = value:sub(2, -2)
  end
  if type(default) == "boolean" then
    local normalized = value:lower()
    if normalized == "yes" or normalized == "true" or normalized == "1" then
      return true
    end
    if normalized == "no" or normalized == "false" or normalized == "0" then
      return false
    end
    return default
  end
  if type(default) == "number" then return tonumber(value) or default end
  return value
end

function config_watcher.parse(contents, defaults)
  local values = {}
  for name, value in pairs(defaults) do values[name] = value end
  for line in (tostring(contents or "") .. "\n"):gmatch("(.-)\n") do
    local name, value = line:match("^%s*([%w_-]+)%s*=%s*(.-)%s*$")
    if name and defaults[name] ~= nil then
      values[name] = decode(value, defaults[name])
    end
  end
  return values
end

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then return "" end
  local contents = file:read("*a") or ""
  file:close()
  return contents
end

function config_watcher.new(args)
  local service = {
    contents = read_file(args.path),
    preserved = {},
    watch_id = nil,
    reload_timer = nil,
    stopped = true
  }
  local initial = config_watcher.parse(service.contents, args.defaults)
  if args.normalize then initial = args.normalize(initial) end
  for name, value in pairs(initial) do
    if args.options[name] ~= value then service.preserved[name] = true end
  end

  function service:preserve(changed)
    for name in pairs(changed or {}) do self.preserved[name] = true end
  end

  function service:reload()
    local contents = read_file(args.path)
    if contents == self.contents then return end
    self.contents = contents
    local values = config_watcher.parse(contents, args.defaults)
    if args.normalize then values = args.normalize(values) end
    local changed = {}
    for name, value in pairs(values) do
      if not self.preserved[name] and args.options[name] ~= value then
        args.options[name] = value
        changed[name] = true
      end
    end
    if next(changed) then args.on_update(changed) end
  end

  local function existing_watch_directory()
    local directory = args.directory
    while directory and directory ~= "" do
      local info = args.utils and args.utils.file_info(directory)
      if info and info.is_dir then return directory end
      local normalized = directory:gsub("[/\\]+$", "")
      local parent = args.utils and select(1, args.utils.split_path(normalized))
      if not parent or parent == "" or parent == directory then break end
      directory = parent
    end
    return args.directory
  end

  local function watch_command()
    local os_name = jit and jit.os or ""
    local directory = existing_watch_directory()
    if os_name == "Windows" then
      local quoted_directory = "'" .. directory:gsub("'", "''") .. "'"
      return {"powershell", "-NoProfile", "-NonInteractive", "-Command",
        "$w=New-Object IO.FileSystemWatcher(" .. quoted_directory .. ");" ..
        "$w.EnableRaisingEvents=$true;" ..
        "$w.WaitForChanged([IO.WatcherChangeTypes]::All)|Out-Null"}
    end
    if os_name == "OSX" then
      return {"sh", "-c",
        "command -v fswatch >/dev/null || exit 127; exec fswatch -1 -- $1",
        "material-osc-config-watch", directory}
    end
    return {"sh", "-c",
      "if command -v inotifywait >/dev/null; then " ..
        "exec inotifywait -qq -e close_write,create,delete,moved_to -- $1; " ..
      "elif command -v gio >/dev/null; then " ..
        "watch_tmp=$(mktemp -d) || exit 1; " ..
        "watch_fifo=$watch_tmp/event; mkfifo \"$watch_fifo\" || exit 1; " ..
        "cleanup() { " ..
          "trap - EXIT INT TERM; " ..
          "test -n \"$monitor_pid\" && kill \"$monitor_pid\" 2>/dev/null; " ..
          "test ! -e \"$watch_fifo\" || rm -f \"$watch_fifo\"; " ..
          "test ! -d \"$watch_tmp\" || rmdir \"$watch_tmp\"; " ..
        "}; trap cleanup EXIT INT TERM; " ..
        "gio monitor -d \"$1\" >\"$watch_fifo\" & monitor_pid=$!; " ..
        "IFS= read -r event <\"$watch_fifo\"; " ..
      "else exit 127; fi",
      "material-osc-config-watch", directory}
  end

  function service:schedule_reload()
    if self.reload_timer then self.reload_timer:kill() end
    self.reload_timer = args.mp.add_timeout(args.reload_delay or 0.1, function()
      self.reload_timer = nil
      self:reload()
    end)
  end

  function service:arm()
    if self.stopped or self.watch_id then return end
    self.watch_id = args.mp.command_native_async({
      name = "subprocess",
      args = watch_command(),
      playback_only = false,
      capture_stdout = true,
      capture_stderr = true
    }, function(success, result)
      self.watch_id = nil
      if self.stopped then return end
      local status = result and tonumber(result.status) or -1
      if not success or status ~= 0 then
        self.stopped = true
        if args.on_error then args.on_error(result and result.stderr or "") end
        return
      end
      self:schedule_reload()
      self:arm()
    end)
  end

  function service:start()
    if not self.stopped then return end
    self.stopped = false
    self:arm()
  end

  function service:stop()
    self.stopped = true
    if self.watch_id then args.mp.abort_async_command(self.watch_id) end
    self.watch_id = nil
    if self.reload_timer then self.reload_timer:kill() end
    self.reload_timer = nil
  end

  return service
end

return config_watcher
