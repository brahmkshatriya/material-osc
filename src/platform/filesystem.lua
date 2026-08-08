local filesystem = {}
local windows_command = require "src.platform.windows_command"

function filesystem.new(args)
  local mp, utils = args.mp, args.utils
  local process, runtime = args.process, args.runtime
  local service = {}

  function service:info(path)
    if not path or path == "" then return nil end
    return utils.file_info(path)
  end

  function service:read(path)
    if not path or path == "" then return nil end
    local file = io.open(path, "rb")
    if not file then return nil end
    local contents = file:read("*a")
    file:close()
    return contents
  end

  function service:write(path, contents)
    if not path or path == "" then return false end
    local file = io.open(path, "wb")
    if not file then return false end
    local ok = file:write(contents or "")
    file:close()
    return ok ~= nil
  end

  function service:remove(path)
    if not path or path == "" then return false end
    return os.remove(path) ~= nil
  end

  function service:rename(source, target)
    if not source or source == "" or not target or target == "" then
      return false
    end
    return os.rename(source, target) ~= nil
  end

  function service:write_atomic(path, contents)
    if not path or path == "" then return false end
    local temporary = path .. ".tmp"
    if not self:write(temporary, contents) then return false end
    if self:rename(temporary, path) then return true end

    -- Windows cannot replace an existing file with rename. Retain atomic
    -- replacement where supported and fall back to a direct write there.
    local ok = self:write(path, contents)
    self:remove(temporary)
    return ok
  end

  function service:join(left, right)
    return utils.join_path(left, right)
  end

  function service:split(path)
    return utils.split_path(path)
  end

  function service:list(path, kind)
    return utils.readdir(path, kind)
  end

  function service:normalize(path)
    if not path or path == "" then return path end
    return mp.command_native({"normalize-path", path}) or path
  end

  function service:ensure_directory(path)
    if not path or path == "" then return false end
    local info = self:info(path)
    if info then
      if info.is_dir ~= false then return true end
      return false, "a file already exists at that path"
    end
    local command = runtime.is_windows and windows_command.powershell(
      "[System.IO.Directory]::CreateDirectory($argument1) | Out-Null",
      {path}) or {"mkdir", "-p", path}
    local ok, result = process:run(command)
    if ok then return true end
    local reason = result and result.stderr
    reason = reason and reason:gsub("^%s+", ""):gsub("%s+$", "") or nil
    return false, reason ~= "" and reason or nil
  end

  function service:ensure_parent(path)
    local directory = path and select(1, self:split(path)) or nil
    if not directory or directory == "" then return true end
    return self:ensure_directory(directory)
  end

  function service:existing_directory(path)
    local directory = path
    while directory and directory ~= "" do
      local info = self:info(directory)
      if info and info.is_dir then return directory end
      local normalized = directory:gsub("[/\\]+$", "")
      local parent = select(1, self:split(normalized))
      if not parent or parent == "" or parent == directory then break end
      directory = parent
    end
    return path
  end

  function service:replace(source, target)
    local contents = self:read(source)
    if not contents then return false, "missing " .. tostring(source) end
    local temporary, backup = target .. ".update", target .. ".previous"
    if not self:write(temporary, contents) then
      return false, "cannot write " .. temporary
    end
    self:remove(backup)
    local had_target = self:read(target) ~= nil
    if had_target and not self:rename(target, backup) then
      self:remove(temporary)
      return false, "cannot replace " .. target
    end
    if not self:rename(temporary, target) then
      if had_target then self:rename(backup, target) end
      self:remove(temporary)
      return false, "cannot install " .. target
    end
    self:remove(backup)
    return true
  end

  function service:temporary_base()
    local path = os.tmpname()
    self:remove(path)
    return path
  end

  function service:extract_archive(archive, directory, callback)
    local ready, reason = self:ensure_directory(directory)
    if not ready then
      callback(false, {}, reason and
        ("could not create the temporary update directory: " .. reason) or
        "could not create the temporary update directory")
      return
    end
    local command
    if runtime.is_windows then
      command = windows_command.powershell(
        "Expand-Archive -Force -LiteralPath $argument1 " ..
          "-DestinationPath $argument2",
        {archive, directory})
    else
      command = {"unzip", "-oq", archive, "-d", directory}
    end
    process:run_async(command, nil, function(ok, result)
      if ok or runtime.is_windows then
        callback(ok, result, ok and nil or
          (result.stderr or "could not unpack release"))
        return
      end
      process:run_async({"tar", "-xf", archive, "-C", directory}, nil,
        function(tar_ok, tar_result)
          callback(tar_ok, tar_result, tar_ok and nil or
            (tar_result.stderr or result.stderr or "could not unpack release"))
        end)
    end)
  end

  function service:open(path, options, callback)
    options = options or {}
    if runtime.is_windows then path = self:normalize(path) end
    local command
    if runtime.is_windows then
      command = options.reveal and {"explorer", "/select," .. path} or
        windows_command.powershell(
          "Start-Process -FilePath $argument1", {path})
    elseif runtime.is_macos then
      command = options.reveal and {"open", "-R", path} or {"open", path}
    else
      local destination = options.reveal and
        select(1, self:split(path)) or path
      command = {"xdg-open", destination}
    end
    return process:run_async(command, nil, function(ok, result)
      if callback then callback(ok, result, path) end
    end)
  end

  function service:watch(directory, callback)
    local command
    if runtime.is_windows then
      command = windows_command.powershell(
        "$watcher=New-Object IO.FileSystemWatcher($argument1); " ..
          "$watcher.EnableRaisingEvents=$true; " ..
          "$watcher.WaitForChanged([IO.WatcherChangeTypes]::All) | Out-Null",
        {directory})
    elseif runtime.is_macos then
      command = {"sh", "-c",
        "command -v fswatch >/dev/null || exit 127; exec fswatch -1 -- $1",
        "material-osc-file-watch", directory}
    else
      command = {"sh", "-c",
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
        "material-osc-file-watch", directory}
    end
    return process:run_async(command, nil, callback)
  end

  return service
end

return filesystem
