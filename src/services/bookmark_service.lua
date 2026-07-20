local bookmarks = {}
local input = require "mp.input"

function bookmarks.new(args)
  local mp, utils = args.mp, args.utils
  local service = {data = {}, current_key = nil, base_chapters = {}}
  local database_path = mp.command_native({"expand-path",
    "~~home/material-osc-bookmarks.json"})

  local function read_database()
    if not database_path or database_path == "" then return {} end
    local file = io.open(database_path, "rb")
    if not file then return {} end
    local contents = file:read("*a")
    file:close()
    local parsed = utils.parse_json(contents or "")
    return type(parsed) == "table" and parsed or {}
  end

  local function write_database(data)
    if not database_path or database_path == "" then return false end
    local encoded = utils.format_json(data)
    if not encoded then return false end
    local file = io.open(database_path, "wb")
    if not file then return false end
    file:write(encoded, "\n")
    file:close()
    return true
  end

  local function normalize_numbers(data)
    for _, entries in pairs(data) do
      if type(entries) == "table" then
        for index, entry in ipairs(entries) do
          if type(entry) == "table" and not tonumber(entry.number) then
            entry.number = tonumber(tostring(entry.title or ""):match(
              "^Bookmark (%d+)$")) or index
          end
        end
      end
    end
  end

  local function media_key()
    local path = mp.get_property("path", "") or ""
    if path == "" then return nil end
    return mp.command_native({"normalize-path", path}) or path
  end

  function service:apply()
    if not self.current_key then return end
    local chapters = {}
    for _, chapter in ipairs(self.base_chapters or {}) do
      chapters[#chapters + 1] = chapter
    end
    for _, bookmark in ipairs(self.data[self.current_key] or {}) do
      chapters[#chapters + 1] = {
        time = tonumber(bookmark.time) or 0,
        title = bookmark.title or ("Bookmark " .. args.format_time(bookmark.time or 0))
      }
    end
    table.sort(chapters, function(a, b)
      return (tonumber(a.time) or 0) < (tonumber(b.time) or 0)
    end)
    mp.set_property_native("chapter-list", chapters)
  end

  function service:restore()
    self.current_key = media_key()
    self.base_chapters = {}
    for _, chapter in ipairs(mp.get_property_native("chapter-list") or {}) do
      if not self:is_bookmark(chapter) then
        self.base_chapters[#self.base_chapters + 1] = chapter
      end
    end
    self:apply()
  end

  function service:add()
    local key = media_key()
    if not key then return false end
    if key ~= self.current_key then self:restore() end
    local position = mp.get_property_number("time-pos", 0) or 0
    local previous_entries = self.data[key] or {}
    local entries = {}
    for _, entry in ipairs(previous_entries) do entries[#entries + 1] = entry end
    for _, entry in ipairs(entries) do
      if math.abs((tonumber(entry.time) or 0) - position) < 0.5 then
        mp.osd_message("Bookmark already exists", 2)
        return false
      end
    end
    local bookmark_number = 0
    for index, entry in ipairs(entries) do
      local number = tonumber(entry.number) or
        tonumber(tostring(entry.title or ""):match("^Bookmark (%d+)$")) or
        index
      entry.number = number
      bookmark_number = math.max(bookmark_number, number)
    end
    bookmark_number = bookmark_number + 1
    entries[#entries + 1] = {
      time = position,
      number = bookmark_number,
      title = "Bookmark " .. tostring(bookmark_number)
    }
    table.sort(entries, function(a, b)
      return (tonumber(a.time) or 0) < (tonumber(b.time) or 0)
    end)
    self.data[key] = entries
    if not write_database(self.data) then
      self.data[key] = previous_entries
      mp.osd_message("Could not save bookmark", 2)
      return false
    end
    self:apply()
    mp.osd_message("Bookmark added at " .. args.format_time(position), 2)
    args.render()
    return true
  end

  function service:is_bookmark(chapter)
    if not chapter or not self.current_key then return false end
    local chapter_time = tonumber(chapter.time)
    if not chapter_time then return false end
    for _, entry in ipairs(self.data[self.current_key] or {}) do
      if math.abs((tonumber(entry.time) or 0) - chapter_time) < 0.001 and
        entry.title == chapter.title then
        return true
      end
    end
    return false
  end

  function service:remove(chapter)
    local key = media_key()
    if not key or not chapter then return false end
    if key ~= self.current_key then self:restore() end
    local previous_entries = self.data[key] or {}
    local chapter_time = tonumber(chapter.time)
    if not chapter_time then return false end
    local entries, removed = {}, false
    for _, entry in ipairs(previous_entries) do
      local matches = not removed and
        math.abs((tonumber(entry.time) or 0) - chapter_time) < 0.001 and
        entry.title == chapter.title
      if matches then
        removed = true
      else
        entries[#entries + 1] = entry
      end
    end
    if not removed then return false end
    self.data[key] = #entries > 0 and entries or nil
    if not write_database(self.data) then
      self.data[key] = previous_entries
      mp.osd_message("Could not remove bookmark", 2)
      return false
    end
    self:apply()
    mp.osd_message("Bookmark removed", 2)
    args.render()
    return true
  end

  function service:rename(chapter, title)
    if not chapter or not self.current_key then return false end
    title = tostring(title or ""):match("^%s*(.-)%s*$")
    if title == "" then
      mp.osd_message("Bookmark name cannot be empty", 2)
      return false
    end
    local entries = self.data[self.current_key] or {}
    local chapter_time = tonumber(chapter.time)
    if not chapter_time then return false end
    local entry
    for _, candidate in ipairs(entries) do
      if math.abs((tonumber(candidate.time) or 0) - chapter_time) < 0.001 and
        candidate.title == chapter.title then
        entry = candidate
        break
      end
    end
    if not entry then return false end
    local previous_title = entry.title
    entry.title = title
    if not write_database(self.data) then
      entry.title = previous_title
      mp.osd_message("Could not rename bookmark", 2)
      return false
    end
    self:apply()
    mp.osd_message("Bookmark renamed", 2)
    args.render()
    return true
  end

  function service:prompt_rename(chapter)
    if not self:is_bookmark(chapter) then return end
    input.get({
      prompt = "Bookmark name:",
      default_text = chapter.title or "",
      submit = function(title) self:rename(chapter, title) end,
      opened = function() args.set_input_active(true) end,
      closed = function() args.set_input_active(false) end
    })
  end

  service.data = read_database()
  normalize_numbers(service.data)
  return service
end

return bookmarks
