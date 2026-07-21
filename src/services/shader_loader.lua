local shader_loader = {}

local WINDOWS_FILTER = "*.glsl;*.hook"
local UNIX_FILTER = "*.glsl *.hook"

function shader_loader.new(args)
  local mp, utils, msg = args.mp, args.utils, args.msg
  local render = args.render

  local function run_picker(command, fallback, on_result)
    mp.command_native_async({
      name = "subprocess", args = command, playback_only = false,
      capture_stdout = true, capture_stderr = true
    }, function(success, result)
      if success and result and result.status == 0 and result.stdout and
        result.stdout:match("%S") then
        on_result(result.stdout)
      elseif fallback and (not success or not result or result.status == 127) then
        fallback()
      end
    end)
  end

  local function add_shader(path)
    path = tostring(path or ""):match("^%s*(.-)%s*$")
    if path == "" then return end
    mp.commandv("change-list", "glsl-shaders", "append", path)
  end

  local function attach_files(output)
    local added = false
    for path in tostring(output or ""):gmatch("[^\r\n]+") do
      add_shader(path)
      added = true
    end
    if added then render() end
  end

  local function open_file_picker()
    local title = "Add video shaders"
    local os_name = jit and jit.os or ""
    if os_name == "Windows" then
      local script = table.concat({
        "[Console]::OutputEncoding=[Text.Encoding]::UTF8;",
        "Add-Type -AssemblyName System.Windows.Forms;",
        "$d=New-Object System.Windows.Forms.OpenFileDialog;",
        "$d.Title='" .. title .. "';",
        "$d.Multiselect=$true;",
        "$d.Filter='Shader files|" .. WINDOWS_FILTER .. "|All files|*.*';",
        "if($d.ShowDialog() -eq 'OK'){[Console]::Write(($d.FileNames -join \"`n\"))}"
      }, " ")
      run_picker({"powershell", "-NoProfile", "-Command", script}, nil,
        attach_files)
    elseif os_name == "OSX" then
      local script = table.concat({
        "set picked to choose file with prompt \"" .. title .. "\" of type " ..
          "{\"glsl\", \"hook\"} with multiple selections allowed",
        "set output to \"\"",
        "repeat with f in picked",
        "set output to output & POSIX path of f & linefeed",
        "end repeat",
        "return output"
      }, "\n")
      run_picker({"osascript", "-e", script}, nil, attach_files)
    else
      run_picker({"zenity", "--file-selection", "--multiple",
        "--title=" .. title, "--separator=\n",
        "--file-filter=Shader files | " .. UNIX_FILTER,
        "--file-filter=All files | *"}, function()
          run_picker({"kdialog", "--getopenfilename", "~",
            "Shader files (" .. UNIX_FILTER .. ")", "--multiple",
            "--separate-output", "--title", title}, nil, attach_files)
        end, attach_files)
    end
  end

  local function ensure_directory(path)
    if utils.file_info(path) then return true end
    local os_name = jit and jit.os or ""
    local command = os_name == "Windows" and
      {"powershell", "-NoProfile", "-Command",
        "New-Item -ItemType Directory -Force -LiteralPath $args[0] | Out-Null",
        path} or {"mkdir", "-p", path}
    local result = mp.command_native({
      name = "subprocess", args = command, playback_only = false
    })
    return result and tonumber(result.status) == 0
  end

  local function download_shader(url)
    url = tostring(url or ""):match("^%s*(.-)%s*$")
    if url == "" then return end
    local directory = mp.command_native({
      "expand-path", "~~/cache/material-osc/shaders"
    })
    if not directory or directory == "" or not ensure_directory(directory) then
      mp.osd_message("Could not create the shader cache directory", 3)
      return
    end
    local filename = url:gsub("[?#].*$", ""):match("([^/\\]+)$") or "shader.glsl"
    filename = filename:gsub("[^%w%._%-]", "_")
    if not filename:match("%.[%w]+$") then filename = filename .. ".glsl" end
    filename = tostring(os.time()) .. "-" .. filename
    local output = utils.join_path(directory, filename)
    local command = {"curl", "-fLsS", "--connect-timeout", "10",
      "--max-time", "60", "-o", output, url}
    mp.command_native_async({
      name = "subprocess", args = command, playback_only = false,
      capture_stderr = true
    }, function(success, result)
      if (not success or not result or result.status ~= 0) and
        (jit and jit.os or "") == "Windows" then
        mp.command_native_async({name = "subprocess", playback_only = false,
          capture_stderr = true, args = {"powershell", "-NoProfile", "-Command",
            "Invoke-WebRequest -UseBasicParsing -Uri $args[0] -OutFile $args[1]",
            url, output}}, function(ps_success, ps_result)
              if ps_success and ps_result and ps_result.status == 0 then
                add_shader(output)
                render()
              else
                msg.error("shader download failed: " ..
                  tostring(ps_result and ps_result.stderr or "unknown error"))
                mp.osd_message("Shader download failed", 3)
              end
            end)
        return
      end
      if success and result and result.status == 0 then
        add_shader(output)
        render()
      else
        msg.error("shader download failed: " ..
          tostring(result and result.stderr or "unknown error"))
        mp.osd_message("Shader download failed", 3)
      end
    end)
  end

  local function open_link_picker()
    local title = "Add video shader link"
    local on_result = function(output) download_shader(output) end
    local os_name = jit and jit.os or ""
    if os_name == "Windows" then
      local script = table.concat({
        "Add-Type -AssemblyName Microsoft.VisualBasic;",
        "$u=[Microsoft.VisualBasic.Interaction]::InputBox(",
        "'Enter a shader URL','" .. title .. "','');",
        "Write-Output $u"
      }, "")
      run_picker({"powershell", "-NoProfile", "-Command", script}, nil, on_result)
    elseif os_name == "OSX" then
      local script = "text returned of (display dialog \"Enter a shader URL\" " ..
        "default answer \"\" with title \"" .. title .. "\")"
      run_picker({"osascript", "-e", script}, nil, on_result)
    else
      run_picker({"zenity", "--entry", "--title=" .. title,
        "--text=Enter a shader URL:"}, function()
          run_picker({"kdialog", "--inputbox", "Enter a shader URL:", "",
            "--title", title}, nil, on_result)
        end, on_result)
    end
  end

  return {
    open_file_picker = open_file_picker,
    open_link_picker = open_link_picker,
    remove = function(path)
      mp.commandv("change-list", "glsl-shaders", "remove", path)
      render()
    end,
    clear = function()
      mp.commandv("change-list", "glsl-shaders", "clr", "")
      render()
    end
  }
end

return shader_loader
