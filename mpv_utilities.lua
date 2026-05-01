-- mpv_utilities.lua
-- Robust version: Absolute Paths, Auto-Directory Creation, and EDL-aware Snapping.
-- (Cleaned up: Removed embed_cover workaround, using force-window natively instead)

local M = {}

-- Standard dependencies
local mp = require('mp')
local utils = require('mp.utils')
local msg = require('mp.msg')
local os = os
local string = string
local tonumber = tonumber
local table = table
local math = math
local io = io

-- --- Configuration & Constants ---

local LOG_FILE = "/tmp/mpv_history_logger.log"

-- REQUIRED ENVIRONMENT VARIABLES
local SNITCH_DIR = os.getenv("BCHU")
local HI_DIR = os.getenv("HI") 
local MPVL_DIR_RAW = os.getenv("MPVL") or ""
local MPVL_DIR = MPVL_DIR_RAW:match("(.+[^/])$") or MPVL_DIR_RAW 

-- Internal State Variables
local execution_context = "UNKNOWN"
local previous_file_duration = 0
local current_file_path = "N/A"
local g_start_second = 0 
local script_is_loaded = false 
local keybindings_set = false 

local VIDEO_EXTENSIONS = {
    ["mkv"] = true, ["mp4"] = true, ["avi"] = true, ["webm"] = true, 
    ["wmv"] = true, ["mov"] = true, ["flv"] = true, ["ts"] = true, ["m4v"] = true
}
local AUDIO_EXTENSIONS = {
    ["mp3"] = true, ["m4a"] = true, ["flac"] = true, ["wav"] = true, 
    ["ogg"] = true, ["aac"] = true
}

-- --- Utility Functions ---

function M.log(level, ...)
    local timestamp = os.date("%H:%M:%S")
    local parts = {}
    for i, v in ipairs({...}) do parts[i] = tostring(v) end
    local message = table.concat(parts, ' ')
    
    if script_is_loaded or level == "error" then
        if level == "error" then msg.error("[LOGGER] " .. message) else msg.info("[LOGGER] " .. message) end
    end
    
    local log_handle = io.open(LOG_FILE, "a")
    if log_handle then
        log_handle:write(timestamp .. " [" .. string.upper(level) .. "] " .. message .. "\n")
        log_handle:close()
    end
end

local function send_OSD(message_string, seconds)
    local message_str = mp.get_property("osd-ass-cc/0")..message_string..mp.get_property("osd-ass-cc/1")
    mp.osd_message(message_str, seconds or 2)
end

-- Ensures parent directories exist for a given file path
local function ensure_dir(filepath)
    local dir = filepath:match("(.+)/[^/]+$")
    if dir then os.execute("mkdir -p '" .. dir .. "'") end
end

local function get_safe_time_pos()
    local t = mp.get_property_number("time-pos")
    return t and math.floor(t) or 0
end

local function get_safe_duration()
    local d = mp.get_property_number("duration")
    return d and math.floor(d) or 0
end

local function get_file_class(filepath)
    if not filepath or filepath == "" then return "unrecognised" end

    -- 1. Fast Extension Check
    local ext = filepath:match("%.([^%.]+)$")
    if ext then
        ext = ext:lower()
        if ext == "edl" then return "edl" end
        if VIDEO_EXTENSIONS[ext] then return "video" end
        if AUDIO_EXTENSIONS[ext] then return "audio" end
    end

    -- 2. Single-pass Content Check (The "Native" Fallback)
    local f = io.open(filepath, "rb")
    if f then
        local first_line = f:read("*l") or ""
        f:close()

        -- Check for EDL header
        if first_line:find("^# mpv EDL v0") then
            return "edl"
        end
    end

    return "unrecognised"
end

local function file_exists(file)
    local f = io.open(file, "rb")
    if f then f:close() end
    return f ~= nil
end

local function create_edl_if_missing(bfile)
    if not bfile then return false end
    if not file_exists(bfile) then
        ensure_dir(bfile)
        local hndl = io.open(bfile, "wb")
        if hndl then hndl:write("# mpv EDL v0\n") hndl:close() end
    end
    return true
end

local function Split(inputstr, sep)
    local t = {}
    for str in string.gmatch(inputstr, "([^"..sep.."]+)") do table.insert(t, str) end
    return t
end

local function get_the_edl_record(edl_path, chapter_number)
    if not edl_path or not file_exists(edl_path) then return nil end
    local lines = {}
    for line in io.lines(edl_path) do
        if not line:match("^#") then table.insert(lines, line) end
    end
    return lines[chapter_number + 1]
end

local function day_journal(record)
    local DAY_journal_name = "/tmp/edl_day_journal.edl"
    create_edl_if_missing(DAY_journal_name)
    local DAY_handle = io.open(DAY_journal_name, "a")
    if DAY_handle then DAY_handle:write(record) DAY_handle:close() end
end

local function write_that_SNITCH(SNITCHfilename, record, path)
    ensure_dir(SNITCHfilename)
    local SNITCH_handle = io.open(SNITCHfilename, "a")
    if not SNITCH_handle then
        M.log("error", "Failed to open SNITCH file:", SNITCHfilename)
        return
    end
    SNITCH_handle:write(record)
    SNITCH_handle:close()
    send_OSD("SNITCHED: "..path:gsub("\\","/"), 3)
end

-- Helper for absolute path resolution
local function get_full_path()
    local path = mp.get_property("path")
    if not path then return nil end
    local working_dir = mp.get_property("working-directory") or ""
    return utils.join_path(working_dir, path)
end

-- --- Cutting Functions ---

local function valid_for_cutting()
    local path = mp.get_property("path") or ""
    local fileclass = get_file_class(path)
    if fileclass == "video" or fileclass == "audio" then return true end
    send_OSD("Wrong file type: "..fileclass, 2)
    return false
end

function M.start_cut()
    if not valid_for_cutting() then return end
    g_start_second = get_safe_time_pos()
    send_OSD("Start cut "..g_start_second, 1)
end

function M.end_cut()
    if not valid_for_cutting() then return end
    local current_time_pos = get_safe_time_pos()
    local cut_duration = current_time_pos - g_start_second
    
    if cut_duration <= 0 then
        send_OSD("Invalid duration. Aborted.", 3)
        return
    end

    local full_path = get_full_path()
    if not full_path then return end

    local str_record = full_path..","..g_start_second..","..cut_duration.."\n"
    local SNITCH_file = SNITCH_DIR and (SNITCH_DIR.."/manual_cut_"..os.date('%d_%m_%y_%H')..".edl") or nil
    
    if not SNITCH_file then
        send_OSD("Error: SNITCH_DIR (BCHU) not set.", 3)
        return
    end

    write_that_SNITCH(SNITCH_file, str_record, full_path)
    day_journal(str_record)
    g_start_second = 0
end

-- --- Snap and Gold Key ---

function M.snap_SNITCH()
    local full_path = get_full_path()
    if not full_path then return end
    local fileclass = get_file_class(full_path)
    local CALL_OS = nil
    
    if fileclass == "edl" then
        local chapter = mp.get_property_native("chapter") or 0
        local edl_record = get_the_edl_record(mp.get_property("path"), chapter)
        if edl_record then
            local parts = Split(edl_record, ",")
            local source_file = parts[1]
            -- Resolve inner EDL path relative to the EDL itself
            if not source_file:match("^/") then
                local edl_dir = full_path:match("(.+)/[^/]+$") or "."
                source_file = utils.join_path(edl_dir, source_file)
            end
            CALL_OS = string.format("mpv --screen=0 --fs-screen=0 --volume=10 --start=%s '%s'", parts[2], source_file)
        end
    else
        CALL_OS = string.format("mpv --screen=0 --fs-screen=0 --volume=10 --start=%d '%s'", get_safe_time_pos(), full_path)
    end

    if CALL_OS then
        send_OSD("Snapping...", 2)
        mp.command("keypress SPACE")
        os.execute("nohup " .. CALL_OS .. " > /dev/null 2>&1 &")
    end
end

function M.goldKey()
    local path = mp.get_property("path")
    local fileclass = get_file_class(path)
    local record = nil
    local gold_file = HI_DIR and (HI_DIR.."/goldVaultCurrent.edl") or nil

    if not gold_file then
        M.log("error", "GOLD FAILED: HI_DIR not set.")
        send_OSD("Gold Key failed: HI_DIR missing.", 3)
        return
    end

    create_edl_if_missing(gold_file)

    if fileclass == "edl" then
        local chapter = mp.get_property_native("chapter")
        local record_number = chapter or 0
        local edl_record = get_the_edl_record(path, record_number)
        
        local fnam = Split(edl_record, ",")
        local file_name_only = fnam[1]
        local start_second = fnam[2]
        local llength = fnam[3]

        record = file_name_only..","..start_second..","..llength.."\n"
    else
        M.log("warn", "GOLD: Cannot use Gold Key on non-EDL file class:", fileclass)
        send_OSD("Gold Key requires EDL context.", 2)
        return
    end

    local goldHandler = io.open(gold_file,"a")
    if goldHandler then
        goldHandler:write(record)
        goldHandler:close()
        send_OSD("Gold Keyed: wrote record to goldVaultCurrent.edl", 2)
        M.log("info", "GOLD: Wrote record:", record)
    else
        M.log("error", "GOLD FAILED: Cannot open goldVaultCurrent.edl")
        send_OSD("Gold Key failed: cannot write file", 3)
    end
    
    mp.command("playlist-next")
end

function M.deleteMe()
    local filename = mp.get_property_native("path")
    if not filename then
        M.log("error", "DELETE_ME: Could not get current file path.")
        send_OSD("Delete Me failed: No path.", 3)
        return
    end

    M.log("info", "DELETE_ME: Adding '"..filename.."' to /tmp/deleteMe.sh")
    
    local delete_handle, err = io.open('/tmp/deleteMe.sh', "a")
    if not delete_handle then
        M.log("error", "DELETE_ME: Failed to open /tmp/deleteMe.sh. Error: " .. tostring(err))
        send_OSD("Delete Me failed: Cannot write to /tmp/deleteMe.sh", 3)
        return
    end
    
    local command_to_write = "if [ -f '"..filename.."' ]; then rm -v '"..filename.."'; fi\n"
    delete_handle:write(command_to_write)
    delete_handle:close()
    send_OSD("Marked for deletion: "..filename, 2)
    mp.command("playlist-next")
end

-- --- Keybindings ---
local function setup_keybindings()
    if keybindings_set then return end 
    mp.add_key_binding("n", "user-skip-next", function() mp.command("playlist-next") end)
    mp.add_key_binding("KP1", "start_cut", function() M.start_cut() end)
    mp.add_key_binding("KP2", "end_cut", function() M.end_cut() end)
    mp.add_key_binding("KP0", "snap_SNITCH", function() M.snap_SNITCH() end)
    mp.add_key_binding("g", "goldKey", function() M.goldKey() end)
    -- add control + DEL for deleteMe
    mp.add_key_binding("ctrl+DEL", "deleteMe", function() M.deleteMe() end)
    keybindings_set, script_is_loaded = true, true
end

function M.file_loaded()
    if not keybindings_set then mp.add_timeout(0, setup_keybindings) end
end

-- --- Execution ---

pcall(function()
    if MPVL_DIR_RAW ~= "" then
        -- Force a window to open so numpad bindings work on audio-only files natively
        mp.set_property("force-window", "yes")
        
        mp.register_event("file-loaded", M.file_loaded)
        mp.register_event("end-file", function(event) 
            previous_file_duration = (event.reason == "eof") and get_safe_duration() or get_safe_time_pos() 
        end)
    end
end)

return M