local subtitle_loader = {}

local WINDOWS_FILTER = "*.srt;*.ass;*.ssa;*.vtt;*.sub;*.idx;*.sup"
local UNIX_FILTER = "*.srt *.ass *.ssa *.vtt *.sub *.idx *.sup"

function subtitle_loader.new(args)
  local render = args.render

  local function restore_primary_subtitle(id)
    if id and id ~= "" then mp.set_property("sid", id)
    else mp.set_property("sid", "no") end
  end

  local function add_secondary_subtitle(source)
    local primary_id = mp.get_property("sid", "no") or "no"
    mp.commandv("sub-add", source, "select")
    local added_id = mp.get_property_number("sid")
    restore_primary_subtitle(primary_id)
    if added_id then
      mp.set_property_number("secondary-sid", added_id)
      mp.set_property_native("secondary-sub-visibility", true)
    end
  end

  local function attach_files(output, secondary)
    local added = 0
    for path in tostring(output or ""):gmatch("[^\r\n]+") do
      local clean_path = path:match("^%s*(.-)%s*$")
      if clean_path ~= "" then
        if secondary and added == 0 then
          add_secondary_subtitle(clean_path)
        else
          mp.commandv("sub-add", clean_path, added == 0 and "select" or "auto")
        end
        added = added + 1
      end
    end
    if added > 0 then render() end
  end

  local function run_picker(command, fallback, on_result)
    mp.command_native_async({
      name = "subprocess", args = command, playback_only = false,
      capture_stdout = true, capture_stderr = true
    }, function(success, result)
      if success and result and result.status == 0 and result.stdout and
        result.stdout:match("%S") then
        (on_result or attach_files)(result.stdout)
      elseif fallback and (not success or not result or result.status == 127) then
        fallback()
      end
    end)
  end

  local function open_file_picker(secondary)
    local title = secondary and "Add secondary subtitle" or "Add subtitles"
    local on_result = function(output) attach_files(output, secondary) end
    local os_name = jit and jit.os or ""
    if os_name == "Windows" then
      local script = table.concat({
        "[Console]::OutputEncoding=[Text.Encoding]::UTF8;",
        "Add-Type -AssemblyName System.Windows.Forms;",
        "$d=New-Object System.Windows.Forms.OpenFileDialog;",
        "$d.Title='" .. title .. "';",
        "$d.Multiselect=$true;",
        "$d.Filter='Subtitle files|" .. WINDOWS_FILTER .. "|All files|*.*';",
        "if($d.ShowDialog() -eq 'OK'){[Console]::Write(($d.FileNames -join \"`n\"))}"
      }, " ")
      run_picker({"powershell", "-NoProfile", "-Command", script}, nil, on_result)
    elseif os_name == "OSX" then
      local script = table.concat({
        "set picked to choose file with prompt \"" .. title .. "\" of type " ..
          "{\"srt\", \"ass\", \"ssa\", \"vtt\", \"sub\", \"idx\", \"sup\"} " ..
          "with multiple selections allowed",
        "set output to \"\"",
        "repeat with f in picked",
        "set output to output & POSIX path of f & linefeed",
        "end repeat",
        "return output"
      }, "\n")
      run_picker({"osascript", "-e", script}, nil, on_result)
    else
      run_picker({"zenity", "--file-selection", "--multiple",
        "--title=" .. title, "--separator=\n",
        "--file-filter=Subtitle files | " .. UNIX_FILTER,
        "--file-filter=All files | *"}, function()
          run_picker({"kdialog", "--getopenfilename", "~",
            "Subtitle files (" .. UNIX_FILTER .. ")", "--multiple",
            "--separate-output", "--title", title}, nil, on_result)
        end, on_result)
    end
  end

  local function attach_link(output, secondary)
    local url = (output or ""):match("^%s*(.-)%s*$")
    if url == "" then return end
    if secondary then add_secondary_subtitle(url)
    else mp.commandv("sub-add", url, "select") end
    render()
  end

  local function open_link_picker(secondary)
    local title = secondary and "Add secondary subtitle link" or "Add subtitle link"
    local on_result = function(output) attach_link(output, secondary) end
    local os_name = jit and jit.os or ""
    if os_name == "Windows" then
      local script = table.concat({
        "Add-Type -AssemblyName Microsoft.VisualBasic;",
        "$u=[Microsoft.VisualBasic.Interaction]::InputBox(",
        "'Enter a subtitle URL','" .. title .. "','');",
        "Write-Output $u"
      }, "")
      run_picker({"powershell", "-NoProfile", "-Command", script}, nil, on_result)
    elseif os_name == "OSX" then
      local script = "text returned of (display dialog \"Enter a subtitle URL\" " ..
        "default answer \"\" with title \"" .. title .. "\")"
      run_picker({"osascript", "-e", script}, nil, on_result)
    else
      run_picker({"zenity", "--entry", "--title=" .. title,
        "--text=Enter a subtitle URL:"}, function()
          run_picker({"kdialog", "--inputbox", "Enter a subtitle URL:", "",
            "--title", title}, nil, on_result)
        end, on_result)
    end
  end

  return {
    open_file_picker = function() open_file_picker(false) end,
    open_link_picker = function() open_link_picker(false) end,
    open_secondary_file_picker = function() open_file_picker(true) end,
    open_secondary_link_picker = function() open_link_picker(true) end
  }
end

return subtitle_loader
