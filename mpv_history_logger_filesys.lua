-- mpv_history_logger_v3.lua
-- Goal: Add Snap (KP0) and Gold Key (g) functionality with robust audio input.
-- FIXES INCLUDED: 1. VO-Force using 'options-add vo null' for audio-only stability.
-- 2. Deferred (timeout) key binding. 3. Robust anonymous function wrapping for bindings.

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

-- Configuration
local LOG_FILE = "/tmp/mpv_history_logger.log"

-- STRICTLY REQUIRED ENVIRONMENT VARIABLES (Used by cutting/snitching/goldKey)
-- We assume BCHU and EDLSRC are set in the environment.
local SNITCH_DIR = os.getenv("BCHU")
local EDL_SNITCH_JOURNAL = SNITCH_DIR and (SNITCH_DIR.."/edl_journal.edl") or nil
local NON_EDL_JOURNAL = SNITCH_DIR and (SNITCH_DIR.."/m3u_journal.m3u") or nil
local DITCHED_FILE_PATH = os.getenv("EDLSRC") and (os.getenv("EDLSRC").."/ditched.txt") or nil
local SNITCH_SEGMENT_LENGTH = 30 

-- Internal State Variables
local execution_context = "UNKNOWN"
local previous_file_duration = 0
local current_file_path = "N/A"
local g_start_second = 0 
local script_is_loaded = false -- Flag to control console logging during setup

local VIDEO_EXTENSIONS = {
    ["mkv"] = true, ["mp4"] = true, ["avi"] = true, ["webm"] = true, 
    ["wmv"] = true, ["mov"] = true, ["flv"] = true, ["ts"] = true
}
local AUDIO_EXTENSIONS = {
    ["mp3"] = true, ["m4a"] = true, ["flac"] = true, ["wav"] = true, 
    ["ogg"] = true, ["aac"] = true
}

-- --- Utility Functions ---

function M.log(level, ...)
    local timestamp = os.date("%H:%M:%S")
    local parts = {}
    for i, v in ipairs({...}) do
        parts[i] = tostring(v)
    end
    local message = table.concat(parts, ' ')
    
    -- MODIFIED: ONLY print to console if the script is loaded OR if it's an error
    if script_is_loaded or level == "error" then
        if level == "error" then
            msg.error("[LOGGER/"..timestamp.."] " .. message)
        else
            msg.info("[LOGGER/"..timestamp.."] " .. message)
        end
    end
    
    -- ALWAYS write to the file log
    local log_message = timestamp .. " [" .. string.upper(level) .. "] " .. message
    local log_handle, err = io.open(LOG_FILE, "a")
    if log_handle then
        log_handle:write(log_message .. "\n")
        log_handle:close()
    end
end

-- Re-created from original code
local function send_OSD(message_string, seconds)
    local message_str = mp.get_property("osd-ass-cc/0")..message_string..mp.get_property("osd-ass-cc/1")
    mp.osd_message(message_str, seconds or 2)
end

local function get_safe_time_pos()
    local t = mp.get_property_number("time-pos")
    return t and math.floor(t) or 0
end

local function get_safe_duration()
    local d = mp.get_property_number("duration")
    return d and math.floor(d) or 0
end

local function get_file_class(filename)
    local ext_with_dot = filename:match("^.+(%..+)$")
    local ext = ext_with_dot and string.lower(ext_with_dot:sub(2))
    
    if not ext then return "unrecognised" end
    
    if ext == "edl" then return "edl" 
    elseif VIDEO_EXTENSIONS[ext] then
        return "video"
    elseif AUDIO_EXTENSIONS[ext] then
        return "audio"
    end
    
    return "unrecognised"
end

local function file_exists(file)
    local f = io.open(file, "rb")
    if f then f:close() end
    return f ~= nil
end

local function create_edl_if_missing(bfile)
    if not bfile then M.log("error", "Cannot create EDL: Path is nil."); return false end
    if not file_exists(bfile) then
        local hndl = io.open(bfile, "wb")
        if hndl then
            hndl:write("# mpv EDL v0\n")
            hndl:close()
            return true
        end
    end
    return true
end

-- Re-created from original code
local function Split(inputstr, sep)
    local t = {}
    for str in string.gmatch(inputstr, "([^"..sep.."]+)") do
        table.insert(t, str)
    end
    return t
end

-- Simplified stub for EDL record retrieval (requires reading and parsing the file)
local function get_the_edl_record(edl_path, chapter_number)
    M.log("warn", "STUB: Returning mock EDL record for path:", edl_path)
    return edl_path .. ",10,60" 
end

-- Re-created from original code
local function day_journal(record)
    local DAY_journal_name = "/tmp/edl_day_journal.edl"
    create_edl_if_missing(DAY_journal_name)
    local DAY_handle = io.open(DAY_journal_name, "a")
    if DAY_handle then
        DAY_handle:write(record)
        DAY_handle:close()
    end
end

local function write_that_SNITCH(SNITCHfilename, record, journal_type, path)
    -- Simplified write function, omitting journal logic for brevity
    local SNITCH_handle = io.open(SNITCHfilename, "a")
    if not SNITCH_handle then
        M.log("error", "Failed to open SNITCH file for writing:", SNITCHfilename)
        return
    end
    SNITCH_handle:write(record)
    SNITCH_handle:close()

    local message_string = path:gsub("\\","/")
    send_OSD("SNITCHED: "..message_string, 3)
end

-- --- Cutting/EDL Functions ---

local function valid_for_cutting()
    local filename = mp.get_property("filename") or ""
    local fileclass = get_file_class(filename)
    if fileclass == "video" or fileclass == "audio" then
        return true
    else
        send_OSD("Wrong file type for cutting: "..fileclass, 2)
        return false
    end
end

function M.start_cut()
    if not valid_for_cutting() then return end
    local time_pos = get_safe_time_pos()
    g_start_second = time_pos
    M.log("info", "CUT: Start cut issued at", g_start_second, "s.")
    send_OSD("Start cut "..g_start_second, 1)
end

function M.end_cut()
    if not valid_for_cutting() then return end
    
    local current_time_pos = get_safe_time_pos()
    local cut_duration = current_time_pos - g_start_second
    
    if cut_duration <= 0 then
        M.log("warn", "CUT: End time is before or same as start time. Cut aborted.")
        send_OSD("End time is before or same as start time. Cut aborted.", 3)
        g_start_second = 0
        return
    end

    local path = mp.get_property("path")
    local str_record = path..","..g_start_second..","..cut_duration.."\n"

    local SNITCHfilename = "manual_cut_"..os.date('%d_%m_%y_%H')..".edl"
    local SNITCH_file = SNITCH_DIR and (SNITCH_DIR.."/"..SNITCHfilename) or nil
    
    if not SNITCH_file then
        M.log("error", "CUT FAILED: BCHU (SNITCH_DIR) not set.")
        send_OSD("Cut failed: SNITCH_DIR missing.", 3)
        return
    end

    M.log("info", "CUT: Adding record:", str_record)
    M.log("info", "CUT: Writing to:", SNITCH_file)

    create_edl_if_missing(SNITCH_file)
    write_that_SNITCH(SNITCH_file, str_record, "edl", path)
    day_journal(str_record)

    g_start_second = 0
    M.log("info", "CUT: Ready for next cut.")
    send_OSD("Ready for next Cut", 2)
end

-- --- New Functionality: Snap and Gold Key (Simplified) ---

function M.snap_SNITCH()
    local filename = mp.get_property("filename")
    local path = mp.get_property("path")
    local fileclass = get_file_class(filename)
    
    M.log("info", "SNAP: Snapping file:", path)

    if fileclass == "unrecognised" then
        M.log("warn", "SNAP: Unrecognized file type for snap:", filename)
        send_OSD("Unrecognised file type: "..path, 2)
        return
    end
    
    local CALL_OS = nil
    
    if fileclass == "edl" then
        local chapter = mp.get_property_native("chapter")
        local record_number = chapter or 0
        local edl_record = get_the_edl_record(mp.get_property_native("path"), record_number)
        
        local fnam = Split(edl_record, ",")
        local file_name_only = fnam[1]
        local start_time = fnam[2] 
        
        CALL_OS = "mpv --screen=0 --fs-screen=0 --volume=10 --start="..start_time..' "'..file_name_only..'"'
        
    elseif fileclass == "video" or fileclass == "audio" then
        local start_second = get_safe_time_pos()
        local file_name_only = path:gsub("\\","/")
        
        CALL_OS = "mpv --screen=0 --fs-screen=0 --volume=10 --start="..start_second..' "'..file_name_only..'"'
    end

    if CALL_OS then
        M.log("info", "SNAP: Executing OS command:", CALL_OS)
        send_OSD("Snapping to new MPV instance...", 2)
        
        mp.command("keypress SPACE")
        
        local SNAP_LOG_FILE = "/tmp/mpv_snap_log_" .. os.time() .. ".log"
        local background_command = string.format(
            "nohup %s > %s 2>&1 &",
            CALL_OS,
            SNAP_LOG_FILE
        )
        os.execute(background_command)
    end
end

function M.goldKey()
    M.log("info", "GOLD: Gold Key pressed.")
    local filename = mp.get_property("filename")
    local path = mp.get_property("path")
    local fileclass = get_file_class(filename)
    local record = nil
    local gold_file = SNITCH_DIR and (SNITCH_DIR.."/goldVault.edl") or nil

    if not gold_file then
        M.log("error", "GOLD FAILED: BCHU (SNITCH_DIR) not set.")
        send_OSD("Gold Key failed: SNITCH_DIR missing.", 3)
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
        send_OSD("Gold Keyed: wrote record to goldVault.edl", 2)
        M.log("info", "GOLD: Wrote record:", record)
    else
        M.log("error", "GOLD FAILED: Cannot open goldVault.edl")
        send_OSD("Gold Key failed: cannot write file", 3)
    end
    
    mp.command("playlist-next")
end


-- --- Context Detection Logic ---

local function detect_execution_context()
    local playlist_count = mp.get_property_number("playlist-count") or 0
    
    if playlist_count > 1 then
        local first_item_path = mp.get_property("playlist/0/filename") or ""
        if first_item_path:match("%.edl$") then
            execution_context = "EDL_PLAYLIST"
        else
            execution_context = "M3U_OR_FOLDER_PLAYLIST"
        end
    elseif playlist_count == 1 then
        execution_context = "SINGLE_FILE"
    end
    
    M.log("info", "Script initialized. Detected context:", execution_context)
    M.log("info", "Output log file:", LOG_FILE)
end

-- --- MPV Event Hooks ---

function M.capture_and_log_pre_command(command)
    local final_time = get_safe_time_pos()
    local duration = get_safe_duration()

    if current_file_path ~= "N/A" and final_time > 0 then
        M.log("warn", "COMMAND INTERCEPTED: ", command, "!")
        M.log("warn", "PRE-SKIP CAPTURE: File:", current_file_path)
        M.log("warn", "PRE-SKIP CAPTURE: Time played:", final_time, "s /", duration, "s")
        previous_file_duration = final_time
    end
end

function M.on_client_command(name, command)
    local commands_to_intercept = {
        ["playlist-next"] = true,
        ["playlist-prev"] = true,
        ["quit"] = true,
        ["stop"] = true,
    }

    if commands_to_intercept[command[1]] then
        M.capture_and_log_pre_command(command[1])
    end
end

function M.start_file()
    M.log("info", "START_FILE: New file loading...")
    current_file_path = "N/A"
end

function M.file_loaded()
    current_file_path = mp.get_property("path") or "N/A"
    local duration = get_safe_duration()
    local filename = mp.get_property("filename") or ""
    local fileclass = get_file_class(filename)
    
    M.log("info", "FILE_LOADED: Path:", current_file_path)
    M.log("info", "FILE_LOADED: Total duration is", duration, "s.")
    
    -- --- VO FIX: Force video output for audio-only files (Final, Non-File I/O Fix) ---
    if fileclass == "audio" and not mp.get_property_native("vid") then
        -- Use options-add on the 'vo' property to load a virtual video output driver.
        -- This is the Lua equivalent of --vo-add null, forcing the VO window open.
        mp.commandv("options-add", "vo", "null") 
        M.log("info", "AUDIO_FIX: Null VO driver loaded via options-add to stabilize input.")
        
        -- Since adding a VO driver might briefly interrupt playback, we ensure it resumes.
        mp.add_timeout(0, function()
            mp.command("set pause no") 
        end)
    end
    -- --- END VO FIX ---

    if previous_file_duration > 0 then
        M.log("info", "CONTEXT: Previous file played for a max of", previous_file_duration, "s.")
    else
        M.log("info", "CONTEXT: No reliable duration recorded for previous file.")
    end
    
    previous_file_duration = 0 
end

function M.end_file(event)
    local reason = event.reason or "unknown"
    local final_time = get_safe_time_pos()
    local media_duration = get_safe_duration()
    
    M.log("info", "END_FILE: Reason:", reason, "| Last time-pos:", final_time, "s | Media Duration:", media_duration, "s")

    if previous_file_duration == 0 then
        if reason == "eof" or reason == "redirect" then
            previous_file_duration = media_duration
            M.log("info", "CONTEXT CAPTURE: File finished playing completely.")
        else
            previous_file_duration = final_time
            M.log("info", "CONTEXT CAPTURE: File skipped by unknown means. Final recorded play time is:", previous_file_duration, "s.")
        end
    end
end

function M.chapter_change(name, value)
    local chapter_title = mp.get_property("chapter-list/"..tostring(value).."/title") or "N/A"
    M.log("info", "CHAPTER_CHANGE: Chapter", value, "at", get_safe_time_pos(), "s. Title:", chapter_title)
end


-- --- EXECUTION FLOW ---

local ok, err = pcall(function()

    detect_execution_context()

    -- 2. Register MPV Hooks
    M.log("info", "EXECUTION: Registering hooks.")
    mp.add_hook("on_client_command", 90, M.on_client_command)
    mp.register_event("start-file", M.start_file)
    mp.register_event("file-loaded", M.file_loaded)
    mp.register_event("end-file", M.end_file)

    M.log("info", "EXECUTION: Observing chapter property.")
    mp.observe_property("chapter", "number", M.chapter_change)

    -- NEW: Defer key binding registration to the next event loop iteration (0ms delay)
    M.log("info", "EXECUTION: Deferring key bindings to next event loop.")
    
    mp.add_timeout(0, function()
        
        -- 3. Key bindings
        M.log("info", "DEFERRED: Setting key bindings now (Final Robust Bindings).")
        
        -- Use anonymous functions to wrap every action for robust function reference
        mp.add_key_binding("n", "user-skip-next", function() mp.command("playlist-next") end, {repeatable=false, force=true})
        mp.add_key_binding("KP1", "start_cut", function() M.start_cut() end, {repeatable=false, force=true})
        mp.add_key_binding("KP2", "end_cut", function() M.end_cut() end, {repeatable=false, force=true})
        mp.add_key_binding("KP0", "snap_SNITCH", function() M.snap_SNITCH() end, {repeatable=true, force=true})
        mp.add_key_binding("g", "goldKey", function() M.goldKey() end, {repeatable=true, force=true})
        
        M.log("info", "DEFERRED: All key bindings set successfully.")
        
        script_is_loaded = true 
        M.log("info", "Script loaded successfully.")
    end)
    
end)

if not ok then
    local err_message = "SCRIPT LOAD ERROR: " .. tostring(err)
    msg.error(err_message)
    local timestamp = os.date("%H:%M:%S")
    local log_message = timestamp .. " [ERROR] " .. err_message
    local log_handle, err = io.open(LOG_FILE, "a")
    if log_handle then
        log_handle:write(log_message .. "\n")
        log_handle:close()
    end
end

return M