local player = {}

function player.new(args)
  local runtime, mp = args.runtime, args.mp
  local service = {}

  function service:format_time(seconds)
    seconds = math.max(0, seconds or 0)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(seconds / 60) % 60
    local secs = math.floor(seconds % 60)
    if hours > 0 then return string.format("%d:%02d:%02d", hours, minutes, secs) end
    return string.format("%d:%02d", minutes, secs)
  end

  function service:chapter_at(position)
    if not position then return nil end
    local selected, selected_time = nil, -math.huge
    for _, chapter in ipairs(runtime.snapshot.chapters or {}) do
      local chapter_time = tonumber(chapter.time)
      if chapter_time and chapter_time <= position and chapter_time >= selected_time then
        selected, selected_time = chapter, chapter_time
      end
    end
    local title = selected and selected.title
    if type(title) ~= "string" or title:match("^%s*$") then return nil end
    return title
  end

  function service:seek_position(box)
    local duration = runtime.snapshot.duration or 0
    if duration <= 0 then return nil end
    local pointer_x = runtime.pointer.x +
      (runtime.seek.dragging and runtime.seek.offset_x or 0)
    return args.clamp((pointer_x - box.x1) / (box.x2 - box.x1), 0, 1) * duration
  end

  function service:seek(position)
    if position then mp.commandv("seek", position, "absolute+exact") end
  end

  function service:preview_seek(box)
    local position = self:seek_position(box)
    if not position then return end
    runtime.seek.position = position
    args.render()
  end

  function service:is_buffering()
    if runtime.loading.quality_switching then return true end
    local properties = runtime.properties
    if properties and properties.seeking then return true end
    if properties and properties["paused-for-cache"] then return true end
    local state
    if properties then
      state = tonumber(properties["cache-buffering-state"])
    else
      state = mp.get_property_number("cache-buffering-state")
    end
    return state ~= nil and state > 0 and state < 100
  end

  return service
end

return player
