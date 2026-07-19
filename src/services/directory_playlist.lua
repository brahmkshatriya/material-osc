local directory_playlist = {}

local MEDIA_EXTENSIONS = {
  -- Video
  ["3g2"] = true, ["3gp"] = true, ["asf"] = true, ["avi"] = true,
  ["flv"] = true, ["m2ts"] = true, ["m4v"] = true, ["mkv"] = true,
  ["mov"] = true, ["mp4"] = true, ["mpeg"] = true, ["mpg"] = true,
  ["mts"] = true, ["ogm"] = true, ["ogv"] = true, ["rm"] = true,
  ["rmvb"] = true, ["ts"] = true, ["vob"] = true, ["webm"] = true,
  ["wmv"] = true,
  -- Audio
  ["aac"] = true, ["ac3"] = true, ["aiff"] = true, ["alac"] = true,
  ["ape"] = true, ["dts"] = true, ["flac"] = true, ["m4a"] = true,
  ["mka"] = true, ["mp3"] = true, ["oga"] = true, ["ogg"] = true,
  ["opus"] = true, ["wav"] = true, ["wma"] = true,
}

local function extension(path)
  return tostring(path):match("%.([^./\\]+)$")
end

local function is_remote(path)
  return path == "-" or path:match("^%a[%w+.-]*://") ~= nil
end

function directory_playlist.new(args)
  local mp, utils, opts = args.mp, args.utils, args.opts
  local service = {}
  local is_windows = package.config:sub(1, 1) == "\\"

  local function same_name(left, right)
    if is_windows then return left:lower() == right:lower() end
    return left == right
  end

  function service:load()
    if opts.directory_playlist == false then return end

    -- An existing playlist was deliberately supplied, so do not replace or
    -- expand it. Adjacent files loaded by this service also take this path.
    local playlist = mp.get_property_native("playlist") or {}
    if #playlist ~= 1 then return end

    local source = mp.get_property("path", "") or ""
    if source == "" or is_remote(source) then return end

    local directory, current_name = utils.split_path(source)
    if not current_name or current_name == "" then return end
    if not directory or directory == "" then
      directory = mp.get_property("working-directory", ".") or "."
    end

    local filenames = utils.readdir(directory, "files")
    if not filenames then return end

    local items = {}
    for _, name in ipairs(filenames) do
      local ext = extension(name)
      if same_name(name, current_name) or
        (ext and MEDIA_EXTENSIONS[ext:lower()]) then
        local path = utils.join_path(directory, name)
        local info = utils.file_info(path)
        if info and info.is_file then
          items[#items + 1] = {
            name = name,
            path = path,
            mtime = tonumber(info.mtime) or 0,
            current = same_name(name, current_name)
          }
        end
      end
    end

    if #items < 2 then return end
    local sort_mode = tostring(opts.directory_playlist_sort):lower()
    local function name_before(left, right)
      local left_name, right_name = left.name:lower(), right.name:lower()
      if left_name ~= right_name then return left_name < right_name end
      return left.name < right.name
    end

    table.sort(items, function(left, right)
      if sort_mode == "oldest" and left.mtime ~= right.mtime then
        return left.mtime < right.mtime
      end
      if sort_mode == "newest" and left.mtime ~= right.mtime then
        return left.mtime > right.mtime
      end
      return name_before(left, right)
    end)

    local current_position
    for position, item in ipairs(items) do
      if item.current then
        current_position = position
      else
        mp.commandv("loadfile", item.path, "append")
      end
    end

    -- The current file starts at index zero. mpv's destination is the slot
    -- before which it inserts, so moving forward uses the one-based position.
    if current_position and current_position > 1 then
      mp.commandv("playlist-move", 0, current_position)
    end
  end

  return service
end

return directory_playlist
