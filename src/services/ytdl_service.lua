local ytdl_service = {}

local function quality_label(height, fps)
  height, fps = tonumber(height) or 0, tonumber(fps) or 0
  local label = height > 0 and (tostring(height) .. "p") or "Video"
  if height == 2160 then label = label .. " (4K)"
  elseif height == 4320 then label = label .. " (8K)" end
  if fps > 30 then label = label .. " " .. tostring(math.floor(fps + 0.5)) .. "fps" end
  return label
end

ytdl_service.quality_label = quality_label

function ytdl_service.supports(url)
  if type(url) ~= "string" then return false end
  url = url:gsub("^ytdl://", "")
  local host = url:match("^https?://([^/%?#]+)")
  if not host then return false end
  host = host:lower():gsub(":%d+$", "")
  return host == "youtu.be" or host == "youtube.com" or
    host:match("%.youtube%.com$") ~= nil or
    host == "youtube-nocookie.com" or
    host:match("%.youtube%-nocookie%.com$") ~= nil
end

local function append_raw_options(command)
  local options = mp.get_property_native("ytdl-raw-options") or {}
  if type(options) ~= "table" then return end
  for key, value in pairs(options) do
    if value == true or value == "" then
      command[#command + 1] = "--" .. tostring(key)
    elseif value ~= false and value ~= nil then
      command[#command + 1] = "--" .. tostring(key)
      command[#command + 1] = tostring(value)
    end
  end
end

function ytdl_service.new(args)
  local state = args.runtime.ytdl

  local function select_quality(item)
    if not item or not item.selector or not state.url then return end
    local position = mp.get_property_number("time-pos", 0) or 0
    local paused = mp.get_property_native("pause") == true
    local media_title = mp.get_property("media-title", "") or ""
    state.selected_id, state.pending_selected_id = item.id, item.id
    state.pending_playback_url = item.playback_url
    local subtitles = {}
    for _, track in ipairs(mp.get_property_native("track-list") or {}) do
      if track.type == "sub" and track.external and track["external-filename"] then
        subtitles[#subtitles + 1] = {
          url = track["external-filename"], title = track.title,
          language = track.lang, selected = track.selected == true
        }
      end
    end
    state.pending_subtitles = {
      tracks = subtitles,
      visible = mp.get_property_native("sub-visibility") ~= false
    }
    local load_options = {
      start = tostring(position), pause = paused and "yes" or "no"
    }
    if not item.playback_url then
      load_options["ytdl-format"] = item.selector
    end
    if media_title ~= "" then load_options["force-media-title"] = media_title end
    args.runtime.loading.quality_switching = true
    args.runtime.loading.started_ms = mp.get_time() * 1000
    args.render()
    if args.before_quality_reload then args.before_quality_reload() end
    mp.command_native({name = "loadfile", url = item.playback_url or state.url,
      flags = "replace", options = load_options})
  end

  local function restore_subtitles()
    local pending = state.pending_subtitles
    if type(pending) ~= "table" then return end
    state.pending_subtitles = nil
    for _, subtitle in ipairs(pending.tracks or {}) do
      mp.commandv("sub-add", subtitle.url, subtitle.selected and "select" or "auto",
        subtitle.title or "Subtitle", subtitle.language or "und")
    end
    mp.set_property_native("sub-visibility", pending.visible ~= false)
  end

  local function attach_caption(item)
    if not item or not item.url or state.caption_loading_id then return end
    state.caption_request_id = state.caption_request_id + 1
    local request_id = state.caption_request_id
    state.caption_loading_id = item.id
    args.render()
    mp.command_native_async({"sub-add", item.url, "select",
      item.track_title or item.label, item.language}, function(success, result)
      if request_id ~= state.caption_request_id then return end
      state.caption_loading_id = nil
      if success and (not result or result.status == nil or result.status == 0) then
        args.set_settings_page("subtitles")
      else
        mp.osd_message("Failed to load auto subtitle", 3)
      end
      args.render()
    end)
  end

  local function load_qualities()
    local path = mp.get_property("path", "") or ""
    if state.pending_playback_url and path == state.pending_playback_url then
      state.selected_id = state.pending_selected_id or state.selected_id
      state.pending_selected_id, state.pending_playback_url = nil, nil
      return
    end
    if not ytdl_service.supports(path) then
      state.active, state.source, state.url = false, nil, nil
      state.items, state.caption_items = {}, {}
      state.selected_id, state.pending_selected_id = nil, nil
      state.pending_playback_url = nil
      return
    end
    if state.active and state.url == path and #state.items > 0 then
      state.selected_id = state.pending_selected_id or state.selected_id
      state.pending_selected_id = nil
      return
    end
    state.request_id = state.request_id + 1
    local request_id = state.request_id
    state.items, state.caption_items, state.selected_id = {}, {}, nil
    state.active, state.source, state.url = true, "youtube", path
    local command = {"yt-dlp", "--dump-single-json", "--no-playlist", "--no-warnings", path}
    append_raw_options(command)
    mp.command_native_async({name = "subprocess", args = command,
      playback_only = false, capture_stdout = true, capture_stderr = true},
      function(success, result)
        if request_id ~= state.request_id or not success or not result or
          result.status ~= 0 then return end
        local data = args.utils.parse_json(result.stdout or "")
        if not data or type(data.formats) ~= "table" then return end
        local best = {}
        for _, format in ipairs(data.formats) do
          local height, width, fps = tonumber(format.height),
            tonumber(format.width), tonumber(format.fps)
          local id = tostring(format.format_id or "")
          if height and width and id ~= "" and format.vcodec and format.vcodec ~= "none" then
            local rounded_fps = fps and math.floor(fps + 0.5) or 0
            local key = tostring(height)
            local score = rounded_fps * 10000000 +
              (tonumber(format.tbr) or tonumber(format.vbr) or 0)
            if not best[key] or score > best[key].score then
              best[key] = {score = score, width = width, height = height,
                fps = rounded_fps, format_id = id,
                has_audio = format.acodec and format.acodec ~= "none",
                playback_url = format.protocol and
                  format.protocol:match("^m3u8") and
                  format.manifest_url == path and format.url or nil}
            end
          end
        end
        local items = {}
        for key, entry in pairs(best) do
          items[#items + 1] = {id = "ytdl:" .. key,
            label = quality_label(entry.height, entry.fps),
            stream_quality = true, source = "youtube",
            selector = entry.has_audio and entry.format_id or
              (entry.format_id .. "+bestaudio/best"),
            playback_url = entry.playback_url,
            width = entry.width, height = entry.height, fps = entry.fps}
        end
        table.sort(items, function(a, b)
          if a.height ~= b.height then return a.height > b.height end
          return a.fps > b.fps
        end)
        state.items = items
        local captions = {}
        for language, formats in pairs(data.automatic_captions or {}) do
          local selected
          for _, caption in ipairs(formats) do
            if caption.ext == "vtt" then selected = caption break end
          end
          selected = selected or formats[1]
          if selected and selected.url then
            local name = selected.name or tostring(language)
            captions[#captions + 1] = {id = "auto:" .. tostring(language),
              label = name, track_title = name .. " (Auto)",
              language = tostring(language), url = selected.url}
          end
        end
        table.sort(captions, function(a, b) return a.label < b.label end)
        state.caption_items = captions
        args.render()
      end)
  end

  return {select_quality = select_quality, restore_subtitles = restore_subtitles,
    attach_caption = attach_caption, load_qualities = load_qualities}
end

return ytdl_service
