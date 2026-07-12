local seekbar_renderer = {}

function seekbar_renderer.new(deps)
  local runtime, opts = deps.runtime, deps.opts
  local dp, clamp, mouse_in = deps.dp, deps.clamp, deps.mouse_in
  local draw_rect, draw_box = deps.draw_rect, deps.draw_box
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
  
    local function draw_track_segment(from_x, to_x, color, alpha)
      from_x = clamp(from_x, x1, x2)
      to_x = clamp(to_x, x1, x2)
      if to_x <= from_x then return end
      local cursor = from_x
      for _, gap in ipairs(track_gaps) do
        if gap.x2 > cursor and gap.x1 < to_x then
          if gap.x1 > cursor then
            draw_rect(ass, cursor, seek_y, math.min(gap.x1, to_x),
              seek_y + seek_h, color, alpha)
          end
          cursor = math.max(cursor, gap.x2)
          if cursor >= to_x then break end
        end
      end
      if cursor < to_x then
        draw_rect(ass, cursor, seek_y, to_x, seek_y + seek_h, color, alpha)
      end
    end
  
    draw_track_segment(x1, x2, "#282828", "99")
  
    if runtime.snapshot.network then
      local cache_state = runtime.snapshot.cache_state or {}
      local ranges = cache_state["seekable-ranges"] or {}
      for _, range in ipairs(ranges) do
        local range_start = clamp((range["start"] or 0) / duration, 0, 1)
        local range_end = clamp((range["end"] or 0) / duration, 0, 1)
        if range_end > range_start then
          draw_track_segment(x1 + seek_w * range_start,
                     x1 + seek_w * range_end, "#b1b1b1", "66")
        end
      end
    end
  
    draw_track_segment(x1, handle_x, opts.accent_color, "00")
  
    local preview_area = {
      x1 = x1,
      y1 = seek_y - dp(6),
      x2 = x2,
      y2 = seek_y + seek_h + dp(6)
    }
    local hovering_seek = mouse_in(preview_area)
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
