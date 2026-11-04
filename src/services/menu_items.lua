-- Turns the menu tree from menu_builder into the rows the context menu draws,
-- one submenu level at a time.
local menu_items = {}

function menu_items.new(args)
  local builder = args.builder
  local service = {}

  local function has_state(entry, name)
    for _, value in ipairs(entry.state or {}) do
      if value == name then return true end
    end
    return false
  end

  -- a tab separates the title from its shortcut
  local function split_title(title)
    title = tostring(title or "")
    local label, shortcut = title:match("^(.-)\t(.*)$")
    return label or title, shortcut
  end

  function service:available()
    local items = builder:tree()
    return type(items) == "table" and #items > 0
  end

  -- Returns the entries at path (a list of submenu indexes) converted to
  -- plain tables, plus the titles of the submenus along the path.
  function service:level(path)
    local entries = builder:tree()
    if type(entries) ~= "table" then return nil end
    local titles = {}
    for _, index in ipairs(path or {}) do
      local entry = entries[index]
      if type(entry) ~= "table" or type(entry.submenu) ~= "table" then
        return nil
      end
      titles[#titles + 1] = (split_title(entry.title))
      entries = entry.submenu
    end

    local items = {}
    for index, entry in ipairs(entries) do
      if type(entry) == "table" and not has_state(entry, "hidden") then
        if entry.type == "separator" then
          -- drop leading and repeated separators
          if #items > 0 and not items[#items].separator then
            items[#items + 1] = {separator = true}
          end
        else
          local label, shortcut = split_title(entry.title)
          local is_submenu = entry.type == "submenu"
          items[#items + 1] = {
            label = label,
            shortcut = shortcut,
            command = entry.cmd,
            submenu_index = is_submenu and index or nil,
            checked = has_state(entry, "checked"),
            disabled = has_state(entry, "disabled") or
              (is_submenu and (type(entry.submenu) ~= "table" or
                #entry.submenu == 0))
          }
        end
      end
    end
    if #items > 0 and items[#items].separator then items[#items] = nil end
    return items, titles
  end

  return service
end

return menu_items
