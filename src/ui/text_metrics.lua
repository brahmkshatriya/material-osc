local text_metrics = {}

local UTF8_CHARACTER = "[%z\1-\127\194-\244][\128-\191]*"

-- These are the default-instance metrics from fonts/GoogleSansFlex.ttf.  libass
-- normalizes this font against the OS/2 Windows ascent + descent (2452 + 999),
-- rather than its 2000 unit em.  Keeping the source font units here avoids
-- rounding every glyph before a complete run has been measured.
local FONT_HEIGHT = 3451
local ASCII_ADVANCES = {
  -- U+0020-U+002F
  450, 656, 646, 1282, 1204, 1660, 1256, 360,
  656, 656, 854, 1116, 476, 675, 476, 600,
  -- U+0030-U+003F
  1290, 735, 1052, 1070, 1186, 1126, 1114, 991,
  1102, 1114, 476, 476, 1116, 1116, 1116, 956,
  -- U+0040-U+004F
  1768, 1340, 1211, 1472, 1406, 1102, 1062, 1578,
  1396, 490, 1060, 1252, 1018, 1732, 1416, 1648,
  -- U+0050-U+005F
  1152, 1648, 1172, 1101, 1076, 1306, 1262, 1888,
  1272, 1190, 1144, 761, 600, 761, 930, 1125,
  -- U+0060-U+006F
  900, 1070, 1204, 1085, 1204, 1126, 758, 1194,
  1122, 452, 452, 1010, 422, 1750, 1122, 1192,
  -- U+0070-U+007E
  1204, 1204, 750, 943, 730, 1122, 1028, 1554,
  973, 1026, 963, 788, 474, 788, 1116,
}

local LATIN1_ADVANCES = {
  -- U+00A0-U+00AF
  450, 656, 1171, 1044, 1221, 1144, 474, 1092,
  900, 1666, 963, 1100, 1116, 675, 1060, 900,
  -- U+00B0-U+00BF
  648, 1116, 684, 719, 900, 1260, 1228, 476,
  900, 501, 1090, 1100, 1564, 1630, 1747, 956,
  -- U+00C0-U+00CF
  1340, 1340, 1340, 1340, 1340, 1340, 1935, 1472,
  1102, 1102, 1102, 1102, 490, 490, 490, 490,
  -- U+00D0-U+00DF
  1406, 1416, 1648, 1648, 1648, 1648, 1648, 1116,
  1648, 1306, 1306, 1306, 1306, 1190, 1152, 1140,
  -- U+00E0-U+00EF
  1070, 1070, 1070, 1070, 1070, 1070, 1838, 1085,
  1126, 1126, 1126, 1126, 452, 452, 452, 452,
  -- U+00F0-U+00FF
  1156, 1122, 1192, 1192, 1192, 1192, 1192, 1116,
  1192, 1122, 1122, 1122, 1122, 1026, 1204, 1026,
}

-- Significant pairs from the font's GPOS `kern` feature.  Corrections smaller
-- than 40 font units are below one third of a pixel at the largest UI size and
-- are intentionally omitted.  Pairs involving the display-name punctuation
-- with the largest visible corrections are included separately below.  mpv's
-- generated ASS event track leaves kerning disabled, so these are only applied
-- when a caller explicitly measures a track that opted into ASS kerning.
local KERNING = {
  A = {C=-66, G=-66, O=-66, Q=-66, S=-43, T=-165, U=-48, V=-159,
    W=-114, Y=-190, c=-49, d=-49, e=-49, f=-86, g=-49, o=-49,
    q=-49, t=-94, v=-155, w=-123, y=-155},
  B = {V=-43, Y=-63},
  C = {C=-45, G=-45, O=-45, Q=-45, j=-50, v=-80},
  D = {A=-66, T=-75, V=-65, W=-52, X=-71, Y=-97},
  F = {A=-134, J=-187, a=-59, c=-52, d=-52, e=-52, g=-52,
    o=-52, q=-52, s=-49, u=-50},
  G = {T=-47, V=-44, W=-42, X=-52, Y=-81},
  H = {j=-41}, I = {j=-41}, J = {A=-50},
  K = {C=-49, G=-49, J=-56, O=-49, Q=-49, Y=-60, c=-58, d=-58,
    e=-58, f=-73, g=-58, o=-58, q=-58, t=-45, u=-52, v=-96,
    w=-53, y=-77},
  L = {C=-57, G=-57, O=-57, Q=-57, T=-160, V=-125, W=-91,
    Y=-179, f=-54, v=-111, w=-58, y=-88},
  M = {j=-41}, N = {j=-41},
  O = {A=-66, T=-75, V=-65, W=-52, X=-71, Y=-97},
  P = {A=-128, J=-250, X=-73, Y=-53, a=-45, c=-40, d=-40,
    e=-40, g=-40, o=-40, q=-40},
  Q = {A=-66, T=-75, V=-65, W=-52, X=-71, Y=-97},
  R = {T=-57, V=-55, W=-47, Y=-84},
  S = {A=-46, W=-43, Y=-75},
  T = {A=-165, C=-74, G=-74, J=-165, O=-74, Q=-74, a=-195,
    c=-195, d=-195, e=-195, f=-80, g=-195, j=-83, m=-141,
    n=-141, o=-195, p=-125, q=-195, r=-141, s=-199, t=-57,
    u=-142, v=-112, w=-100, x=-141, y=-110, z=-146},
  U = {A=-48, J=-41},
  V = {A=-167, C=-60, G=-60, J=-163, O=-60, Q=-60, S=-57,
    a=-135, c=-126, d=-126, e=-126, f=-65, g=-126, j=-71,
    m=-117, n=-117, o=-126, p=-77, q=-126, r=-117, s=-140,
    u=-116, v=-81, w=-50, x=-55, y=-82, z=-106},
  W = {A=-115, C=-49, G=-49, J=-136, O=-49, Q=-49, S=-57,
    a=-94, c=-96, d=-96, e=-96, f=-47, g=-96, m=-91, n=-91,
    o=-96, p=-65, q=-96, r=-91, s=-109, u=-90, v=-69, w=-40,
    y=-63, z=-78},
  X = {C=-72, G=-72, J=-50, O=-72, Q=-72, S=-51, c=-60,
    d=-60, e=-60, f=-65, g=-60, o=-60, q=-60, t=-56, u=-59,
    v=-82, w=-40, y=-54},
  Y = {A=-190, C=-98, G=-98, J=-198, O=-98, Q=-98, S=-92,
    a=-214, c=-187, d=-187, e=-187, f=-99, g=-187, j=-127,
    m=-156, n=-156, o=-187, p=-85, q=-187, r=-156, s=-191,
    t=-58, u=-160, v=-101, w=-102, x=-127, y=-109, z=-148},
  Z = {C=-41, G=-41, O=-41, Q=-41, y=-64},
  a = {T=-232, V=-158, W=-127, Y=-225, f=-40, t=-40, v=-52},
  b = {A=-45, J=-45, T=-186, V=-126, W=-94, X=-60, Y=-187,
    f=-45, v=-54, x=-48},
  c = {T=-165, V=-75, W=-50, Y=-123},
  e = {T=-196, V=-111, W=-106, Y=-163},
  f = {A=-94, J=-108, T=47, Y=56, a=-81, c=-74, d=-74,
    e=-74, g=-74, o=-74, q=-74},
  g = {T=-133, V=-61, W=-48, Y=-141, j=40},
  h = {T=-174, V=-159, W=-124, Y=-205},
  i = {j=50}, j = {j=50},
  k = {C=-40, G=-40, O=-40, Q=-40, T=-107, U=-44, V=-77,
    W=-64, Y=-105},
  m = {T=-174, V=-159, W=-124, Y=-205},
  n = {T=-174, V=-159, W=-124, Y=-205},
  o = {A=-45, J=-45, T=-186, V=-126, W=-94, X=-60, Y=-187,
    f=-45, v=-54, x=-48},
  p = {A=-45, J=-45, T=-186, V=-126, W=-94, X=-60, Y=-187,
    f=-45, v=-54, x=-48},
  q = {T=-90, j=80},
  r = {A=-128, J=-156, T=-107, X=-73, Y=-92, Z=-42, c=-52,
    d=-52, e=-52, g=-52, o=-52, q=-52},
  s = {T=-172, V=-109, W=-88, Y=-166},
  t = {T=-74, V=-48, Y=-69},
  u = {T=-153, V=-114, W=-86, Y=-155},
  v = {A=-155, J=-85, T=-112, V=-81, W=-69, X=-82, Y=-101,
    Z=-45, c=-53, d=-53, e=-53, g=-53, o=-53, q=-53},
  w = {A=-123, J=-58, T=-101, V=-62, W=-40, X=-40, Y=-102},
  x = {J=-42, T=-142, V=-55, Y=-127, c=-48, d=-48, e=-48,
    g=-48, o=-48, q=-48},
  y = {A=-155, J=-89, T=-110, V=-82, W=-63, X=-53, Y=-107,
    Z=-47, c=-50, d=-50, e=-50, g=-50, o=-50, q=-50},
  z = {T=-147, V=-103, W=-78, Y=-142, c=-48, d=-48, e=-48,
    g=-48, o=-48, q=-48},
}

local PUNCTUATION_KERNING = {
  ['A"']=-105, ["A'"]=-105, ['AT']=-165,
  ['L"']=-160, ["L'"]=-160,
  ['T,']=-208, ['T.']=-207, ['V,']=-186, ['V.']=-190,
  ['W,']=-118, ['W.']=-137, ['Y,']=-216, ['Y.']=-220,
  ['F,']=-172, ['F.']=-185, ['P,']=-224, ['P.']=-231,
  ['r,']=-160, ['r.']=-180, ['v,']=-142, ['v.']=-134,
  ['w,']=-112, ['w.']=-105, ['y,']=-121, ['y.']=-120,
  [',T']=-207, ['.T']=-207, [',V']=-190, ['.V']=-190,
  [',W']=-137, ['.W']=-137, [',Y']=-220, ['.Y']=-220,
}

local COMMON_ADVANCES = {
  [0x2013]=1125, [0x2014]=1800,
  [0x2018]=476, [0x2019]=476, [0x201C]=792, [0x201D]=792,
  [0x2022]=762, [0x2026]=1428, [0x20AC]=1200, [0x2122]=1219,
}

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

local function is_combining(value)
  return (value >= 0x0300 and value <= 0x036F) or
    (value >= 0x1AB0 and value <= 0x1AFF) or
    (value >= 0x1DC0 and value <= 0x1DFF) or
    (value >= 0x20D0 and value <= 0x20FF) or
    (value >= 0xFE00 and value <= 0xFE0F) or
    (value >= 0xFE20 and value <= 0xFE2F) or value == 0x200C or
    value == 0x200D
end

local function is_wide(value)
  return (value >= 0x1100 and value <= 0x11FF) or
    (value >= 0x2E80 and value <= 0xA4CF) or
    (value >= 0xAC00 and value <= 0xD7AF) or
    (value >= 0xF900 and value <= 0xFAFF) or
    (value >= 0x1F000 and value <= 0x1FAFF)
end

local function glyph_advance(character, value)
  if value >= 0x20 and value <= 0x7E then
    return ASCII_ADVANCES[value - 0x1F]
  end
  if value >= 0xA0 and value <= 0xFF then
    return LATIN1_ADVANCES[value - 0x9F]
  end
  if value == 0x09 then return ASCII_ADVANCES[1] * 4 end
  if value == 0x0A or value == 0x0D or is_combining(value) then return 0 end
  if COMMON_ADVANCES[value] then return COMMON_ADVANCES[value] end
  -- Unsupported scripts are rendered through a fallback font, whose exact
  -- metrics are not knowable here.  Preserve conservative estimates for them.
  if is_wide(value) then return 2485 end
  return 1392
end

local function kerning(left, right)
  if not left then return 0 end
  local direct = PUNCTUATION_KERNING[left .. right]
  if direct then return direct end
  local row = KERNING[left]
  return row and row[right] or 0
end

function text_metrics.new(args)
  local dp = args.dp
  local scale_font = args.scale_font
  local use_kerning = args.kerning == true
  local default_size = args.default_size or 24
  local cache, cache_size = {}, 0

  local metrics = {}

  local function measured_units(text)
    local cached = cache[text]
    if cached then return cached end

    local line_width, maximum_width, previous = 0, 0, nil
    for character in text:gmatch(UTF8_CHARACTER) do
      local value = codepoint(character)
      if value == 0x0A then
        maximum_width = math.max(maximum_width, line_width)
        line_width, previous = 0, nil
      elseif value ~= 0x0D then
        local advance = glyph_advance(character, value)
        line_width = line_width + advance
        if advance > 0 then
          if use_kerning then
            line_width = line_width + kerning(previous, character)
          end
          previous = character
        end
      end
    end
    local result = math.max(maximum_width, line_width)
    if cache_size >= 512 then cache, cache_size = {}, 0 end
    cache[text], cache_size = result, cache_size + 1
    return result
  end

  local function rendered_size(size)
    size = tonumber(size) or default_size
    if scale_font then return scale_font(size) end
    return dp(size)
  end

  function metrics.length(text)
    local count = 0
    for _ in tostring(text or ""):gmatch(UTF8_CHARACTER) do count = count + 1 end
    return count
  end

  function metrics.truncate(text, maximum)
    text, maximum = tostring(text or ""), math.floor(tonumber(maximum) or 0)
    if maximum <= 0 then return "" end
    if metrics.length(text) <= maximum then return text end

    local suffix = maximum > 3 and "..." or ""
    local keep = maximum > 3 and maximum - 3 or maximum
    local characters = {}
    for character in text:gmatch(UTF8_CHARACTER) do
      if #characters >= keep then break end
      characters[#characters + 1] = character
    end
    return table.concat(characters) .. suffix
  end

  function metrics.width(text, size)
    text = tostring(text or "")
    return measured_units(text) / FONT_HEIGHT * rendered_size(size)
  end

  function metrics.truncate_to_width(text, maximum_width, size)
    text = tostring(text or "")
    maximum_width = tonumber(maximum_width) or 0
    if metrics.width(text, size) <= maximum_width then return text end

    local ellipsis = "..."
    if metrics.width(ellipsis, size) > maximum_width then return ellipsis end

    local characters = {}
    for character in text:gmatch(UTF8_CHARACTER) do
      characters[#characters + 1] = character
    end

    local low, high, best = 0, #characters, 0
    while low <= high do
      local middle = math.floor((low + high) / 2)
      local candidate = table.concat(characters, "", 1, middle) .. ellipsis
      if metrics.width(candidate, size) <= maximum_width then
        best, low = middle, middle + 1
      else
        high = middle - 1
      end
    end
    return table.concat(characters, "", 1, best) .. ellipsis
  end

  return metrics
end

return text_metrics
