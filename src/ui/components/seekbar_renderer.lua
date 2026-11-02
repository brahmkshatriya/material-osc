local seekbar_renderer = {}

function seekbar_renderer.new(deps)
  local runtime, opts = deps.runtime, deps.opts
  local dp, clamp, mouse_in = deps.dp, deps.clamp, deps.mouse_in
  local draw_rect, draw_box, draw_boxes =
    deps.draw_rect, deps.draw_box, deps.draw_boxes
  local seek_pos_from_mouse = deps.seek_pos_from_mouse
  local draw_thumbnail_preview = deps.draw_thumbnail_preview
  local enqueue_effect, thumbnail_service = deps.enqueue_effect, deps.thumbnail_service
  local sponsorblock_category_style = deps.sponsorblock_category_style
  local sponsorblock_should_render = deps.sponsorblock_should_render
  local precise_seek, precise_strip = deps.precise_seek, deps.precise_strip
  local draw_text, draw_icon = deps.draw_text, deps.draw_icon
  local text_width = deps.text_width

  local function format_precise(seconds)
    seconds = math.max(0, seconds or 0)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(seconds / 60) % 60
    local secs = math.floor(seconds % 60)
    if hours > 0 then
      return string.format("%d:%02d:%02d", hours, minutes, secs)
    end
    return string.format("%d:%02d", minutes, secs)
  end

  -- Precise seeking: the time above the seekbar, a close button and a
  -- filmstrip below it in place of the control row. The time pill matches the
  -- seek preview's, the close button the media information one.
  local function draw_precise(ass, x1, x2, seek_y, duration)
    local precise = runtime.seek.precise
    local position = precise_seek:position()
    local seconds_per_px = precise_seek:seconds_per_pixel()
    if seconds_per_px <= 0 then return end
    local center_x = (x1 + x2) / 2
    precise.strip_center = center_x

    local text_size = 22
    local time_text = format_precise(position)
    local pill_h = dp(text_size) + dp(4) * 2
    local pill_w = text_width(time_text, text_size) + dp(12) * 2
    local pill_y2 = seek_y - dp(12)
    local pill_x1 = center_x - pill_w / 2
    draw_box(ass, pill_x1, pill_y2 - pill_h, pill_x1 + pill_w, pill_y2,
      pill_h / 2, "#050708", "33")
    draw_text(ass, center_x, pill_y2 - pill_h / 2, time_text, text_size,
      "#FFFFFF")

    -- close button: finishes precise seeking at the current position
    local close = {x1 = x2 - pill_h, y1 = pill_y2 - pill_h, x2 = x2, y2 = pill_y2}
    precise.close_bounds = close
    draw_box(ass, close.x1, close.y1, close.x2, close.y2, pill_h / 2,
      "#050708", "14")
    if mouse_in(close) then
      draw_box(ass, close.x1, close.y1, close.x2, close.y2, pill_h / 2,
        "#FFFFFF", "D6")
    end
    draw_icon(ass, (close.x1 + close.x2) / 2, (close.y1 + close.y2) / 2,
      "close", "#FFFFFF", 20, "00")

    -- filmstrip, framed like the seek preview thumbnail
    local area = precise.strip_bounds
    if not area then return end
    local strip = {x1 = x1, x2 = x2, y1 = area.y + dp(10), y2 = area.y2 - dp(2)}
    precise.strip_area = strip
    local strip_h = math.floor(strip.y2 - strip.y1)
    draw_box(ass, strip.x1, strip.y1, strip.x2, strip.y2, 0, "#050708", "20")
    if not precise_strip or runtime.snapshot.network or
      not precise_strip:available() then
      draw_text(ass, center_x, (strip.y1 + strip.y2) / 2,
        "Filmstrip is available for local files", 15, "#CAC4D0")
      draw_box(ass, center_x - dp(1), strip.y1 - dp(4), center_x + dp(1),
        strip.y2 + dp(4), 0, "#FFFFFF", "00")
      return
    end
    local tile_w = math.max(math.floor(strip_h * precise_strip:aspect() + 0.5),
      math.ceil((strip.x2 - strip.x1) / 13))
    local tiles = precise_strip:update({
      x1 = strip.x1, x2 = strip.x2, y1 = strip.y1, y2 = strip.y2,
      center_x = center_x, position = position, duration = duration,
      seconds_per_px = seconds_per_px, tile_w = tile_w, tile_h = strip_h
    })
    -- placeholders for tiles that are still being generated
    for _, tile in ipairs(tiles) do
      if not tile.ready then
        local tx1 = math.max(tile.x1, strip.x1)
        local tx2 = math.min(tile.x2, strip.x2)
        if tx2 > tx1 then
          draw_box(ass, tx1, strip.y1, tx2, strip.y2, 0, "#282828", "99")
        end
      end
    end
  end

  local function draw_seekbar(ass, x1, y, x2)
    runtime.seek.preview_bounds = nil
    runtime.seek.position_pill_visible = false
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

    local sponsorblock = runtime.sponsorblock or {}
    for _, segment in ipairs(sponsorblock.segments or {}) do
      local start_time = tonumber(segment.start_time)
      local end_time = tonumber(segment.end_time)
      local should_render = not sponsorblock_should_render or
        sponsorblock_should_render(segment.category)
      if should_render and start_time and end_time and
        end_time > start_time then
        local segment_x1 =
          x1 + seek_w * clamp(start_time / duration, 0, 1)
        local segment_x2 =
          x1 + seek_w * clamp(end_time / duration, 0, 1)
        local style = sponsorblock_category_style(segment.category)
        local segment_color = opts.sponsorblock_multicolored_segments and
          style.color or "#ffff00"
        draw_boxes(ass, track_segments(segment_x1, segment_x2),
          segment_color, style.alpha)
      end
    end

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
    runtime.seek.preview_bounds = preview_area
    local hovering_seek = runtime.controller.visible and mouse_in(preview_area)
    runtime.seek.position_pill_visible =
      runtime.seek.dragging or hovering_seek
    local handle_h = dp(hovering_seek and 24 or 22)
    local handle_y = seek_y + seek_h / 2
    draw_box(ass, handle_x - handle_w / 2, handle_y - handle_h / 2,
         handle_x + handle_w / 2, handle_y + handle_h / 2, handle_w / 2,
         opts.accent_color, "00")
  
    local precise_active = precise_seek and precise_seek:active()
    if precise_active then
      draw_precise(ass, x1, x2, seek_y, duration)
      enqueue_effect("thumbnail-clear", function() thumbnail_service:clear() end)
    elseif runtime.seek.dragging or hovering_seek then
      local preview_pos = runtime.seek.dragging and runtime.seek.position or seek_pos_from_mouse(preview_area)
      draw_thumbnail_preview(ass, x1, seek_y, x2, preview_pos)
    else
      enqueue_effect("thumbnail-clear", function() thumbnail_service:clear() end)
    end
  end

  return draw_seekbar
end

return seekbar_renderer
