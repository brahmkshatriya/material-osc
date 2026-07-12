local subtitle_loader = {}

local WINDOWS_FILTER = "*.srt;*.ass;*.ssa;*.vtt;*.sub;*.idx;*.sup"
local UNIX_FILTER = "*.srt *.ass *.ssa *.vtt *.sub *.idx *.sup"

function subtitle_loader.new(args)
  local render = args.render

  local function attach_files(output)
    local added = 0
    for path in tostring(output or ""):gmatch("[^\r\n]+") do
      local clean_path = path:match("^%s*(.-)%s*$")
      if clean_path ~= "" then
        mp.commandv("sub-add", clean_path, added == 0 and "select" or "auto")
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

  local function open_file_picker()
    local os_name = jit and jit.os or ""
    if os_name == "Windows" then
      local script = table.concat({
        "[Console]::OutputEncoding=[Text.Encoding]::UTF8;",
        "Add-Type -AssemblyName System.Windows.Forms;",
        "$d=New-Object System.Windows.Forms.OpenFileDialog;",
        "$d.Multiselect=$true;",
        "$d.Filter='Subtitle files|" .. WINDOWS_FILTER .. "|All files|*.*';",
        "if($d.ShowDialog() -eq 'OK'){[Console]::Write(($d.FileNames -join \"`n\"))}"
      }, " ")
      run_picker({"powershell", "-NoProfile", "-Command", script})
    elseif os_name == "OSX" then
      local script = table.concat({
        "set picked to choose file with prompt \"Add subtitles\" of type " ..
          "{\"srt\", \"ass\", \"ssa\", \"vtt\", \"sub\", \"idx\", \"sup\"} " ..
          "with multiple selections allowed",
        "set output to \"\"",
        "repeat with f in picked",
        "set output to output & POSIX path of f & linefeed",
        "end repeat",
        "return output"
      }, "\n")
      run_picker({"osascript", "-e", script})
    else
      run_picker({"zenity", "--file-selection", "--multiple",
        "--title=Add subtitles", "--separator=\n",
        "--file-filter=Subtitle files | " .. UNIX_FILTER,
        "--file-filter=All files | *"}, function()
          run_picker({"kdialog", "--getopenfilename", "~",
            "Subtitle files (" .. UNIX_FILTER .. ")", "--multiple",
            "--separate-output", "--title", "Add subtitles"})
        end)
    end
  end

  local function attach_link(output)
    local url = (output or ""):match("^%s*(.-)%s*$")
    if url == "" then return end
    mp.commandv("sub-add", url, "select")
    render()
  end

  local function open_link_picker()
    local os_name = jit and jit.os or ""
    if os_name == "Windows" then
      local script = table.concat({
        "Add-Type -AssemblyName Microsoft.VisualBasic;",
        "$u=[Microsoft.VisualBasic.Interaction]::InputBox(",
        "'Enter a subtitle URL','Add subtitle link','');",
        "Write-Output $u"
      }, "")
      run_picker({"powershell", "-NoProfile", "-Command", script}, nil, attach_link)
    elseif os_name == "OSX" then
      local script = "text returned of (display dialog \"Enter a subtitle URL\" " ..
        "default answer \"\" with title \"Add subtitle link\")"
      run_picker({"osascript", "-e", script}, nil, attach_link)
    else
      run_picker({"zenity", "--entry", "--title=Add subtitle link",
        "--text=Enter a subtitle URL:"}, function()
          run_picker({"kdialog", "--inputbox", "Enter a subtitle URL:", "",
            "--title", "Add subtitle link"}, nil, attach_link)
        end, attach_link)
    end
  end

  return {open_file_picker = open_file_picker, open_link_picker = open_link_picker}
end

return subtitle_loader
