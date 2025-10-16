-- mpv_history_logger_v2.lua
-- Goal: Add EDL cutting (start/end cut) functionality using key bindings (KP1/KP2).
-- Includes robust logging, context detection, and command interception.

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
local io = io -- Added io dependency for file operations

-- --- Configuration & Constants ---

-- STRICTLY REQUIRED ENVIRONMENT VARIABLES (Used by cutting/snitching)
-- NOTE: In a final script, these should be checked, but we assume they are set for now.
local SNITCH_DIR = os.getenv("BCHU")
local EDL_SNITCH_JOURNAL = SNITCH_DIR and (SNITCH_DIR.."/edl_journal.edl") or nil
local NON_EDL_JOURNAL = SNITCH_DIR and (SNITCH_DIR.."/m3u_journal.m3u") or nil
local DITCHED_FILE_PATH = os.getenv("EDLSRC") and (os.getenv("EDLSRC").."/ditched.txt") or nil
local SNITCH_SEGMENT_LENGTH = 30 -- Used in your original SNITCH_file function

local LOG_FILE = "/tmp/mpv_history_logger.log"

-- Internal State Variables
local execution_context = "UNKNOWN"
local previous_file_duration = 0
local current_file_path = "N/A"
local g_start_second = 0 -- Stores the start time for the current cut segment

-- --- Utility Functions ---

function M.log(level, ...)
    local timestamp = os.date("%H:%M:%S")
    local parts = {}
    for i, v in ipairs({...}) do
        parts[i] = tostring(v)
    end
    local message = table.concat(parts, ' ')
    -- Use mp.msg for terminal output
    if level == "error" then
        msg.error("[LOGGER/"..timestamp.."] " .. message)
    else
        msg.info("[LOGGER/"..timestamp.."] " .. message)
    end
    -- Also log to file for persistence
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

local VIDEO_EXTENSIONS = {
    ["mkv"] = true, ["mp4"] = true, ["avi"] = true, ["webm"] = true, 
    ["wmv"] = true, ["mov"] = true, ["flv"] = true, ["ts"] = true
}
local AUDIO_EXTENSIONS = {
    ["mp3"] = true, ["m4a"] = true, ["flac"] = true, ["wav"] = true, 
    ["ogg"] = true, ["aac"] = true
}

local function get_file_class(filename)
    -- ... (Extension parsing remains the same) ...
    local ext_with_dot = filename:match("^.+(%..+)$")
    local ext = ext_with_dot and string.lower(ext_with_dot:sub(2))
    
    if not ext then return "unrecognised" end
    
    M.log("info", "Parsed extension:", ext)

    if ext == "edl" then 
        return "edl" 
    elseif VIDEO_EXTENSIONS[ext] then
        return "video"
    elseif AUDIO_EXTENSIONS[ext] then
        return "audio"
    -- Add image lookup if needed
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
            M.log("info", "Created new EDL:", bfile)
            return true
        else
            M.log("error", "Failed to create EDL file:", bfile);
            return false
        end
    end
    return true
end

local function day_journal(record)
    local DAY_journal_name = "/tmp/edl_day_journal.edl"
    create_edl_if_missing(DAY_journal_name)
    local DAY_handle = io.open(DAY_journal_name, "a")
    if DAY_handle then
        DAY_handle:write(record)
        DAY_handle:close()
    else
        M.log("error", "Failed to open day journal.")
    end
end

local function write_that_SNITCH(SNITCHfilename, record, journal_type, path)
    
    local SNITCH_handle = io.open(SNITCHfilename, "a")
    if not SNITCH_handle then
        M.log("error", "Failed to open SNITCH file for writing:", SNITCHfilename)
        return
    end
    
    SNITCH_handle:write(record)
    SNITCH_handle:close()

    if journal_type == "edl" and EDL_SNITCH_JOURNAL then
        create_edl_if_missing(EDL_SNITCH_JOURNAL)
        local journal_handle = io.open(EDL_SNITCH_JOURNAL,"a")
        if journal_handle then
            journal_handle:write(record)
            journal_handle:close()
        end
        -- Note: Skipping USCR_CMD logic as it requires external context not provided.
    elseif journal_type == "non_edl" and NON_EDL_JOURNAL then
        local journal_handle = io.open(NON_EDL_JOURNAL,"a")
        if journal_handle then
            journal_handle:write(record)
            journal_handle:close()
        end
    end

    local message_string = path:gsub("\\","/")
    send_OSD("SNITCHED: "..message_string, 3)
end

-- --- Cutting/EDL Functions ---

local function valid_for_cutting()
    local filename = mp.get_property("filename") or ""
    local fileclass = get_file_class(filename)
    -- Log the determined file class
    M.log("info", "Determined file class for cutting:", fileclass)
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
    local stop_second = current_time_pos - g_start_second
    
    if stop_second <= 0 then
        M.log("warn", "CUT: End time is before or same as start time. Cut aborted.")
        send_OSD("End time is before or same as start time. Cut aborted.", 3)
        g_start_second = 0
        return
    end

    local path = mp.get_property("path")
    local str_record = path..","..g_start_second..","..stop_second.."\n"

    -- Define the output EDL file path
    local SNITCHfilename = "manual_cut_"..os.date('%d_%m_%y_%H')..".edl"
    local SNITCH_file = SNITCH_DIR and (SNITCH_DIR.."/"..SNITCHfilename) or nil
    
    if not SNITCH_file then
        M.log("error", "CUT FAILED: BCHU environment variable (SNITCH_DIR) not set.")
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
    
    M.log("info", "FILE_LOADED: Path:", current_file_path)
    M.log("info", "FILE_LOADED: Total duration is", duration, "s.")
    
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

detect_execution_context()

-- 2. Register MPV Hooks
mp.add_hook("on_client_command", 90, M.on_client_command)
mp.register_event("start-file", M.start_file)
mp.register_event("file-loaded", M.file_loaded)
mp.register_event("end-file", M.end_file)

mp.observe_property("chapter", "number", M.chapter_change)

-- 3. Key bindings
mp.add_key_binding("n", "user-skip-next", function() mp.command("playlist-next") end, {repeatable=false})
mp.add_key_binding("KP1", "start_cut", M.start_cut, {repeatable=false})
mp.add_key_binding("KP2", "end_cut", M.end_cut, {repeatable=false})

M.log("info", "Script loaded successfully.")

return M