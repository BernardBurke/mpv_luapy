-- mpv_history_logger_v1.lua (Updated with Command Interception)
-- Goal: Capture execution context (single file, playlist, EDL) and essential file lifecycle events.

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

-- --- Configuration & Constants ---

-- Configuration that determines run context type
local LOG_FILE = "/tmp/mpv_history_logger.log"

-- Internal State Variables
local execution_context = "UNKNOWN"
local previous_file_duration = 0  -- Stores the duration of the *just finished* file (in seconds)
local current_file_path = "N/A"

-- --- Utility Functions ---

function M.log(level, ...)
    local timestamp = os.date("%H:%M:%S")
    local parts = {}
    for i, v in ipairs({...}) do
        -- Convert everything to a string, and use "nil" for actual nil values.
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

-- Helper to safely get properties
local function get_safe_time_pos()
    local t = mp.get_property_number("time-pos")
    return t and math.floor(t) or 0
end

local function get_safe_duration()
    local d = mp.get_property_number("duration")
    return d and math.floor(d) or 0
end

-- --- Context Detection Logic ---

-- This function runs once at script start to determine the type of input.
local function detect_execution_context()
    local playlist_count = mp.get_property_number("playlist-count") or 0
    local input_path = mp.get_property("path") or ""

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

-- **NEW GENERIC SAVE FUNCTION**
function M.capture_and_log_pre_command(command)
    local final_time = get_safe_time_pos()
    local duration = get_safe_duration()

    -- We only care about captures if a file is actually loaded
    if current_file_path ~= "N/A" and final_time > 0 then
        -- This logic is now centralized and runs BEFORE the command is executed
        M.log("warn", "COMMAND INTERCEPTED: ", command, "!")
        M.log("warn", "PRE-SKIP CAPTURE: File:", current_file_path)
        M.log("warn", "PRE-SKIP CAPTURE: Time played:", final_time, "s /", duration, "s")
        
        -- Store the final time played, which will be logged in file_loaded of the next file
        previous_file_duration = final_time
    end
end

-- **NEW HOOK FUNCTION**
function M.on_client_command(name, command)
    -- Commands that indicate the file is about to change or MPV is closing
    local commands_to_intercept = {
        ["playlist-next"] = true,
        ["playlist-prev"] = true,
        ["quit"] = true,
        ["stop"] = true,
    }

    if commands_to_intercept[command[1]] then
        -- Run the capture logic first
        M.capture_and_log_pre_command(command[1])
    end
    
    -- The hook automatically lets the command run if we don't return anything.
    -- If we returned mp.HOOK_IGNORED or similar, the command would be blocked.
end

-- --- MPV Event Hooks ---

function M.start_file()
    M.log("info", "START_FILE: New file loading...")
    
    -- Clear properties from the previous file now, before file-loaded runs.
    current_file_path = "N/A"
end

function M.file_loaded()
    current_file_path = mp.get_property("path") or "N/A"
    local duration = get_safe_duration()
    
    M.log("info", "FILE_LOADED: Path:", current_file_path)
    M.log("info", "FILE_LOADED: Total duration is", duration, "s.")
    
    -- Log context of the previous file's activity.
    if previous_file_duration > 0 then
        M.log("info", "CONTEXT: Previous file played for a max of", previous_file_duration, "s.")
    else
        M.log("info", "CONTEXT: No reliable duration recorded for previous file.")
    end
    
    -- Reset for the current file
    previous_file_duration = 0 
end

function M.end_file(event)
    local reason = event.reason or "unknown"
    local final_time = get_safe_time_pos()
    local media_duration = get_safe_duration()
    
    M.log("info", "END_FILE: Reason:", reason, "| Last time-pos:", final_time, "s | Media Duration:", media_duration, "s")

    -- Only update previous_file_duration if it wasn't already set by the COMMAND INTERCEPTOR
    if previous_file_duration == 0 then
        if reason == "eof" or reason == "redirect" then
            -- File completed: Use media duration.
            previous_file_duration = media_duration
            M.log("info", "CONTEXT CAPTURE: File finished playing completely.")
        else
            -- File skipped by unknown means (e.g., MPV internal logic/error).
            previous_file_duration = final_time
            M.log("info", "CONTEXT CAPTURE: File skipped by unknown means. Final recorded play time is:", previous_file_duration, "s.")
        end
    end
end

function M.chapter_change(name, value)
    local chapter_title = mp.get_property("chapter-list/"..tostring(value).."/title") or "N/A"
    M.log("info", "CHAPTER_CHANGE: Chapter", value, "at", get_safe_time_pos(), "s. Title:", chapter_title)
end

-- Removed M.user_skip as interception handles this automatically.

-- --- EXECUTION FLOW ---

-- 1. Run context detection once.
detect_execution_context()

-- 2. Register MPV Hooks
mp.add_hook("on_client_command", 90, M.on_client_command) -- Hook commands BEFORE they execute
mp.register_event("start-file", M.start_file)
mp.register_event("file-loaded", M.file_loaded)
mp.register_event("end-file", M.end_file)

mp.observe_property("chapter", "number", M.chapter_change)

-- 3. Key bindings
-- The 'n' key binding is no longer needed as the built-in 'playlist-next' command is intercepted.
-- If you still want a custom binding:
-- mp.add_key_binding("n", "user-skip-next", function() mp.command("playlist-next") end, {repeatable=false})

M.log("info", "Script loaded successfully.")

return M