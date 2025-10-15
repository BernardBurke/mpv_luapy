-- time_pos_debugger.lua
-- A debugging script to explore MPV event timing and the reliability of 'time-pos'.

local mp = require('mp')
local msg = require('mp.msg')
local math = math

local M = {}

-- Global state
local current_file_id = 0
local periodic_timer = nil
local PERIODIC_LOG_INTERVAL = 5 -- Log time-pos every 5 seconds while playing.

-- --- Utility Functions ---

-- Central logging function to consistently retrieve and log time_pos
local function log_time_pos(source_event, force_sample)
    if not mp.get_property_bool("core-idle") or force_sample then
        local time_pos = mp.get_property_number("time-pos")
        local duration = mp.get_property_number("duration")
        local is_paused = mp.get_property_bool("pause") or false
        local status = time_pos and math.floor(time_pos) or "nil"
        local file_status = mp.get_property("path") and "Active" or "Inactive"
        
        -- Only log if the file is active OR if the event is a cleanup event
        if file_status == "Active" or source_event == "ON_UNLOAD" or source_event == "SHUTDOWN" then
            msg.info(string.format(
                "[DEBUG_%d] | %-12s | Time: %-5s | Paused: %-5s | File Status: %s",
                current_file_id,
                source_event,
                tostring(status),
                tostring(is_paused),
                file_status
            ))
        end
        return status
    end
end

-- Timer callback for periodic logging
local function periodic_log_timer()
    log_time_pos("PERIODIC_TIMER", false)
end

local function stop_timer()
    if periodic_timer then
        periodic_timer:stop()
        periodic_timer = nil
        msg.warn("[DEBUG] Timer stopped.")
    end
end

local function start_timer()
    if not periodic_timer then
        periodic_timer = mp.add_periodic_timer(PERIODIC_LOG_INTERVAL, periodic_log_timer)
        msg.warn("[DEBUG] Timer started.")
    else
        msg.info("[DEBUG] Timer is already active.")
    end
end

-- --- MPV Event Callbacks ---

-- Called when a new file begins loading (before file-loaded)
function M.start_file()
    current_file_id = current_file_id + 1
    msg.info("==============================================")
    log_time_pos("START_FILE", true)
    stop_timer() -- Always stop any running timer from the previous file
end

-- Called when file properties (duration, audio/video streams) are available
function M.file_loaded()
    log_time_pos("FILE_LOADED", true)
    
    -- Immediately start the timer if not paused (MPV default behaviour)
    if not mp.get_property_bool("pause") then
        start_timer()
    end
end

-- Called when playback is about to end (e.g., end of file, playlist-next)
function M.end_file(event)
    log_time_pos("END_FILE", true)
    stop_timer() -- Stop the timer immediately when the file ends
end

-- Called when the user presses pause/play (or if MPV auto-pauses)
function M.on_pause_change(name, is_paused)
    if is_paused then
        -- On pause, force an immediate log/save, then stop the timer
        log_time_pos("PAUSED_TRUE", true)
        stop_timer()
    else
        -- On resume, log, and restart the timer
        log_time_pos("PAUSED_FALSE", true)
        start_timer()
    end
end

-- Called by on_unload hook (highest priority, should capture final time)
function M.on_unload()
    -- This is the critical, final capture point before closing the file handle
    log_time_pos("ON_UNLOAD", true)
    stop_timer()
end

-- Called when MPV is shutting down completely (after on_unload)
function M.shutdown()
    log_time_pos("SHUTDOWN", true)
    -- Timer should already be stopped by M.on_unload()
end

-- Custom user command to simulate your original 'cut' functions
function M.manual_capture()
    log_time_pos("MANUAL_CMD", true)
end

-- --- EXECUTION FLOW ---

-- 1. Register MPV Hooks

-- File/Playlist Events
mp.register_event("start-file", M.start_file)
mp.register_event("file-loaded", M.file_loaded)
mp.register_event("end-file", M.end_file)

-- Cleanup Hooks (ordered priority)
-- on_unload is generally the best place for a *final* database write
mp.add_hook("on_unload", 99, M.on_unload) 
mp.register_event("shutdown", M.shutdown)

-- Property Observers (Responsive to state changes)
mp.observe_property("pause", "bool", M.on_pause_change) 
-- Note: 'time-pos' is too high frequency to observe directly for saving.

-- Key binding to test manual capture (like start_cut/end_cut)
mp.add_key_binding("c", "manual_capture", M.manual_capture, {repeatable=false})

msg.warn("[DEBUG] time_pos_debugger.lua loaded. Press 'c' to manually sample.")

return M