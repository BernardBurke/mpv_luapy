-- mpv_utilities.lua
-- Final version with VO stabilization and recursion guard (Fix-and-Exit method).

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

-- REQUIRED ENVIRONMENT VARIABLES
local SNITCH_DIR = os.getenv("BCHU")
local HI_DIR = os.getenv("HI") 
local EDL_SNITCH_JOURNAL = SNITCH_DIR and (SNITCH_DIR.."/edl_journal.edl") or nil
local NON_EDL_JOURNAL = SNITCH_DIR and (SNITCH_DIR.."/m3u_journal.m3u") or nil
local DITCHED_FILE_PATH = os.getenv("EDLSRC") and (os.getenv("EDLSRC").."/ditched.txt") or nil
local SNITCH_SEGMENT_LENGTH = 30 
local MPVL_DIR_RAW = os.getenv("MPVL") or ""
local MPVL_DIR = MPVL_DIR_RAW:match("(.+[^/])$") or MPVL_DIR_RAW 
local EMBED_COVER_SCRIPT = MPVL_DIR and (MPVL_DIR.."/embed_cover.sh") or nil

-- Internal State Variables
local execution_context = "UNKNOWN"
local previous_file_duration = 0
local current_file_path = "N/A"
local g_start_second = 0 
local script_is_loaded = false 
local VO_FIX_NEEDED = false 
local keybindings_set = false 

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
    
    if script_is_loaded or level == "error" then
        if level == "error" then
            msg.error("[LOGGER/"..timestamp.."] " .. message)
        else
            msg.info("[LOGGER/"..timestamp.."] " .. message)
        end
    end
    
    local log_message = timestamp .. " [" .. string.upper(level) .. "] " .. message
    local log_handle, err = io.open(LOG_FILE, "a")
    if log_handle then
        log_handle:write(log_message .. "\n")
        log_handle:close()
    end
end

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

local function get_file_class(filepath)
    if not filepath then return "unrecognised" end

    -- First, check by file extension, which is fast.
    local ext_with_dot = filepath:match("^.+(%..+)$")
    local ext = ext_with_dot and string.lower(ext_with_dot:sub(2))
    
    if not ext then
        -- If no extension, check content for EDL header
        local f = io.open(filepath, "rb")
        if f then
            local line = f:read("*l")
            f:close()
            if line and line:match("^# mpv EDL v0") then
                return "edl"
            end
        end
        return "unrecognised"
    end
    
    if ext == "edl" then return "edl" 
    elseif VIDEO_EXTENSIONS[ext] then
        return "video"
    elseif AUDIO_EXTENSIONS[ext] then
        return "audio"
    end

    -- If extension is not recognized, as a last resort, check file content for EDL.
    local f = io.open(filepath, "rb")
    if f then
        local line = f:read("*l")
        f:close()
        if line and line:match("^# mpv EDL v0") then
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

-- Reads an EDL file and retrieves a specific record by its line number (0-indexed chapter).
local function get_the_edl_record(edl_path, chapter_number)
    M.log("info", "EDL_READ: Reading record " .. tostring(chapter_number) .. " from: " .. edl_path)

    if not edl_path or not file_exists(edl_path) then
        M.log("error", "EDL_READ: File not found or path is nil:", edl_path)
        return nil
    end

    local lines = {}
    local ok, err = pcall(function()
        for line in io.lines(edl_path) do
            if not line:match("^#") then
                table.insert(lines, line)
            end
        end
    end)

    if not ok then
        M.log("error", "EDL_READ: Failed to read file content:", edl_path, "Error:", err)
        return nil
    end

    return lines[chapter_number + 1]
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
    local path = mp.get_property("path") or ""
    local fileclass = get_file_class(path)
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
    local path = mp.get_property("path")
    local fileclass = get_file_class(path)
    
    M.log("info", "SNAP: Snapping file:", path)

    if fileclass == "unrecognised" then
        M.log("warn", "SNAP: Unrecognized file type for snap:", path)
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
    local path = mp.get_property("path")
    local fileclass = get_file_class(path)
    local record = nil
    local gold_file = HI_DIR and (HI_DIR.."/goldVaultCurrent.edl") or nil

    if not gold_file then
        M.log("error", "GOLD FAILED: HI_DIR (SNITCH_DIR) not set.")
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

-- --- VO STABILITY HOOK (The final fix for keypad input) ---
function M.on_load_start(hook)
    local path = mp.get_property("path") or ""
    local fileclass = get_file_class(path)
    
    if fileclass == "audio" then
        VO_FIX_NEEDED = true
    else
        VO_FIX_NEEDED = false
    end
end

-- --- VO STABILITY EXECUTION (Runs after metadata is loaded, before file starts playing) ---
function M.post_file_load()
    if VO_FIX_NEEDED then
        local path = mp.get_property("path") or ""
        
        -- If 'vid' is nil, there is no video stream (i.e., no cover art/VO window open)
        if not mp.get_property_native("vid") then
            
            M.log("warn", "VO_FIX: No video stream detected. Input is unstable. Initiating fix-and-exit.")
            
            -- Check if the Bash script file itself exists (essential safety check)
            if not EMBED_COVER_SCRIPT or not file_exists(EMBED_COVER_SCRIPT) then
                M.log("error", "VO_FIX: Embed script not found. Path: " .. tostring(EMBED_COVER_SCRIPT))
                send_OSD("VO Fix failed: Embed script missing. Cannot fix file.", 3)
            else
                M.log("info", "VO_FIX: Embedding cover art via Bash script (asynchronous).")
                send_OSD("Fixing audio: Embed cover art. Please restart MPV.", 3)
                
                -- Execute Bash script asynchronously (essential for not blocking the quit command)
                os.execute("bash " .. EMBED_COVER_SCRIPT .. " \"" .. path .. "\" &")
                if os.getenv("EMBED_COVER") == "1" then
                    M.log("info", "VO_FIX: Embedding cover art via Bash script (asynchronous).")
                    send_OSD("Fixing audio: Embed cover art. Please restart MPV.", 3)
                    
                    -- Execute Bash script asynchronously (essential for not blocking the quit command)
                    os.execute("bash " .. EMBED_COVER_SCRIPT .. " \"" .. path .. "\" &")

                -- IMMEDIATE EXIT: Quit MPV so the user can reload the now-modified file.
                mp.add_timeout(0.5, function()
                    mp.command("quit") 
                    M.log("info", "VO_FIX: Quitting MPV for user to reload fixed file.")
                end)
                    -- IMMEDIATE EXIT: Quit MPV so the user can reload the now-modified file.
                    mp.add_timeout(0.5, function()
                        mp.command("quit") 
                        M.log("info", "VO_FIX: Quitting MPV for user to reload fixed file.")
                    end)
                else
                    M.log("warn", "VO_FIX: EMBED_COVER is not set to 1. Skipping cover art embedding.")
                    send_OSD("VO Fix skipped: EMBED_COVER not enabled.", 3)
                end
            end
        end
        VO_FIX_NEEDED = false -- Reset flag regardless of outcome
    end
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

-- --- KEY BINDING SETUP FUNCTION (Stable Location) ---
local function setup_keybindings()
    if keybindings_set then return end 

    M.log("info", "KEY_SETUP: Executing final key binding setup.")

    -- 3. Key bindings
    mp.add_key_binding("n", "user-skip-next", function() mp.command("playlist-next") end, {repeatable=false, force=true})
    mp.add_key_binding("KP1", "start_cut", function() M.start_cut() end, {repeatable=false, force=true})
    mp.add_key_binding("KP2", "end_cut", function() M.end_cut() end, {repeatable=false, force=true})
    mp.add_key_binding("KP0", "snap_SNITCH", function() M.snap_SNITCH() end, {repeatable=true, force=true})
    mp.add_key_binding("g", "goldKey", function() M.goldKey() end, {repeatable=true, force=true})

    keybindings_set = true
    M.log("info", "KEY_SETUP: All key bindings successfully registered.")
    
    -- Final mark as loaded only after all deferred actions are queued
    script_is_loaded = true 
    M.log("info", "Script loaded successfully.")
end

-- --- MPV Event Hooks (Standard) ---

function M.file_loaded()
    current_file_path = mp.get_property("path") or "N/A"
    local duration = get_safe_duration()
    
    M.log("info", "FILE_LOADED: Path:", current_file_path)
    M.log("info", "FILE_LOADED: Total duration is", duration, "s.")
    
    -- Call the new post-load check here
    M.post_file_load() 

    if previous_file_duration > 0 then
        M.log("info", "CONTEXT: Previous file played for a max of", previous_file_duration, "s.")
    else
        M.log("info", "CONTEXT: No reliable duration recorded for previous file.")
    end
    
    -- Defer keybinding setup to the end of the file load process (only runs once)
    if not keybindings_set then
        mp.add_timeout(0, setup_keybindings)
    end
    
    previous_file_duration = 0 
end

function M.start_file()
    M.log("info", "START_FILE: New file loading...")
    current_file_path = "N/A"
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

    -- Check required environment variable presence (Only checking for presence, not directory validity)
    if not MPVL_DIR_RAW or MPVL_DIR_RAW == "" then
        msg.error("FATAL: MPVL environment variable is not set. Cannot run utility.")
        return
    end
    
    detect_execution_context()

    -- 2. Register MPV Hooks
    M.log("info", "EXECUTION: Registering hooks.")
    mp.add_hook("on_client_command", 90, M.on_client_command)
    
    mp.add_hook("on_load", 90, M.on_load_start) 
    
    mp.register_event("start-file", M.start_file)
    mp.register_event("file-loaded", M.file_loaded)
    mp.register_event("end-file", M.end_file)

    M.log("info", "EXECUTION: Observing chapter property.")
    mp.observe_property("chapter", "number", M.chapter_change)
    
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