local hls_module = {}

local function resolve_url(base, value)
  if value:match("^https?://") then return value end
  if value:sub(1, 1) == "/" then
    local origin = base:match("^(https?://[^/]+)")
    return origin and (origin .. value) or value
  end
  local directory = base:match("^(.*)/[^/]*$")
  return directory and (directory .. "/" .. value) or value
end

local function attribute(line, name)
  return line:match(name .. '="([^"]+)"') or line:match(name .. "=([^,]+)")
end

local function parse_master_playlist(url, body)
  local items, stream_info = {}, nil
  for line in (body .. "\n"):gmatch("([^\r\n]*)[\r\n]+") do
    if line:match("^#EXT%-X%-STREAM%-INF:") then
      stream_info = line
    elseif stream_info and line ~= "" and not line:match("^#") then
      local width, height = (attribute(stream_info, "RESOLUTION") or ""):match("(%d+)x(%d+)")
      height = tonumber(height)
      if height then
        local fps = tonumber(attribute(stream_info, "FRAME%-RATE")) or 0
        local bandwidth = tonumber(attribute(stream_info, "AVERAGE%-BANDWIDTH")) or
          tonumber(attribute(stream_info, "BANDWIDTH")) or 0
        items[#items + 1] = {
          id = "hls:" .. tostring(height) .. ":" .. tostring(#items + 1),
          label = tostring(height) .. "p" ..
            (fps > 30 and (" " .. tostring(math.floor(fps + 0.5)) .. "fps") or ""),
          stream_quality = true, source = "hls",
          selector = "hls", playback_url = resolve_url(url, line),
          width = tonumber(width), height = height, fps = fps,
          bandwidth = bandwidth
        }
      end
      stream_info = nil
    end
  end
  table.sort(items, function(a, b)
    if a.height ~= b.height then return a.height > b.height end
    if a.fps ~= b.fps then return a.fps > b.fps end
    return a.bandwidth > b.bandwidth
  end)
  return items
end

function hls_module.supports(url)
  if type(url) ~= "string" or not url:match("^https?://") then return false end
  local path = url:lower():match("^[^?#]+") or ""
  return path:sub(-5) == ".m3u8"
end

function hls_module.new(args)
  local state = args.runtime.ytdl
  local service = {}

  function service:load_qualities()
    local path = mp.get_property("path", "") or ""
    if state.pending_playback_url and path == state.pending_playback_url then
      state.selected_id = state.pending_selected_id or state.selected_id
      state.pending_selected_id, state.pending_playback_url = nil, nil
      return
    end
    if not hls_module.supports(path) then return false end

    state.request_id = state.request_id + 1
    local request_id = state.request_id
    state.active, state.source, state.url = true, "hls", path
    state.items, state.caption_items = {}, {}
    state.selected_id, state.pending_selected_id = nil, nil
    mp.command_native_async({
      name = "subprocess", playback_only = false, capture_stdout = true,
      capture_stderr = true,
      args = {"curl", "--location", "--fail", "--silent", "--show-error", path}
    }, function(success, result)
      if request_id ~= state.request_id or not success or not result or
        result.status ~= 0 then return end
      state.items = parse_master_playlist(path, result.stdout or "")
      state.active = #state.items > 0
      args.render()
    end)
    return true
  end

  return service
end

local youtube_module = require "src.services.ytdl_service"

local stream_quality = {
  quality_label = youtube_module.quality_label,
  supports_youtube = youtube_module.supports
}

function stream_quality.new(args)
  local youtube = youtube_module.new(args)
  local hls = hls_module.new(args)
  local service = {}

  function service:load()
    local path = mp.get_property("path", "") or ""
    if hls_module.supports(path) then hls:load_qualities()
    else youtube.load_qualities() end
  end

  function service:select(item) youtube.select_quality(item) end
  function service:restore_subtitles() youtube.restore_subtitles() end
  function service:attach_caption(item) youtube.attach_caption(item) end

  return service
end

return stream_quality
