-- time_pos_file_logger.lua
-- Focuses purely on MPV event timing and reliable time capture, using a text file
-- as the persistent store instead of SQLite.

local M = {}

-- Standard dependencies
local mp = require('mp')
local msg = require('mp.msg')
local os = os
local string = string
local tonumber = tonumber
local io = io
local math = math

-- --- Configuration & Constants ---
local LOG_FILE_PATH = "/tmp/mpv_history_log.txt"
local SAVE_INTERVAL_SECONDS = 30 -- Log position every 30 seconds

-- Internal State Variables
local save_timer = nil
local is_file_active = false 
-- CRITICAL: Stores the last reliable time from the periodic timer.
local last_known_time = 0 
local current_file_path = "N/A"
local current_file_id = 0 -- Simple counter for file tracking

-- --- Centralized Logging & File Writing ---

function M.log(level, ...)
    local message = table.concat({...}, ' ')
    if level == "error" then
        msg.error("[LOGGER] " .. message)
    else
        msg.info("[LOGGER] " .. message)
    end
end

-- Function to simulate the database save by writing to a file.
-- This function is the ONLY one that writes persistent data.
local function persist_time_position(file_path, time_pos, reason)
    if time_pos <= 0 or file_path == "N/A" then
        M.log("info", "PERSIST SKIPPED: Time is zero or file is invalid. Time:", time_pos)
        return
    end

    local log_handle, err = io.open(LOG_FILE_PATH, "a")
    if log_handle then
        local log_message = string.format(
            "%s | ID: %d | TIME: %d | DATE: %s | REASON: %s\n",
            file_path,
            current_file_id,
            time_pos,
            os.date("%Y-%m-%d %H:%M:%S"),
            reason
        )
        log_handle:write(log_message)
        log_handle:close()
        M.log("info", "PERSIST SUCCESS: Saved", time_pos, "s for ID:", current_file_id, "by", reason)
    else
        M.log("error", "Failed to open log file:", LOG_FILE_PATH, "Error:", err)
    end
end

-- --- Time Position Capture Logic ---

function M.capture_and_save(is_forced_capture)
    local current_pos
    local reason_str

    if is_forced_capture then
        -- FINAL CAPTURE (on_unload, pause, chapter): Use the last known time.
        current_pos = last_known_time
        reason_str = "FINAL/FORCED"
    else
        -- PERIODIC TIMER CAPTURE: Sample MPV property directly.
        local time_pos = mp.get_property_number("time-pos")
        if time_pos == nil or time_pos < 0 or mp.get_property_bool("paused") then
            return -- Skip if property is invalid or paused
        end
        current_pos = math.floor(time_pos)
        reason_str = "PERIODIC"
    end

    -- Update the global known time only if we have a valid time > 0.
    if current_pos > 0 then
        last_known_time = current_pos
    end

    -- Persist to file if this is a FORCED CAPTURE (most critical) or if it's the PERIODIC CAPTURE.
    if is_forced_capture or reason_str == "PERIODIC" then
        persist_time_position(current_file_path, current_pos, reason_str)
    end
end

function M.periodic_save_timer()
    -- This function is called repeatedly by the MPV timer.
    M.capture_and_save(false)
end

function M.stop_periodic_save()
    if save_timer then 
        save_timer:stop() 
        save_timer = nil
        M.log("info", "Stopped periodic save timer.")
    end
end

function M.start_periodic_save()
    if save_timer then 
        M.log("info", "Periodic save timer already running.")
        return 
    end
    save_timer = mp.add_periodic_timer(SAVE_INTERVAL_SECONDS, M.periodic_save_timer)
    M.log("info", "Started periodic save timer at", SAVE_INTERVAL_SECONDS, "seconds.")
end

function M.on_pause_change(name, is_paused)
    if not is_file_active then return end
    
    if is_paused then
        M.log("info", "Playback paused. Forcing capture/persist.")
        M.stop_periodic_save()
        M.capture_and_save(true)
    else
        M.log("info", "Playback resumed. Starting periodic save timer.")
        M.start_periodic_save()
    end
end

-- --- MPV Event Hooks ---

function M.start_file()
    M.log("info", "--- START FILE EVENT ---")
    current_file_id = current_file_id + 1
    M.stop_periodic_save() 
    is_file_active = false
    
    last_known_time = 0 -- Reset the source of truth for the new file
end

function M.file_loaded()
    is_file_active = true
    current_file_path = mp.get_property("path") or "N/A"
    
    -- Try to capture mpv's restored time (if applicable), or set to 0.
    local initial_time_pos = math.floor(mp.get_property_number("time-pos") or 0)
    last_known_time = initial_time_pos 

    M.log("info", "FILE LOADED: Initial time is", initial_time_pos)

    -- If playback starts immediately, start the timer.
    if not mp.get_property_bool("paused") then
         M.start_periodic_save()
    end
end

function M.on_unload()
    M.log("info", "--- UNLOAD EVENT (Final Capture) ---")
    
    M.stop_periodic_save() 
    
    if is_file_active then
        -- This is the final, most important save: Use the last known time.
        M.capture_and_save(true)
    end
    is_file_active = false
    current_file_path = "N/A"
end

-- Chapter hook for forcing saves (can be used to track mid-file saves)
function M.new_chapter()
    M.capture_and_save(true)
end

function M.shutdown()
    M.on_unload() 
    M.log("info", "Shutdown complete.")
end

-- --- EXECUTION FLOW ---

mp.register_event("start-file", M.start_file)
mp.register_event("file-loaded", M.file_loaded)
mp.add_hook("on_unload", 50, M.on_unload) 
mp.register_event("shutdown", M.shutdown)

mp.observe_property("pause", "bool", M.on_pause_change)
mp.observe_property("chapter", "number", M.new_chapter)

M.log("info", "Time Position File Logger loaded. Check: " .. LOG_FILE_PATH)

return M