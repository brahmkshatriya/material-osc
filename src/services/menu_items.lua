-- Turns the menu tree from menu_builder into the rows the context menu draws,
-- one submenu level at a time.
local menu_items = {}

function menu_items.new(args)
  local mp, msg = args.mp, args.msg
  local builder, actions = args.builder, args.actions
  local service = {}
  local warned, cached = {}, {}

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

  local function convert(entry, snapshot)
    local label, shortcut = split_title(entry.title)
    if entry.builtin then
      local builtin, known = actions:builtin(entry.builtin, snapshot)
      if not known and not warned[entry.builtin] then
        warned[entry.builtin] = true
        msg.warn("menu: unknown item @" .. entry.builtin)
      end
      return builtin and {
        label = label ~= "" and label or builtin.label,
        icon = entry.icon or builtin.icon,
        action = builtin.action
      }
    end
    local is_submenu = entry.type == "submenu"
    local command = entry.cmd
    return {
      label = label,
      icon = entry.icon,
      shortcut = shortcut or entry.shortcut,
      submenu = is_submenu,
      submenu_index = nil,
      checked = has_state(entry, "checked"),
      disabled = has_state(entry, "disabled") or
        (is_submenu and (type(entry.submenu) ~= "table" or #entry.submenu == 0)),
      action = not is_submenu and command and command ~= "" and
        function() mp.command(command) end or nil
    }
  end

  function service:reload()
    builder:reload()
  end

  -- Returns the rows at path (a list of submenu indexes), or nil when that
  -- submenu no longer exists. The last item of the root is always Customize.
  function service:level(path, snapshot)
    local entries = builder:tree()
    for _, index in ipairs(path) do
      local entry = entries[index]
      if type(entry) ~= "table" or type(entry.submenu) ~= "table" then
        return nil
      end
      entries = entry.submenu
    end

    -- long lists are only converted again when the menu changed
    local key = table.concat(path, "/")
    local saved = cached[key]
    if saved and saved.generation == builder.generation then return saved.items end

    local items, has_builtin = {}, false
    for index, entry in ipairs(entries) do
      if type(entry) == "table" and not has_state(entry, "hidden") then
        if entry.type == "separator" then
          -- drop leading and repeated separators
          if #items > 0 and not items[#items].separator then
            items[#items + 1] = {separator = true}
          end
        else
          has_builtin = has_builtin or entry.builtin ~= nil
          local item = convert(entry, snapshot)
          if item then
            if item.submenu then item.submenu_index = index end
            items[#items + 1] = item
          end
        end
      end
    end
    if #items > 0 and items[#items].separator then items[#items] = nil end
    if #path == 0 then
      items[#items + 1] = actions:builtin("customize", snapshot)
    elseif not has_builtin then
      cached[key] = {generation = builder.generation, items = items}
    end
    return items
  end

  return service
end

return menu_items
