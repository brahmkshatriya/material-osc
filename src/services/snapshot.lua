local snapshot = {}

function snapshot.reader(deps)
  local runtime = deps.runtime
  local format_time = deps.format_time
  local friendly_quality_label = deps.friendly_quality_label
  assert(type(friendly_quality_label) == "function",
    "snapshot.reader requires friendly_quality_label")
  local configured_volume_max = deps.configured_volume_max
  local is_buffering = deps.is_buffering

  return function()
    local duration = mp.get_property_number("duration", 0) or 0
    local position = mp.get_property_number("time-pos", 0) or 0
    local chapters = mp.get_property_native("chapter-list") or {}
    local chapter_index = mp.get_property_number("chapter", -1) or -1
    local displayed_time
    if runtime.time.show_remaining and duration > 0 then
      displayed_time = "-" .. format_time(math.max(0, duration - position))
    else
      displayed_time = format_time(position)
    end

    local chapter_name = nil
    local chapter = chapters[chapter_index + 1]
    if chapter and type(chapter.title) == "string" and not chapter.title:match("^%s*$") then
      chapter_name = chapter.title
    end

    local video_id = mp.get_property_number("vid", 0) or 0
    local video_items = {}
    local image_items = {}
    local video_stream_index = 0
    local subtitle_id = mp.get_property_number("sid", 0) or 0
    local subtitle_items = {{id = 0, label = "Off", language = nil}}
    local audio_id = mp.get_property_number("aid", 0) or 0
    local audio_items = {{id = 0, label = "Off", language = nil}}
    local function technical_details(track, kind)
      local details = {}
      local codec = track.codec
      if type(codec) == "string" and codec ~= "" then
        details[#details + 1] = codec
      end
      local bitrate = tonumber(track["demux-bitrate"]) or
        tonumber(track["hls-bitrate"])
      if kind == "video" then
        local width, height = tonumber(track["demux-w"]),
          tonumber(track["demux-h"])
        if width and width > 0 and height and height > 0 then
          details[#details + 1] = string.format("%dx%d", width, height)
        end
        local fps = tonumber(track["demux-fps"])
        if fps and fps > 0 then
          details[#details + 1] = string.format("%g fps", fps)
        end
        if bitrate and bitrate > 0 then
          details[#details + 1] = string.format("%d Kbps",
            math.floor(bitrate / 1000 + 0.5))
        end
      else
        if bitrate and bitrate > 0 then
          details[#details + 1] = string.format("%d Kbps",
            math.floor(bitrate / 1000 + 0.5))
        end
        local sample_rate = tonumber(track["demux-samplerate"])
        if sample_rate and sample_rate > 0 then
          details[#details + 1] = string.format("%g Hz", sample_rate)
        end
      end
      return table.concat(details, " · ")
    end
    for _, track in ipairs(mp.get_property_native("track-list") or {}) do
      if track.type == "video" then
        local label = track.title
        if type(label) ~= "string" or label:match("^%s*$") then
          local resolution = track["demux-w"] and track["demux-h"] and
            (tostring(track["demux-w"]) .. "×" .. tostring(track["demux-h"])) or nil
          label = resolution or ("Video " .. tostring(track.id))
        end
        local item = {
          id = tonumber(track.id) or track.id,
          label = label,
          language = track.lang,
          height = tonumber(track["demux-h"]),
          details = technical_details(track, "video")
        }
        if track.albumart == true or track.image == true then
          item.image = true
          item.video_index = video_stream_index
          item.details = item.details ~= "" and item.details or "Image"
          image_items[#image_items + 1] = item
        else
          video_items[#video_items + 1] = item
        end
        video_stream_index = video_stream_index + 1
      elseif track.type == "sub" then
        local label = track.title
        if type(label) ~= "string" or label:match("^%s*$") then
          label = track.lang and ("Subtitle " .. tostring(track.id)) or
            ("Subtitle " .. tostring(track.id))
        end
        subtitle_items[#subtitle_items + 1] = {
          id = tonumber(track.id) or track.id,
          label = label,
          language = track.lang
        }
      elseif track.type == "audio" then
        local label = track.title
        if type(label) ~= "string" or label:match("^%s*$") then
          label = "Audio " .. tostring(track.id)
        end
        audio_items[#audio_items + 1] = {
          id = tonumber(track.id) or track.id,
          label = label,
          language = track.lang,
          details = technical_details(track, "audio")
        }
      end
    end

    if runtime.ytdl.active and #runtime.ytdl.items > 0 then
      local native_video_items = video_items
      video_items = runtime.ytdl.items
      for _, item in ipairs(video_items) do
        for _, native_item in ipairs(native_video_items) do
          if item.height and native_item.height == item.height then
            item.details = native_item.details
            if (tonumber(item.fps) or 0) <= 0 then
              local fps = native_item.details and
                native_item.details:match("([%d%.]+) fps$")
              item.fps = tonumber(fps) or item.fps
            end
            item.label = friendly_quality_label(item.height, item.fps)
            break
          end
        end
      end
      local params = mp.get_property_native("video-out-params") or {}
      local current_height = tonumber(params.h)
      local current_fps = mp.get_property_number("container-fps") or
        mp.get_property_number("estimated-vf-fps")
      local rounded_fps = current_fps and math.floor(current_fps + 0.5) or 0
      video_id = runtime.ytdl.selected_id
      if not video_id then
        for _, item in ipairs(video_items) do
          if item.height == current_height and
            (rounded_fps == 0 or (tonumber(item.fps) or 0) == 0 or
              item.fps == rounded_fps) then
            video_id = item.id
            break
          end
        end
      end
    end

    local video_track_count = #video_items
    if #image_items > 0 then
      video_items[#video_items + 1] = {separator = true, label = "Images"}
      for _, item in ipairs(image_items) do
        video_items[#video_items + 1] = item
      end
    end

    return {
      duration = duration,
      position = position,
      paused = mp.get_property_native("pause") == true,
      muted = mp.get_property_native("mute") == true,
      fullscreen = mp.get_property_native("fullscreen") == true,
      volume = mp.get_property_number("volume", 0) or 0,
      speed = mp.get_property_number("speed", 1) or 1,
      sub_visibility = mp.get_property_native("sub-visibility") ~= false,
      subtitle_delay = mp.get_property_number("sub-delay", 0) or 0,
      subtitle_font_size = mp.get_property_number("sub-font-size", 38) or 38,
      subtitle_border_size = mp.get_property_number("sub-border-size", 1.65) or 1.65,
      subtitle_color = mp.get_property("sub-color", "#FFFFFFFF") or "#FFFFFFFF",
      subtitle_font = mp.get_property("sub-font", "sans-serif") or "sans-serif",
      volume_max = math.max(100, mp.get_property_number("volume-max", configured_volume_max) or configured_volume_max),
      chapter_index = chapter_index,
      chapters = chapters,
      subtitle_items = subtitle_items,
      subtitle_id = subtitle_id,
      audio_items = audio_items,
      audio_id = audio_id,
      chapter_name = chapter_name,
      time_text = displayed_time .. " / " .. format_time(duration),
      buffering = is_buffering(),
      network = mp.get_property_native("demuxer-via-network") == true,
      cache_state = mp.get_property_native("demuxer-cache-state") or {},
      video_id = video_id,
      video_present = (mp.get_property_number("vid", 0) or 0) > 0,
      video_items = video_items,
      video_track_count = video_track_count,
      video_params = mp.get_property_native("video-out-params") or {}
    }
  end


end

return snapshot
