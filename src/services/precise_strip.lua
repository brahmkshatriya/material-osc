-- Filmstrip for precise seeking (YouTube-style): a row of thumbnails below
-- the seekbar that slides with the precise position.
--
-- Thumbnails come from ffmpeg (falling back to mpv) in chunks of a few
-- tiles: one process decodes a short window once and emits every tile in it
-- as raw BGRA frames. Chunks run a few at a time, nearest to the playhead
-- first, and are cached for the current file. Tiles are shown as mpv
-- overlays (cropped at the strip edges through offset/stride), with the
-- playhead drawn as an overlay too because overlays sit above the OSD.
local precise_strip = {}

local CHUNK_TILES = 4
local MAX_JOBS = 3
local TILE_IDS_FIRST, TILE_IDS_LAST = 48, 62
local PLAYHEAD_ID = 63

function precise_strip.new(args)
  local mp, utils, msg = args.mp, args.utils, args.msg
  local service = {}
  local temp_dir = os.getenv("TEMP") or os.getenv("TMP") or
    mp.command_native({"expand-path", "~~cache"})
  local pid = tostring(mp.get_property_number("pid", 0) or 0)
  local generator = "ffmpeg"
  local chunks, files = {}, {}
  local running, file_counter = 0, 0
  local wanted = {}            -- chunk keys visible in the last update
  local shown = {}             -- overlay id -> placement signature
  local playhead = nil         -- {file, w, h}
  local video_path, aspect = nil, nil
  local disabled = false

  local function temp_file(name)
    file_counter = file_counter + 1
    local path = utils.join_path(temp_dir, string.format(
      "material-osc-strip-%s-%d-%s.bgra", pid, file_counter, name))
    files[#files + 1] = path
    return path
  end

  local function remove_overlay(id)
    if shown[id] then
      mp.command_native({"overlay-remove", tostring(id)})
      shown[id] = nil
    end
  end

  function service:clear()
    for id = TILE_IDS_FIRST, PLAYHEAD_ID do remove_overlay(id) end
  end

  local function reset_cache()
    service:clear()
    chunks, wanted = {}, {}
    for _, path in ipairs(files) do os.remove(path) end
    files = {}
    playhead, aspect = nil, nil
  end

  function service:available()
    return not disabled
  end

  -- video aspect ratio (display size), cached per file
  function service:aspect()
    if aspect then return aspect end
    local params = mp.get_property_native("video-out-params") or
      mp.get_property_native("video-params") or {}
    local w, h = tonumber(params.dw or params.w), tonumber(params.dh or params.h)
    if w and h and w > 0 and h > 0 then aspect = w / h end
    return aspect or 16 / 9
  end

  -- generation ----------------------------------------------------------------

  local function command_for(chunk)
    local vf = string.format(
      "fps=1/%.6f,scale=%d:%d:force_original_aspect_ratio=increase:" ..
      "flags=fast_bilinear,crop=%d:%d,format=bgra",
      chunk.interval, chunk.w, chunk.h, chunk.w, chunk.h)
    local start = string.format("%.3f", chunk.start)
    local length = string.format("%.3f", chunk.interval * CHUNK_TILES)
    if generator == "ffmpeg" then
      return {"ffmpeg", "-v", "error", "-nostdin", "-skip_loop_filter", "all",
        "-flags2", "fast", "-ss", start, "-t", length, "-i", chunk.path,
        "-an", "-sn", "-dn", "-vf", vf, "-f", "rawvideo", "-y", chunk.file}
    end
    return {"mpv", "--no-config", "--msg-level=all=no", "--start=" .. start,
      "--length=" .. length, "--hr-seek=yes", "--audio=no", "--sub=no",
      "--vd-lavc-skiploopfilter=all", "--vd-lavc-fast", "--vf=" .. vf,
      "--ovc=rawvideo", "--of=rawvideo", "-o", chunk.file, chunk.path}
  end

  local schedule

  local function run(chunk)
    running = running + 1
    chunk.status = "running"
    chunk.file = chunk.file or temp_file(chunk.key:gsub("[^%w]", ""))
    mp.command_native_async({
      name = "subprocess", args = command_for(chunk), playback_only = false,
      capture_stdout = true, capture_stderr = true
    }, function(success, result)
      running = running - 1
      if chunks[chunk.key] ~= chunk then schedule(); return end
      local info = utils.file_info(chunk.file)
      local frame_bytes = chunk.w * chunk.h * 4
      -- a non-empty error_string means the process could not run at all
      local launch_failed = not success or not result or
        (result.error_string or "") ~= ""
      msg.verbose(string.format("precise strip: chunk %s status=%s size=%s %s",
        chunk.key, tostring(result and result.status), tostring(info and info.size),
        tostring(result and result.stderr or "")))
      if not launch_failed and result.status == 0 and info and
        info.size >= frame_bytes then
        chunk.frames = math.floor(info.size / frame_bytes)
        -- pad the file: an edge-cropped tile maps a few bytes past its frame
        local handle = io.open(chunk.file, "ab")
        if handle then
          handle:write(string.rep("\0", chunk.w * 4))
          handle:close()
        end
        chunk.status = "ready"
        args.render()
      elseif launch_failed and generator == "ffmpeg" then
        -- ffmpeg is not available: retry this and future chunks with mpv
        msg.verbose("precise strip: ffmpeg unavailable, using mpv")
        generator = "mpv"
        chunk.status = "pending"
      elseif launch_failed then
        msg.warn("precise strip: thumbnail generation failed; strip disabled")
        disabled = true
        chunk.status = "failed"
      else
        -- e.g. past the end of the file
        chunk.status = "failed"
      end
      schedule()
    end)
  end

  -- start the nearest pending visible chunks while slots are free
  schedule = function()
    while running < MAX_JOBS do
      local best, best_distance = nil, nil
      for key, distance in pairs(wanted) do
        local chunk = chunks[key]
        if chunk and chunk.status == "pending" and
          (not best_distance or distance < best_distance) then
          best, best_distance = chunk, distance
        end
      end
      if not best then return end
      run(best)
    end
  end

  -- placement -----------------------------------------------------------------

  local function ensure_playhead(h)
    if playhead and playhead.h == h then return playhead end
    local w = 2
    local file = temp_file("playhead" .. h)
    local handle = io.open(file, "wb")
    if not handle then return nil end
    handle:write(string.rep("\255\255\255\255", w * h))
    handle:close()
    playhead = {file = file, w = w, h = h}
    return playhead
  end

  local function place(id, signature, command)
    if shown[id] == signature then return end
    for index, value in ipairs(command) do command[index] = tostring(value) end
    mp.command_native(command)
    shown[id] = signature
  end

  -- geometry: strip rect (x1, y1, x2, y2), center_x, position, duration,
  -- seconds_per_px, tile_w, tile_h. Returns tile rects for placeholders.
  function service:update(geometry)
    if disabled then return {} end
    local path = mp.get_property("path")
    if path ~= video_path then
      reset_cache()
      video_path = path
    end
    if not path then return {} end

    local tile_w, tile_h = geometry.tile_w, geometry.tile_h
    local gap = 2
    local px_per_second = 1 / geometry.seconds_per_px
    local interval = tile_w * geometry.seconds_per_px
    local position, center_x = geometry.position, geometry.center_x
    local x1, x2 = geometry.x1, geometry.x2
    local first = math.floor((position - (center_x - x1) *
      geometry.seconds_per_px) / interval)
    local last = math.floor((position + (x2 - center_x) *
      geometry.seconds_per_px) / interval)
    local max_index = math.floor(geometry.duration / interval)
    first, last = math.max(0, first), math.min(max_index, last)
    local center_index = math.floor(position / interval)

    wanted = {}
    local tiles, used_ids = {}, {}
    local next_id = TILE_IDS_FIRST
    local image_w, image_h = tile_w - gap, tile_h
    for index = first, last do
      local group = math.floor(index / CHUNK_TILES)
      local key = string.format("%dx%d@%.4f#%d", image_w, image_h, interval, group)
      local chunk = chunks[key]
      if not chunk then
        chunk = {
          key = key, path = path, w = image_w, h = image_h,
          interval = interval, status = "pending",
          -- sample the middle of each tile's time range
          start = group * CHUNK_TILES * interval + interval / 2
        }
        chunks[key] = chunk
      end
      local distance = math.abs(index - center_index)
      if not wanted[key] or distance < wanted[key] then wanted[key] = distance end

      local tile_x = math.floor(center_x + (index * interval - position) *
        px_per_second + 0.5)
      local tile = {x1 = tile_x, x2 = tile_x + image_w, ready = false}
      tiles[#tiles + 1] = tile
      local frame = index - group * CHUNK_TILES
      if chunk.status == "ready" and frame < (chunk.frames or 0) and
        next_id <= TILE_IDS_LAST then
        -- crop the overlay to the strip through offset/width
        local visible_x1 = math.max(tile_x, math.ceil(x1))
        local visible_x2 = math.min(tile_x + image_w, math.floor(x2))
        local crop_w = visible_x2 - visible_x1
        if crop_w > 0 then
          tile.ready = true
          local offset = frame * image_w * image_h * 4 +
            (visible_x1 - tile_x) * 4
          local y = math.floor(geometry.y1 + 0.5)
          local id = next_id
          next_id = next_id + 1
          used_ids[id] = true
          place(id, table.concat({chunk.file, visible_x1, y, offset, crop_w}, "|"),
            {"overlay-add", id, visible_x1, y, chunk.file, offset, "bgra",
              crop_w, image_h, image_w * 4})
        end
      end
    end
    for id = TILE_IDS_FIRST, TILE_IDS_LAST do
      if not used_ids[id] then remove_overlay(id) end
    end

    local line = ensure_playhead(tile_h + 8)
    if line then
      local x = math.floor(center_x - line.w / 2 + 0.5)
      local y = math.floor(geometry.y1 - 4 + 0.5)
      place(PLAYHEAD_ID, table.concat({line.file, x, y}, "|"),
        {"overlay-add", PLAYHEAD_ID, x, y, line.file, 0, "bgra",
          line.w, line.h, line.w * 4})
    end
    schedule()
    return tiles
  end

  mp.register_event("start-file", reset_cache)
  mp.register_event("shutdown", reset_cache)

  -- files of earlier sessions can survive when mpv quit while a chunk was
  -- still being written (Windows cannot delete an open file)
  for _, name in ipairs(utils.readdir(temp_dir, "files") or {}) do
    local owner = name:match("^material%-osc%-strip%-(%d+)%-")
    if owner and owner ~= pid then os.remove(utils.join_path(temp_dir, name)) end
  end

  return service
end

return precise_strip
