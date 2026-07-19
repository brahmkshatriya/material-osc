local thumbnail = {}

function thumbnail.new(deps)
  local state = deps.thumbnail_state
  local viewport = deps.viewport
  local get_snapshot = deps.get_snapshot
  local utils = deps.utils
  local msg = deps.msg
  local dp = deps.dp
  local clamp = deps.clamp
  local format_time = deps.format_time
  local chapter_name_at = deps.chapter_name_at
  local enqueue_effect = deps.enqueue_effect
  local render = deps.render
  local draw_box = deps.draw_box
  local draw_text = deps.draw_text
  local text_intrinsic_width = deps.text_intrinsic_width
  local truncate_utf8_to_width = deps.truncate_utf8_to_width
  local thumbnail_service = {}

  function thumbnail_service:is_ready()
    local snapshot = get_snapshot()
    return state.available and not state.disabled and
      state.width > 0 and state.height > 0 and
      snapshot.video_present == true
  end

  function thumbnail_service:request(pos, x, y)
    if not self:is_ready() then return end
    state.visible = true
    mp.commandv("script-message-to", "thumbfast", "thumb", pos, x, y)
  end

  function thumbnail_service:clear()
    if not state.visible then return end
    state.visible = false
    if state.available then
      mp.commandv("script-message-to", "thumbfast", "clear")
    end
  end

  mp.register_script_message("thumbfast-info", function(json)
    local data = utils.parse_json(json)
    if type(data) ~= "table" or
      type(data.width) ~= "number" or type(data.height) ~= "number" then
      msg.error("thumbfast-info: invalid thumbnail information")
      return
    end

    state.width = data.width
    state.height = data.height
    state.disabled = data.disabled ~= false
    state.available = data.available == true
    render()
  end)

  local function draw_thumbnail_preview(ass, x1, seek_y, x2, pos)
    local duration = get_snapshot().duration or 0
    if not pos or duration <= 0 then return end

    local seek_w = x2 - x1
    if seek_w < dp(80) then return end

    local ratio = clamp(pos / duration, 0, 1)
    local center_x = x1 + seek_w * ratio
    local has_thumbnail = thumbnail_service:is_ready()
    local time_text = format_time(pos)
    local chapter_text = chapter_name_at(pos)
    local pill_text_size = 22
    local pill_vertical_padding = dp(4)
    local pill_horizontal_padding = dp(8)
    local pill_background_alpha = "48"
    local thumb_w = has_thumbnail and state.width or 0
    local thumb_h = has_thumbnail and state.height or 0
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

    local thumb_x1, thumb_y1, thumb_x2, thumb_y2 = 0, 0, 0, 0
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
           thumb_x2 + frame_pad, thumb_y2 + frame_pad, 0, "#050708", "20")
      local overlay_x = math.floor(thumb_x1 + 0.5)
      local overlay_y = math.floor(thumb_y1 + 0.5)
      enqueue_effect("thumbnail-request", function()
        thumbnail_service:request(pos, overlay_x, overlay_y)
      end)
    else
      enqueue_effect("thumbnail-clear", function() thumbnail_service:clear() end)
    end

    draw_box(ass, time_x1, pill_y1, time_x2, pill_y2, pill_h / 2,
         "#050708", pill_background_alpha)
    draw_text(ass, (time_x1 + time_x2) / 2, (pill_y1 + pill_y2) / 2,
          time_text, pill_text_size, "#FFFFFF")

    if chapter_text then
      draw_box(ass, chapter_x1, pill_y1, chapter_x2, pill_y2, pill_h / 2,
           "#050708", pill_background_alpha)
      draw_text(ass, (chapter_x1 + chapter_x2) / 2,
            (pill_y1 + pill_y2) / 2, chapter_text, pill_text_size,
            "#FFFFFF")
    end
  end

  return thumbnail_service, draw_thumbnail_preview
end

return thumbnail
