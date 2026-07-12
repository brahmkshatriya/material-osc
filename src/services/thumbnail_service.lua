local thumbnail_worker = {}

function thumbnail_worker.new(deps)
  local state = deps.thumbnail_state
  local get_snapshot = deps.get_snapshot
  local opts = deps.opts
  local utils = deps.utils
  local msg = deps.msg
  local dp = deps.dp
  local clamp = deps.clamp
  local format_time = deps.format_time
  local chapter_name_at = deps.chapter_name_at
  local get_script_dir = deps.get_script_dir
  local enqueue_effect = deps.enqueue_effect
  local render = deps.render
  local draw_box = deps.draw_box
  local draw_text = deps.draw_text
  local draw_loading_shape_morph = deps.draw_loading_shape_morph
  local text_intrinsic_width = deps.text_intrinsic_width
  local truncate_utf8_to_width = deps.truncate_utf8_to_width
  local thumbnail_service = {}

  local function has_thumbnail_video_track()
    for _, track in ipairs(mp.get_property_native("track-list") or {}) do
      if track.type == "video" and track.selected == true then
        if track.albumart ~= true then return true end
      end
    end
    return false
  end

  function thumbnail_service:is_ready()
    return opts.thumbnails and get_snapshot().video_present == true and
         has_thumbnail_video_track() and
         (not get_snapshot().network or
          opts.network_thumbnails)
  end

  function thumbnail_service:clear()
    local thumbnail = state
    if thumbnail.request_timer then
      thumbnail.request_timer:kill()
      thumbnail.request_timer = nil
    end
    if thumbnail.exact_timer then
      thumbnail.exact_timer:kill()
      thumbnail.exact_timer = nil
    end

    thumbnail.request_id = thumbnail.request_id + 1
    thumbnail.pending_pos = nil
    thumbnail.request_pos = nil
    thumbnail.loading = false
    thumbnail.visible = false
    thumbnail.target_x = nil
    thumbnail.target_y = nil
    thumbnail.display_x = nil
    thumbnail.display_y = nil
    thumbnail.last_seek_at = -math.huge
    mp.commandv("overlay-remove", thumbnail.overlay_id)
  end

  local thumbnail_seek_period = 3 / 60
  local thumbnail_exact_delay = 0.12
  local thumbnail_poll_period = 1 / 60
  local thumbnail_is_windows = (jit and jit.os == "Windows") or
                     package.config:sub(1, 1) == "\\"

  local thumbnail_client_script = [=[
  #!/usr/bin/env bash
  MPV_IPC_FD=0
  MPV_IPC_PATH="%s"
  trap "kill 0" EXIT
  while [[ $# -ne 0 ]]; do
    case $1 in
      --mpv-ipc-fd=*) MPV_IPC_FD=${1/--mpv-ipc-fd=/} ;;
    esac
    shift
  done
  if echo "print-text material-osc-thumbnail" >&"$MPV_IPC_FD"; then
    echo -n > "$MPV_IPC_PATH"
    tail -f "$MPV_IPC_PATH" >&"$MPV_IPC_FD" &
    while read -r -u "$MPV_IPC_FD" 2>/dev/null; do :; done
  fi
  ]=]

  local function thumbnail_source_dimensions(params)
    params = params or {}

    -- Prefer the selected track's intrinsic frame size for every video.  The
    -- output dimensions can describe mpv's display canvas and make both cover
    -- art and unusually shaped videos appear as a generic widescreen preview.
    for _, track in ipairs(mp.get_property_native("track-list") or {}) do
      if track.type == "video" and track.selected == true then
        local width = tonumber(track["demux-w"])
        local height = tonumber(track["demux-h"])
        if width and width > 0 and height and height > 0 then
          return width, height
        end
      end
    end

    local width = tonumber(params.w or params.dw)
    local height = tonumber(params.h or params.dh)
    if width and width > 0 and height and height > 0 then
      return width, height
    end
    return 16, 9
  end

  local function thumbnail_preview_dimensions(params)
    local source_width, source_height = thumbnail_source_dimensions(params)
    local max_width = dp(240)
    local max_height = dp(160)
    local scale = math.min(max_width / source_width, max_height / source_height)
    return math.max(1, math.floor(source_width * scale + 0.5)),
         math.max(1, math.floor(source_height * scale + 0.5))
  end

  function thumbnail_service:desired_dimensions()
    local params = mp.get_property_native("video-out-params") or
             get_snapshot().video_params or {}
    return thumbnail_preview_dimensions(params)
  end

  function thumbnail_service:can_thumbnail_current_file()
    if not opts.thumbnails then return false end
    if (mp.get_property_number("vid", 0) or 0) <= 0 then return false end
    if not has_thumbnail_video_track() then return false end
    if mp.get_property_native("demuxer-via-network") == true and
      not opts.network_thumbnails then return false end
    local source = mp.get_property("path")
    return source ~= nil and source ~= ""
  end

  function thumbnail_service:remove_display_file()
    if state.file then os.remove(state.file) end
    state.file = nil
    state.file_width = 0
    state.file_height = 0
  end

  function thumbnail_service:close_worker_command_file()
    local handle = state.worker_command_handle
    if handle then pcall(function() handle:close() end) end
    state.worker_command_handle = nil
  end

  function thumbnail_service:stop_worker(preserve_display)
    local thumbnail = state
    if thumbnail.worker_id then
      mp.abort_async_command(thumbnail.worker_id)
      thumbnail.worker_id = nil
    end
    if thumbnail.poll_timer then
      thumbnail.poll_timer:kill()
      thumbnail.poll_timer = nil
    end
    if thumbnail.prewarm_timer then
      thumbnail.prewarm_timer:kill()
      thumbnail.prewarm_timer = nil
    end

    self:close_worker_command_file()
    if thumbnail.worker_socket then os.remove(thumbnail.worker_socket) end
    if thumbnail.worker_command_file then os.remove(thumbnail.worker_command_file) end
    if thumbnail.worker_client_script then os.remove(thumbnail.worker_client_script) end
    if thumbnail.worker_output then os.remove(thumbnail.worker_output) end
    if thumbnail.worker_candidate then os.remove(thumbnail.worker_candidate) end

    thumbnail.worker_socket = nil
    thumbnail.worker_command_file = nil
    thumbnail.worker_client_script = nil
    thumbnail.worker_output = nil
    thumbnail.worker_candidate = nil
    thumbnail.worker_display = nil
    thumbnail.worker_width = 0
    thumbnail.worker_height = 0
    thumbnail.worker_source = nil

    if not preserve_display then self:remove_display_file() end
  end

  function thumbnail_service:add_overlay(width, height)
    local thumbnail = state
    if not thumbnail.file or thumbnail.file_width ~= width or
      thumbnail.file_height ~= height then return false end

    local x = thumbnail.target_x or 0
    local y = thumbnail.target_y or 0
    mp.command_native_async({"overlay-add", thumbnail.overlay_id,
                 x, y, thumbnail.file, 0, "bgra", width, height,
                 width * 4}, function() end)
    thumbnail.display_x = x
    thumbnail.display_y = y
    thumbnail.visible = true
    return true
  end

  function thumbnail_service:show_completed(width, height)
    local thumbnail = state
    if not thumbnail.worker_output or not thumbnail.worker_candidate or
      not thumbnail.worker_display then return end

    -- Move the writer's output before checking it. This prevents the worker from
    -- replacing the file between the size check and overlay-add.
    os.remove(thumbnail.worker_candidate)
    if not os.rename(thumbnail.worker_output, thumbnail.worker_candidate) then return end

    local info = utils.file_info(thumbnail.worker_candidate)
    if not info or info.size ~= width * height * 4 then
      os.remove(thumbnail.worker_candidate)
      return
    end

    -- POSIX rename atomically replaces the displayed frame. Keep a fallback for
    -- filesystems that reject replacing an existing destination.
    if not os.rename(thumbnail.worker_candidate, thumbnail.worker_display) then
      os.remove(thumbnail.worker_display)
      if not os.rename(thumbnail.worker_candidate, thumbnail.worker_display) then
        os.remove(thumbnail.worker_candidate)
        return
      end
    end

    thumbnail.file = thumbnail.worker_display
    thumbnail.file_width = width
    thumbnail.file_height = height
    if thumbnail.request_pos ~= nil then
      self:add_overlay(width, height)
      thumbnail.loading = false
      render()
    end
  end

  function thumbnail_service:write_direct_command(command)
    local thumbnail = state
    if not thumbnail.worker_command_file then return false end
    if not thumbnail.worker_command_handle then
      thumbnail.worker_command_handle = io.open(thumbnail.worker_command_file, "r+")
    end
    local handle = thumbnail.worker_command_handle
    if not handle then return false end

    local ok = pcall(function()
      handle:seek("end")
      handle:write(command .. "\n")
      handle:flush()
    end)
    if not ok then
      self:close_worker_command_file()
      return false
    end
    return true
  end

  function thumbnail_service:write_socket_command(pos, mode)
    local socket = state.worker_socket
    if not socket or not utils.file_info(socket) then return false end
    local json = utils.format_json({
      command = {"seek", pos, mode},
      async = true
    })
    mp.command_native_async({
      name = "subprocess",
      playback_only = false,
      capture_stdout = true,
      capture_stderr = true,
      stdin_data = json .. "\n",
      args = {"socat", "-", "UNIX-CONNECT:" .. socket}
    }, function() end)
    return true
  end

  function thumbnail_service:seek(pos, exact)
    if not state.worker_id then return false end
    local mode = exact and "absolute+exact" or "absolute+keyframes"
    local command = string.format("async seek %.6f %s", pos, mode)
    if self:write_direct_command(command) then return true end
    return self:write_socket_command(pos, mode)
  end

  function thumbnail_service:start_worker(source, pos, width, height)
    local thumbnail = state
    if thumbnail.worker_id and thumbnail.worker_source == source and
      thumbnail.worker_width == width and thumbnail.worker_height == height then
      return false
    end

    local keep_display = thumbnail.file ~= nil and
                 thumbnail.file_width == width and
                 thumbnail.file_height == height
    self:stop_worker(keep_display)
    if not keep_display then
      mp.commandv("overlay-remove", thumbnail.overlay_id)
      thumbnail.visible = false
      self:remove_display_file()
    end

    local pid = mp.get_property("pid", "0")
    local base = "/tmp/material-osc-thumbnail-" .. pid
    thumbnail.worker_socket = base .. ".sock"
    thumbnail.worker_command_file = base .. ".commands"
    thumbnail.worker_client_script = base .. ".run"
    thumbnail.worker_output = base .. ".work"
    thumbnail.worker_candidate = base .. ".candidate"
    thumbnail.worker_display = base .. ".bgra"
    thumbnail.worker_width = width
    thumbnail.worker_height = height
    thumbnail.worker_source = source

    os.remove(thumbnail.worker_socket)
    os.remove(thumbnail.worker_command_file)
    os.remove(thumbnail.worker_output)
    os.remove(thumbnail.worker_candidate)
    if not keep_display then os.remove(thumbnail.worker_display) end

    local use_direct_ipc = not thumbnail_is_windows
    if use_direct_ipc then
      local script = io.open(thumbnail.worker_client_script, "w")
      if script then
        script:write(string.format(thumbnail_client_script,
                     thumbnail.worker_command_file))
        script:close()
        local result = mp.command_native({
          name = "subprocess",
          playback_only = false,
          capture_stdout = true,
          capture_stderr = true,
          args = {"chmod", "+x", thumbnail.worker_client_script}
        })
        if not result or result.status ~= 0 then use_direct_ipc = false end
      else
        use_direct_ipc = false
      end
    end

    local filter = string.format(
      "scale=w=%d:h=%d:force_original_aspect_ratio=decrease," ..
      "pad=w=%d:h=%d:x=-1:y=-1,format=bgra", width, height, width, height)
    local args = {
      "mpv", "--no-config", "--msg-level=all=no", "--really-quiet",
      "--no-terminal", "--load-scripts=no", "--osc=no", "--ytdl=no",
      "--load-stats-overlay=no", "--load-osd-console=no",
      "--load-auto-profiles=no", "--idle=yes", "--pause=yes",
      "--keep-open=always", "--audio=no", "--sub=no",
      "--start=" .. tostring(pos), "--hr-seek=no",
      "--demuxer-readahead-secs=0", "--demuxer-max-bytes=128KiB",
      "--vd-lavc-skiploopfilter=all", "--vd-lavc-software-fallback=1",
      "--vd-lavc-fast", "--vd-lavc-threads=2", "--hwdec=no",
      "--sws-scaler=fast-bilinear", "--sws-allow-zimg=no",
      "--input-ipc-server=" .. thumbnail.worker_socket,
      "--vf=" .. filter, "--ovc=rawvideo", "--of=image2",
      "--ofopts=update=1", "--o=" .. thumbnail.worker_output
    }
    if use_direct_ipc then
      args[#args + 1] = "--scripts=" .. thumbnail.worker_client_script
    end
    args[#args + 1] = "--"
    args[#args + 1] = source

    local async_id
    async_id = mp.command_native_async({
      name = "subprocess",
      playback_only = false,
      args = args
    }, function()
      if thumbnail.worker_id == async_id then
        thumbnail.worker_id = nil
        thumbnail_service:close_worker_command_file()
      end
    end)
    thumbnail.worker_id = async_id

    thumbnail.poll_timer = mp.add_periodic_timer(thumbnail_poll_period, function()
      thumbnail_service:show_completed(thumbnail.worker_width,
                       thumbnail.worker_height)
    end)
    return true
  end

  function thumbnail_service:dispatch_pending()
    local thumbnail = state
    thumbnail.request_timer = nil
    local pos = thumbnail.pending_pos
    thumbnail.pending_pos = nil
    if pos == nil or thumbnail.request_pos == nil then return end

    local source = mp.get_property("path")
    if not source then return end
    local width = thumbnail.preview.width
    local height = thumbnail.preview.height
    local started = self:start_worker(source, pos, width, height)
    local sent = started or self:seek(pos, false)
    if sent then
      thumbnail.last_seek_at = mp.get_time()
    elseif thumbnail.request_pos ~= nil then
      -- The worker can exist before its IPC endpoint has been created. Retry
      -- briefly instead of dropping the first interactive seek.
      thumbnail.pending_pos = pos
      thumbnail.request_timer = mp.add_timeout(0.02, function()
        thumbnail_service:dispatch_pending()
      end)
    end
  end

  function thumbnail_service:schedule_exact(request_id, pos, attempts)
    local thumbnail = state
    attempts = attempts or 0
    if request_id ~= thumbnail.request_id or thumbnail.request_pos == nil or
      math.abs((thumbnail.request_pos or 0) - pos) > 0.001 then return end

    if self:seek(pos, true) then return end
    if attempts < 10 then
      thumbnail.exact_timer = mp.add_timeout(0.03, function()
        thumbnail.exact_timer = nil
        thumbnail_service:schedule_exact(request_id, pos, attempts + 1)
      end)
    end
  end

  function thumbnail_service:request(pos, x, y, width, height)
    local thumbnail = state
    thumbnail.request_id = thumbnail.request_id + 1
    local request_id = thumbnail.request_id
    thumbnail.request_pos = pos
    thumbnail.target_x = x
    thumbnail.target_y = y
    thumbnail.pending_pos = pos
    thumbnail.loading = true

    if thumbnail.file_width == width and thumbnail.file_height == height then
      if not thumbnail.visible then self:add_overlay(width, height) end
    elseif thumbnail.visible then
      mp.commandv("overlay-remove", thumbnail.overlay_id)
      thumbnail.visible = false
    end

    local now = mp.get_time()
    if not thumbnail.request_timer then
      local delay = math.max(0, thumbnail_seek_period -
                     (now - thumbnail.last_seek_at))
      if delay <= 0 then
        self:dispatch_pending()
      else
        thumbnail.request_timer = mp.add_timeout(delay, function()
          thumbnail_service:dispatch_pending()
        end)
      end
    end

    if thumbnail.exact_timer then thumbnail.exact_timer:kill() end
    thumbnail.exact_timer = mp.add_timeout(thumbnail_exact_delay, function()
      thumbnail.exact_timer = nil
      thumbnail_service:schedule_exact(request_id, pos, 0)
    end)
  end

  function thumbnail_service:dispose()
    self:clear()
    self:stop_worker(false)
  end

  function thumbnail_service:on_file_loaded()
    -- Always discard the previous file's worker and cached frame first.
    self:dispose()
    if not self:can_thumbnail_current_file() then return end

    local attempts = 0
    local function prewarm()
      state.prewarm_timer = nil
      if not thumbnail_service:can_thumbnail_current_file() then return end
      local params = mp.get_property_native("video-out-params") or {}
      local has_dimensions = tonumber(params.dw or params.w) and
                   tonumber(params.dh or params.h)
      if not has_dimensions and attempts < 10 then
        attempts = attempts + 1
        state.prewarm_timer = mp.add_timeout(0.05, prewarm)
        return
      end

      local width, height = thumbnail_service:desired_dimensions()
      state.preview.width = width
      state.preview.height = height
      thumbnail_service:start_worker(mp.get_property("path"),
                      mp.get_property_number("time-pos", 0) or 0,
                      width, height)
    end

    state.prewarm_timer = mp.add_timeout(0.05, prewarm)
  end

  function thumbnail_service:preview_dimensions(params)
    return thumbnail_preview_dimensions(params)
  end

  return thumbnail_service
end

local thumbnail = {}

function thumbnail.new(deps)
  local state = deps.thumbnail_state
  local viewport = deps.viewport
  local get_snapshot = deps.get_snapshot
  local dp = deps.dp
  local clamp = deps.clamp
  local format_time = deps.format_time
  local chapter_name_at = deps.chapter_name_at
  local enqueue_effect = deps.enqueue_effect
  local draw_box = deps.draw_box
  local draw_text = deps.draw_text
  local draw_loading_shape_morph = deps.draw_loading_shape_morph
  local text_intrinsic_width = deps.text_intrinsic_width
  local truncate_utf8_to_width = deps.truncate_utf8_to_width
  local thumbnail_service = thumbnail_worker.new(deps)

  local function draw_thumbnail_preview(ass, x1, seek_y, x2, pos)
    local duration = get_snapshot().duration or 0
    if not pos or duration <= 0 then return end

    local seek_w = x2 - x1
    if seek_w < dp(80) then return end

    local ratio = clamp(pos / duration, 0, 1)
    local center_x = x1 + seek_w * ratio
    local has_thumbnail = thumbnail_service:is_ready()
    if has_thumbnail then
      local params = get_snapshot().video_params or {}
      state.preview.width, state.preview.height =
        thumbnail_service:preview_dimensions(params)
    end

    local time_text = format_time(pos)
    local chapter_text = chapter_name_at(pos)
    local pill_text_size = 22
    local pill_vertical_padding = dp(4)
    local pill_horizontal_padding = dp(8)
    local thumb_w = has_thumbnail and state.preview.width or 0
    local thumb_h = has_thumbnail and state.preview.height or 0
    local pill_h = dp(pill_text_size) + pill_vertical_padding * 2
    local gap = dp(6)
    local pill_gap = dp(6)
    local bottom_gap = dp(18)
    local margin = dp(8)
    local frame_pad = dp(1)
    local time_pill_w = text_intrinsic_width(time_text, pill_text_size) +
                pill_horizontal_padding * 2

    local max_row_w = math.max(0, viewport.w - margin * 2)
    local chapter_pill_w = 0
    if chapter_text then
      local available_chapter_w = max_row_w - time_pill_w - pill_gap
      if available_chapter_w >= dp(64) then
        local max_chapter_w = math.min(dp(300), available_chapter_w)
        chapter_text = truncate_utf8_to_width(chapter_text,
          max_chapter_w - pill_horizontal_padding * 2, pill_text_size)
        chapter_pill_w = math.min(
          max_chapter_w,
          text_intrinsic_width(chapter_text, pill_text_size) +
          pill_horizontal_padding * 2)
      else
        chapter_text = nil
      end
    end

    local row_w = time_pill_w
    if chapter_text then row_w = row_w + pill_gap + chapter_pill_w end

    local thumb_x1 = 0
    local thumb_y1 = 0
    local thumb_x2 = 0
    local thumb_y2 = 0
    if has_thumbnail then
      thumb_x1 = clamp(center_x - thumb_w / 2, margin, viewport.w - margin - thumb_w)
      thumb_y1 = math.max(margin,
                    seek_y - bottom_gap - pill_h - gap - thumb_h - frame_pad * 2)
      thumb_x2 = thumb_x1 + thumb_w
      thumb_y2 = thumb_y1 + thumb_h
    end

    local row_center_x = has_thumbnail and (thumb_x1 + thumb_x2) / 2 or center_x
    local row_x1 = clamp(row_center_x - row_w / 2, margin,
               viewport.w - margin - row_w)
    local pill_y1 = has_thumbnail and (thumb_y2 + frame_pad + gap) or
                math.max(margin, seek_y - bottom_gap - pill_h)
    local pill_y2 = pill_y1 + pill_h

    local time_x1 = row_x1
    local time_x2 = time_x1 + time_pill_w
    local chapter_x1 = time_x2 + pill_gap
    local chapter_x2 = chapter_x1 + chapter_pill_w

    if has_thumbnail then
      draw_box(ass, thumb_x1 - frame_pad, thumb_y1 - frame_pad,
           thumb_x2 + frame_pad, thumb_y2 + frame_pad, 0, "#050708",
           "20")
      local overlay_x = math.floor(thumb_x1 + 0.5)
      local overlay_y = math.floor(thumb_y1 + 0.5)
      state.target_x = overlay_x
      state.target_y = overlay_y
      if state.visible and state.file and
        (state.display_x ~= overlay_x or state.display_y ~= overlay_y) then
        enqueue_effect("thumbnail-overlay-position", function()
          mp.command_native_async({"overlay-add", state.overlay_id,
                       overlay_x, overlay_y, state.file, 0, "bgra",
                       thumb_w, thumb_h, thumb_w * 4}, function() end)
          state.display_x = overlay_x
          state.display_y = overlay_y
        end)
      end
      if not state.request_pos or math.abs(pos - state.request_pos) > 0.05 then
        enqueue_effect("thumbnail-request", function()
          thumbnail_service:request(pos, overlay_x, overlay_y, thumb_w, thumb_h)
        end)
      end
      if state.loading and not state.visible then
        local loading_size = math.min(dp(48), thumb_w * 0.32, thumb_h * 0.45)
        draw_loading_shape_morph(ass, (thumb_x1 + thumb_x2) / 2,
                     (thumb_y1 + thumb_y2) / 2, loading_size)
      end
    else
      state.request_pos = nil
      state.loading = false
      enqueue_effect("thumbnail-clear", function() thumbnail_service:clear() end)
    end

    draw_box(ass, time_x1, pill_y1, time_x2, pill_y2, pill_h / 2,
         "#050708", "78")
    draw_text(ass, (time_x1 + time_x2) / 2, (pill_y1 + pill_y2) / 2,
          time_text, pill_text_size, "#FFFFFF")

    if chapter_text then
      draw_box(ass, chapter_x1, pill_y1, chapter_x2, pill_y2, pill_h / 2,
           "#050708", "78")
      draw_text(ass, (chapter_x1 + chapter_x2) / 2,
            (pill_y1 + pill_y2) / 2, chapter_text, pill_text_size,
            "#FFFFFF")
    end
  end


  return thumbnail_service, draw_thumbnail_preview
end

return thumbnail
