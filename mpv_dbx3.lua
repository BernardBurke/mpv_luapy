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

-- --- Centralized Logging & File Writing ---

function M.log(level, ...)
    local message = table.concat({...}, ' ')
    if level == "error" then
        msg.error("[LOGGER] " .. message)
    else
        msg.info("[LOGGER] " .. message)
    end
end

function initialise()


M.log("info", "Initialising dbx3")
mp.set_property("osd-align-y","bottom")
mp.set_property("osd-align-x","center")
--mp.set_property("volume",20)
--mp.set_property("screen",0)
--mp.set_property("fullscreen")
--mp.set_property("fs-screen",0)

print("Good morning")

end
-- --- MPV Event Hooks ---

function M.start_file()
    M.log("info", "--- START FILE EVENT ---")

end

function M.file_loaded()
    current_file_path = mp.get_property("path") or "N/A"
    

    M.log("info", "FILE LOADED: Initial time is", current_file_path)

    
end

function M.on_unload()
    M.log("info", "--- UNLOAD EVENT (Final Capture) ---")
        
end

-- Chapter hook for forcing saves (can be used to track mid-file saves)
function M.new_chapter()
    M.log("info", "--- NEW CHAPTER EVENT ---")
    
end

function M.shutdown()
    M.on_unload() 
    M.log("info", "Shutdown complete.")
end



function file_exists(file)
    local f = io.open(file, "rb")
    if f then f:close() end
    return f ~= nil
end




 
function file_type(fname)
    --print("In file_type "..mp.get_property(""))
    --local fpath=mp.get_property("path")
    return fname:match "[^.]+$"

end

function Split(s, delimiter)
    result = {};
    for match in (s..delimiter):gmatch("(.-)"..delimiter) do
        table.insert(result, match);
    end
    return result;
end

function isTemp()
    local pathstr=mp.get_property_native("path")
    if string.find(pathstr,"/tmp/tmp.") then
        return true
    else
        return false
    end
end

function isEDL()
    local pathstr=mp.get_property_native("path")
    local fhandle = io.open(pathstr,"r")
    local firstLine = fhandle:read()
    fhandle:close()
    if string.find("# mpv EDL v0",firstLine) then
        return true
    else
        return false
    end
end

function file_type(fname)
    --print("In file_type "..mp.get_property(""))
    if isTemp() then
        if isEDL(fname) then
            return "edl"
        else
            return "m3u"
        end
        --print("I am a temporary file")

    end
    return fname:match "[^.]+$"

end

function get_file_class(filename)
    local afterthedot = file_type(filename)
    local firstchars = string.sub(afterthedot,1,3)

    print("afterthedot "..afterthedot)
    print("firstchars "..firstchars)

    local mediaclass = nil
    if firstchars == "edl" then 
        mediaclass = "edl"
    end

    if firstchars == "mkv" or firstchars == "mp4" or firstchars == "avi" or firstchars == "web" or firstchars == "wmv" then 
        mediaclass = "video"
    end

    if firstchars == "jpg" or firstchars == "png" or firstchars == "gig" then 
        mediaclass = "image"
    end

    if firstchars == "mp3" or firstchars == "m4a" then
        mediaclass = "audio"
    end

    if mediaclass == nil then
        mediaclass = "unrecognised"
    end

    return mediaclass
end
-- --- EXECUTION FLOW ---

mp.register_event("start-file", M.start_file)
mp.register_event("file-loaded", M.file_loaded)
mp.add_hook("on_unload", 50, M.on_unload) 
mp.register_event("shutdown", M.shutdown)

--mp.observe_property("pause", "bool", M.on_pause_change)
mp.observe_property("chapter", "number", M.new_chapter)
mp.set_property("osd-align-y", "bottom")
mp.set_property("osd-align-x", "center")


mp.add_key_binding("D", "toggle_ditch_snitch", M.toggle_ditch_snitch, {repeatable=true})
mp.add_key_binding("MBTN_Right", "ditch_or_snitch", M.ditch_or_snitch, {repeatable=true})
mp.add_key_binding("KP1", "start_cut", M.start_cut, {repeatable=true})
mp.add_key_binding("KP2", "end_cut", M.end_cut, {repeatable=true})
mp.add_key_binding("Ctrl+DEL", "deleteMe", M.delete_me, {repeatable=true})

M.log("info", "dbx3 loaded. Check: " .. LOG_FILE_PATH)



return M



