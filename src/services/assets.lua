local assets = {}

local function script_directory(fallback)
  if fallback and fallback ~= "" then return fallback end
  local source = debug.getinfo(2, "S").source
  if source:sub(1, 1) == "@" then source = source:sub(2) end
  local directory = source:match("^(.*)[/\\][^/\\]-$")
  return directory and directory ~= "" and directory or "."
end

function assets.initialize(args)
  local directory = script_directory(args.script_dir)
  local font_dir = args.utils.join_path(directory, "fonts")
  if not args.utils.file_info(font_dir) then
    font_dir = args.utils.join_path(directory, "../fonts")
  end
  args.msg.verbose("loading local OSD and subtitle font directory: " .. font_dir)
  mp.set_property("osd-fonts-dir", font_dir)
  mp.set_property("sub-fonts-dir", font_dir)
  return {script_dir = directory, font_dir = font_dir}
end

return assets
