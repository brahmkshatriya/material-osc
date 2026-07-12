local text_metrics = {}

local UTF8_CHARACTER = "[%z\1-\127\194-\244][\128-\191]*"

local function codepoint(character)
  local b1, b2, b3, b4 = character:byte(1, 4)
  if not b1 then return 0 end
  if b1 < 0x80 then return b1 end
  if b1 < 0xE0 and b2 then return (b1 - 0xC0) * 0x40 + b2 - 0x80 end
  if b1 < 0xF0 and b2 and b3 then
    return (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + b3 - 0x80
  end
  if b2 and b3 and b4 then
    return (b1 - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000 +
      (b3 - 0x80) * 0x40 + b4 - 0x80
  end
  return 0
end

local function glyph_advance(character)
  if character == " " then return 0.25 end
  if character == "\t" then return 1.00 end
  if character:match("[ilIjtfr.,'`:;!|]") then return 0.25 end
  if character:match("[mwMW@%%&#]") then return 0.78 end
  if character:match("[ABCDEFGHJKLMNOPQRSTUVWXYZ]") then return 0.62 end
  if character:match("[abcdefghknopqsuvxyz]") then return 0.52 end
  if character:match("[0-9]") then return 0.55 end
  if character:match("[(){}%[%]<>]") then return 0.34 end
  if character:match("[-_~+=/*\\]") then return 0.46 end
  if #character == 1 then return 0.50 end

  local value = codepoint(character)
  if (value >= 0x1100 and value <= 0x11FF) or
    (value >= 0x2E80 and value <= 0xA4CF) or
    (value >= 0xAC00 and value <= 0xD7AF) or
    (value >= 0xF900 and value <= 0xFAFF) or
    (value >= 0x1F000 and value <= 0x1FAFF) then
    return 1.00
  end
  return 0.56
end

function text_metrics.new(args)
  local dp = args.dp
  local default_size = args.default_size or 24
  local cache, cache_size = {}, 0

  local metrics = {}

  function metrics.length(text)
    local count = 0
    for _ in tostring(text or ""):gmatch(UTF8_CHARACTER) do count = count + 1 end
    return count
  end

  function metrics.truncate(text, maximum)
    text = tostring(text or "")
    if maximum <= 0 then return "" end
    if metrics.length(text) <= maximum then return text end
    if maximum <= 3 then return text:sub(1, maximum) end

    local characters = {}
    for character in text:gmatch(UTF8_CHARACTER) do
      characters[#characters + 1] = character
      if #characters >= maximum - 3 then break end
    end
    return table.concat(characters) .. "..."
  end

  function metrics.width(text, size)
    text, size = tostring(text or ""), tonumber(size) or default_size
    local key = tostring(size) .. "\0" .. text
    if cache[key] then return dp(cache[key]) end

    local width_em = 0
    for character in text:gmatch(UTF8_CHARACTER) do
      width_em = width_em + glyph_advance(character)
    end
    local width = width_em * size * 0.72
    if cache_size >= 512 then cache, cache_size = {}, 0 end
    cache[key], cache_size = width, cache_size + 1
    return dp(width)
  end

  function metrics.truncate_to_width(text, maximum_width, size)
    text, size = tostring(text or ""), tonumber(size) or default_size
    if metrics.width(text, size) <= maximum_width then return text end
    local ellipsis = "..."
    local available = maximum_width - metrics.width(ellipsis, size)
    if available <= 0 then return ellipsis end

    local characters, width = {}, 0
    for character in text:gmatch(UTF8_CHARACTER) do
      local character_width = dp(glyph_advance(character) * size * 0.72)
      if width + character_width > available then break end
      characters[#characters + 1], width = character, width + character_width
    end
    return table.concat(characters) .. ellipsis
  end

  return metrics
end

return text_metrics
