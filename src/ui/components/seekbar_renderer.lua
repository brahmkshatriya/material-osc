local seekbar_renderer = {}

function seekbar_renderer.new(deps)
  local runtime, opts = deps.runtime, deps.opts
  local dp, clamp, mouse_in = deps.dp, deps.clamp, deps.mouse_in
  local draw_rect, draw_box, draw_boxes =
    deps.draw_rect, deps.draw_box, deps.draw_boxes
  local seek_pos_from_mouse = deps.seek_pos_from_mouse
  local draw_thumbnail_preview = deps.draw_thumbnail_preview
  local enqueue_effect, thumbnail_service = deps.enqueue_effect, deps.thumbnail_service

  local function draw_seekbar(ass, x1, y, x2)
    local duration = runtime.snapshot.duration or 0
    local pos = runtime.seek.dragging and runtime.seek.position or
            (runtime.snapshot.position or 0)
    local seek_h = dp(4)
    local seek_y = y - seek_h / 2
    local seek_w = x2 - x1
  
    if seek_w < dp(80) then return end
  
    if duration <= 0 then
      draw_rect(ass, x1, seek_y, x2, seek_y + seek_h, "#282828", "99")
      return
    end
  
    local ratio = clamp(pos / duration, 0, 1)
    local handle_x = x1 + seek_w * ratio
    local handle_w = runtime.seek.dragging and dp(2) or seek_h
    local handle_gap = dp(4)
    local gap_left = handle_x - handle_w / 2 - handle_gap
    local gap_right = handle_x + handle_w / 2 + handle_gap
  
    local track_gaps = {{x1 = gap_left, x2 = gap_right}}
    local chapters = runtime.snapshot.chapters or {}
    local chapter_gap_half = dp(1)
    for _, chapter in ipairs(chapters) do
      local chapter_time = chapter.time
      if chapter_time and chapter_time > 0 and chapter_time < duration then
        local cx = x1 + seek_w * clamp(chapter_time / duration, 0, 1)
        track_gaps[#track_gaps + 1] = {
          x1 = cx - chapter_gap_half,
          x2 = cx + chapter_gap_half
        }
      end
    end
    table.sort(track_gaps, function(a, b) return a.x1 < b.x1 end)
  
    local function track_segments(from_x, to_x)
      local segments = {}
      from_x = clamp(from_x, x1, x2)
      to_x = clamp(to_x, x1, x2)
      if to_x <= from_x then return segments end
      local cursor = from_x
      for _, gap in ipairs(track_gaps) do
        if gap.x2 > cursor and gap.x1 < to_x then
          if gap.x1 > cursor then
            segments[#segments + 1] = {
              x1 = cursor, y1 = seek_y, x2 = math.min(gap.x1, to_x),
              y2 = seek_y + seek_h, radius = seek_h / 2
            }
          end
          cursor = math.max(cursor, gap.x2)
          if cursor >= to_x then break end
        end
      end
      if cursor < to_x then
        segments[#segments + 1] = {
          x1 = cursor, y1 = seek_y, x2 = to_x,
          y2 = seek_y + seek_h, radius = seek_h / 2
        }
      end
      return segments
    end

    draw_boxes(ass, track_segments(x1, x2), "#282828", "99")
  
    if runtime.snapshot.network then
      local cache_state = runtime.snapshot.cache_state or {}
      local ranges = cache_state["seekable-ranges"] or {}
      local cache_segments = {}
      for _, range in ipairs(ranges) do
        local range_start = clamp((range["start"] or 0) / duration, 0, 1)
        local range_end = clamp((range["end"] or 0) / duration, 0, 1)
        if range_end > range_start then
          for _, segment in ipairs(track_segments(
              x1 + seek_w * range_start, x1 + seek_w * range_end)) do
            cache_segments[#cache_segments + 1] = segment
          end
        end
      end
      draw_boxes(ass, cache_segments, "#b1b1b1", "66")
    end
  
    draw_boxes(ass, track_segments(x1, handle_x), opts.accent_color, "00")

    local loop_a = tonumber(runtime.snapshot.ab_loop_a)
    local loop_b = tonumber(runtime.snapshot.ab_loop_b)
    if loop_a then
      local loop_a_x = x1 + seek_w * clamp(loop_a / duration, 0, 1)
      local loop_x1, loop_x2
      if loop_b then
        local loop_b_x = x1 + seek_w * clamp(loop_b / duration, 0, 1)
        loop_x1 = math.min(loop_a_x, loop_b_x)
        loop_x2 = math.max(loop_a_x, loop_b_x)
      else
        local minimum_w = dp(4)
        loop_x1 = clamp(loop_a_x - minimum_w / 2, x1, x2 - minimum_w)
        loop_x2 = loop_x1 + minimum_w
      end
      local loop_h = dp(10)
      local loop_y = seek_y + seek_h / 2
      local loop_radius = math.min(dp(2), (loop_x2 - loop_x1) / 2)
      local loop_color = loop_b and opts.accent_color or "#000000"
      local loop_alpha = loop_b and "70" or "00"
      draw_box(ass, loop_x1, loop_y - loop_h / 2,
        loop_x2, loop_y + loop_h / 2, loop_radius,
        loop_color, loop_alpha)
    end

    local preview_area = {
      x1 = x1,
      y1 = seek_y - dp(6),
      x2 = x2,
      y2 = seek_y + seek_h + dp(6)
    }
    local hovering_seek = runtime.controller.visible and mouse_in(preview_area)
    local handle_h = dp(hovering_seek and 24 or 22)
    local handle_y = seek_y + seek_h / 2
    draw_box(ass, handle_x - handle_w / 2, handle_y - handle_h / 2,
         handle_x + handle_w / 2, handle_y + handle_h / 2, handle_w / 2,
         opts.accent_color, "00")
  
    if runtime.seek.dragging or hovering_seek then
      local preview_pos = runtime.seek.dragging and runtime.seek.position or seek_pos_from_mouse(preview_area)
      draw_thumbnail_preview(ass, x1, seek_y, x2, preview_pos)
    else
      enqueue_effect("thumbnail-clear", function() thumbnail_service:clear() end)
    end
  end

  return draw_seekbar
end

return seekbar_renderer
