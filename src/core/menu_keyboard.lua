local menu_keyboard = {}

local DIALOGS = {"playlist", "chapter", "subtitle", "audio", "settings"}

local function center(box)
  return box.x1 + box.w / 2, box.y1 + box.h / 2
end

local function inside(inner, outer)
  local x, y = center(inner)
  return x >= outer.x1 and x <= outer.x2 and
    y >= outer.y1 and y <= outer.y2
end

local function is_chrome(name)
  return name:find("backdrop", 1, true) or
    name:find("panel", 1, true) or
    name:find("surface", 1, true) or
    name:find("scrollbar", 1, true) or
    name:find("-area", 1, true)
end

local function row_prefix(name)
  if not name:find("row", 1, true) then return nil end
  return name:match("^(.-)%d+$")
end

function menu_keyboard.new(args)
  local runtime = args.runtime
  local service = {}

  local function active_menu()
    if runtime.context_menu.open and runtime.context_menu.bounds then
      return "context_menu", runtime.context_menu
    end
    for _, name in ipairs(DIALOGS) do
      local state = runtime[name]
      if state.open and state.bounds then return name, state end
    end
    return nil, nil
  end

  local function candidates()
    local scope, state = active_menu()
    if not scope or not state.bounds then return scope, state, {} end
    local result = {}
    for _, name in ipairs(runtime.input.order) do
      local box = runtime.input.hitboxes[name]
      local keyboard_interactive = box and (box.keyboard_action or
        box.keyboard_left or box.keyboard_right or
        box.keyboard_up or box.keyboard_down)
      if box and box.enabled ~= false and box.keyboard_enabled ~= false and
        box.keyboard_generation == runtime.input.keyboard_generation and
        keyboard_interactive and
        inside(box, state.keyboard_bounds or state.bounds) and
        not is_chrome(name) then
        result[#result + 1] = box
      end
    end
    table.sort(result, function(a, b)
      local ax, ay = center(a)
      local bx, by = center(b)
      if math.abs(ay - by) > 1 then return ay < by end
      return ax < bx
    end)
    return scope, state, result
  end

  local function body_candidate(items, reverse)
    local first, last = reverse and #items or 1, reverse and 1 or #items
    local step = reverse and -1 or 1
    for index = first, last, step do
      local name = items[index].name
      if not name:find("close", 1, true) and
        not name:find("reset", 1, true) and
        not name:find("remove", 1, true) and
        not name:find("edit", 1, true) and
        not name:find("options", 1, true) then
        return items[index]
      end
    end
    return items[first]
  end

  local function set_focus(scope, box)
    runtime.input.keyboard_scope = scope
    runtime.input.keyboard_focus = box and box.name or nil
    if args.render then args.render() end
  end

  local function focused_box(items)
    local name = runtime.input.keyboard_focus
    for _, box in ipairs(items) do
      if box.name == name then return box end
    end
    return nil
  end

  local function item_count(scope)
    local snapshot = runtime.snapshot or {}
    if scope == "playlist" then return snapshot.playlist_count or 0 end
    if scope == "chapter" then return #(snapshot.chapters or {}) end
    if scope == "subtitle" then return #(snapshot.subtitle_items or {}) end
    if scope == "audio" then return #(snapshot.audio_items or {}) end
    if scope ~= "settings" then return 0 end
    local page = runtime.settings.page
    if page == "video" then return #(snapshot.video_items or {}) end
    if page == "audio" then return #(snapshot.audio_items or {}) end
    if page == "subtitles" or page == "secondary_subtitles" then
      return #(snapshot.subtitle_items or {})
    end
    if page == "auto_captions" then
      return #(runtime.ytdl.caption_items or {})
    end
    if page == "video_shaders" then return #(snapshot.shader_items or {}) end
    return 0
  end

  local function scroll_row_boundary(scope, state, items, current, direction)
    if direction ~= "up" and direction ~= "down" then return false end
    local prefix = row_prefix(current.name)
    if not prefix then return false end
    local group = {}
    for _, box in ipairs(items) do
      if row_prefix(box.name) == prefix then group[#group + 1] = box end
    end
    if #group == 0 then return false end
    table.sort(group, function(a, b)
      local _, ay = center(a)
      local _, by = center(b)
      return ay < by
    end)
    local at_edge = direction == "up" and current.name == group[1].name or
      direction == "down" and current.name == group[#group].name
    if not at_edge then return false end
    local maximum = math.max(0, item_count(scope) - #group)
    local next_index = math.max(0, math.min(maximum,
      (state.scroll_index or 0) + (direction == "up" and -1 or 1)))
    if next_index == (state.scroll_index or 0) then return false end
    state.scroll_index = next_index
    runtime.input.keyboard_scope = scope
    runtime.input.keyboard_focus = current.name
    if args.render then args.render() end
    return true
  end

  local function directional_candidate(items, current, direction)
    local cx, cy = center(current)
    local best, best_score
    for _, box in ipairs(items) do
      if box.name ~= current.name then
        local x, y = center(box)
        local dx, dy = x - cx, y - cy
        local primary, secondary
        if direction == "up" and dy < -1 then
          primary, secondary = -dy, math.abs(dx)
        elseif direction == "down" and dy > 1 then
          primary, secondary = dy, math.abs(dx)
        elseif direction == "left" and dx < -1 then
          primary, secondary = -dx, math.abs(dy)
        elseif direction == "right" and dx > 1 then
          primary, secondary = dx, math.abs(dy)
        end
        if primary then
          local score = primary + secondary * 2.5
          if not best_score or score < best_score then
            best, best_score = box, score
          end
        end
      end
    end
    return best
  end

  function service:reset(scope)
    if not scope or runtime.input.keyboard_scope == scope then
      runtime.input.keyboard_focus = nil
      runtime.input.keyboard_scope = nil
    end
  end

  function service:handle(action)
    local scope, state, items = candidates()
    if #items == 0 then return end
    if runtime.input.keyboard_scope ~= scope then self:reset() end
    local current = focused_box(items)

    if action == "activate" then
      current = current or body_candidate(items, false)
      if not current then return end
      runtime.input.keyboard_scope = scope
      runtime.input.keyboard_focus = current.name
      if current.keyboard_action then current.keyboard_action(current) end
      return
    end

    if action == "home" or action == "end" then
      set_focus(scope, body_candidate(items, action == "end"))
      return
    end

    if action == "next" or action == "previous" then
      if not current then
        set_focus(scope, body_candidate(items, action == "previous"))
        return
      end
      local index = 0
      for i, box in ipairs(items) do
        if current and box.name == current.name then index = i break end
      end
      local delta = action == "next" and 1 or -1
      index = ((index - 1 + delta) % #items) + 1
      set_focus(scope, items[index])
      return
    end

    if action == "page_up" or action == "page_down" then
      local delta = action == "page_up" and -5 or 5
      local maximum = math.max(0, item_count(scope) - 1)
      if maximum > 0 then
        state.scroll_index = math.max(0,
          math.min(maximum, (state.scroll_index or 0) + delta))
        if args.render then args.render() end
      end
      return
    end

    local direction = action
    if not current then
      set_focus(scope, body_candidate(items, direction == "up" or
        direction == "left"))
      return
    end
    local direction_action = current["keyboard_" .. direction]
    if direction_action then
      direction_action(current)
      if args.render then args.render() end
      return
    end
    if scroll_row_boundary(scope, state, items, current, direction) then return end
    set_focus(scope, directional_candidate(items, current, direction) or current)
  end

  return service
end

return menu_keyboard
