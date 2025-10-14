-- mpv_db_handler_v4.lua
-- Includes: Env check, Safe DB path handling (for --no-config), Dir creation, and combined player logic.

local M = {}

-- Standard dependencies
local sqlite3 = require('lsqlite3')
local mp = require('mp')
local utils = require('mp.utils')
local msg = require('mp.msg')
local os = os
local string = string
local tonumber = tonumber
local table = table
local io = io
local math = math

-- --- Configuration: Environment Variables & Constants ---

-- STRICTLY REQUIRED ENVIRONMENT VARIABLES (Checked before script proceeds)
local REQUIRED_ENV_VARS = {
    "BCHU",   -- Used for SNITCH_DIR (EDL/M3U output path)
    "EDLSRC", -- Used for DITCHED_FILE_PATH (directory for ditched.txt)
}

-- Safely determine the default database directory, handling --no-config.
local default_db_path = (function()
    local cfg = mp.find_config_file('.')
    
    if cfg then
        -- Path found (e.g., /home/user/.config/mpv/mpv.conf)
        -- We return the directory name (e.g., /home/user/.config/mpv/)
        return cfg:match("(.*/)[^/]+$") or (cfg .. "/")
    else
        -- Fallback if mp.find_config_file() returns nil (due to --no-config)
        local home = os.getenv("HOME") or os.getenv("USERPROFILE")
        if home then
            -- Fall back to a standard hidden directory in the user's home path
            return home .. "/.mpv_db/"
        else
            -- Last resort: Fall back to /tmp/
            return "/tmp/mpv_db/"
        end
    end
end)()


-- Database paths (These are NOT required as they have robust fallbacks)
local ENV_HISTORY_DB = os.getenv("MPV_HISTORY_DB")
local ENV_LIBRARY_DB = os.getenv("MPV_LIBRARY_DB")

local HISTORY_DB_PATH = ENV_HISTORY_DB or (default_db_path .. 'history.db')
local LIBRARY_DB_PATH = ENV_LIBRARY_DB or (default_db_path .. 'library.db')


-- dbx2.lua constants and environment variables
local SNITCH_DIR = os.getenv("BCHU")
local USCR = os.getenv("USCR")
local subtitles_file = os.getenv("IMGSUBTITLES")

local SNITCH_SEGMENT_LENGTH = 30
local MESSAGE_DISPLAY_TIME_DEFAULT = 15
local DITCH_MODE = os.getenv("DITCH_MODE") and "DITCH" or "SNITCH"
local message_display_time = tonumber(os.getenv("MESSAGE_DISPLAY_TIME")) or MESSAGE_DISPLAY_TIME_DEFAULT

-- File paths (These rely on the REQUIRED_ENV_VARS)
local EDL_SNITCH_JOURNAL = SNITCH_DIR and (SNITCH_DIR.."/edl_journal.edl") or nil
local NON_EDL_JOURNAL = SNITCH_DIR and (SNITCH_DIR.."/m3u_journal.m3u") or nil
local DITCHED_FILE_PATH = os.getenv("EDLSRC") and (os.getenv("EDLSRC").."/ditched.txt") or nil
local LOG_FILE = "/tmp/mpv_db_handler.log" -- Centralized logger file

-- Internal State Variables
local DB_CONNECTIONS = {}
local lines = {} -- For subtitles
local step_count = 1
local line_count = 0
local previous_chapter_time = 0
local g_start_second = 0 -- For cutting
local SUBTITLES_ENABLED = false

-- --- Centralized Logging Function ---
local function log_to_file(message)
    local log_message = os.date("%Y-%m-%d %H:%M:%S") .. " - " .. message
    local log_handle, err = io.open(LOG_FILE, "a")
    if log_handle then
        log_handle:write(log_message .. "\n")
        log_handle:close()
    end
end

function M.log(level, ...)
    local message = table.concat({...}, ' ')
    if level == "error" then
        msg.error("[DB/CTL] " .. message)
    else
        msg.info("[DB/CTL] " .. message)
    end
end

-- --- Module: Environment Check ---
function M.check_environment()
    local missing_vars = {}
    for _, var_name in ipairs(REQUIRED_ENV_VARS) do
        if not os.getenv(var_name) then
            table.insert(missing_vars, var_name)
        end
    end

    if #missing_vars > 0 then
        local error_msg = "FATAL: The following required environment variables are not set: " .. table.concat(missing_vars, ", ")
        M.log("error", error_msg)
        mp.abort_script(error_msg)
        return false 
    end

    return true
end

-- --- Database Utility Functions ---

M.log("info", "History DB Path:", HISTORY_DB_PATH)
M.log("info", "Library DB Path:", LIBRARY_DB_PATH)

-- New Utility: Creates the directory for a file path if it doesn't exist
local function create_dir_if_missing(file_path)
    local dir_path = file_path:match("(.*/)[^/]+$")
    if not dir_path then
        return true
    end

    local status, err = utils.dir_exists(dir_path)
    if status then
        return true
    end

    -- Attempt to create the directory recursively
    local success = os.execute("mkdir -p " .. dir_path)

    if success == 0 or success == true then
        M.log("info", "Created missing database directory:", dir_path)
        return true
    else
        M.log("error", "Failed to create directory:", dir_path, "Error code:", success)
        return false
    end
end


local function open_db(db_path, db_name)
    M.log("info", "Attempting to open DB: " .. db_path)

    -- CRASH PREVENTION: Ensure the directory exists before opening the file
    if not create_dir_if_missing(db_path) then
        mp.abort_script(string.format("%s DB failed to open: Directory creation failed.", db_name))
        return nil, nil, "Directory not found/writable"
    end

    local db_handle, errcode, errmsg = sqlite3.open(db_path)
    if not db_handle then
        M.log("error", db_name, "Failed to open:", errmsg)
        mp.abort_script(string.format("%s DB failed to open: %s", db_name, errmsg))
    end

    DB_CONNECTIONS[db_name] = db_handle
    M.log("info", db_name, "opened successfully.")
    return db_handle
end

local function check_and_create_table(db)
    local check_table = "SELECT name FROM sqlite_master WHERE type='table' AND name='history_item';"
    local table_exists = false
    local cursor = db:exec(check_table)
    
    if cursor then
        table_exists = cursor:fetch() ~= nil
        cursor:close()
    end

    if not table_exists then
        M.log("info", "history_item table not found. Creating it...")
        local create_tables = [[
            CREATE TABLE history_item(
                id          INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                path        TEXT    NOT NULL,
                filename    TEXT    NOT NULL,
                title       TEXT    NOT NULL,
                time_pos    INTEGER,
                date        DATE    NOT NULL
            );
        ]]
        
        local res = db:exec(create_tables)
        if res ~= sqlite3.OK then M.log("error", db:errmsg()); error(db:errmsg()) end
        M.log("info", "history_item table created successfully.")
    end
end

-- --- MPV/File Utility Functions ---

local function send_OSD(message_string, seconds)
    local message_str = mp.get_property("osd-ass-cc/0")..message_string..mp.get_property("osd-ass-cc/1")
    mp.osd_message(message_str, seconds or message_display_time)
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

local function get_file_class(filename)
    local ext = filename:match("^.+(%..+)$")
    if not ext then return "unrecognised" end
    ext = string.lower(ext:sub(2))
    
    if ext == "edl" then return "edl" end
    if ext == "mkv" or ext == "mp4" or ext == "avi" or ext == "webm" or ext == "wmv" then return "video" end
    if ext == "jpg" or ext == "png" or ext == "gif" then return "image" end
    if ext == "mp3" or ext == "m4a" then return "audio" end
    return "unrecognised"
end

local function all_trim(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$")
end

-- --- Player Control Functions ---

local function write_that_SNITCH(SNITCHfilename, record, journal_type, path)
    if not SNITCHfilename or not record or not SNITCH_DIR then 
        M.log("error", "SNITCH_DIR or filename/record is nil. Skipping write.") 
        send_OSD("SNITCH FAILED: Config missing", 5)
        return
    end

    local success = true
    local SNITCH_handle = io.open(SNITCHfilename, "a")
    if SNITCH_handle then
        SNITCH_handle:write(record)
        SNITCH_handle:close()
    else
        M.log("error", "Failed to open SNITCH file:", SNITCHfilename)
        success = false
    end

    if success and journal_type == "edl" and EDL_SNITCH_JOURNAL then
        create_edl_if_missing(EDL_SNITCH_JOURNAL)
        local journal_handle = io.open(EDL_SNITCH_JOURNAL, "a")
        if journal_handle then
            journal_handle:write(record)
            journal_handle:close()
        else
            M.log("error", "Failed to open EDL journal:", EDL_SNITCH_JOURNAL)
        end
    elseif success and journal_type == "non_edl" and NON_EDL_JOURNAL then
        local journal_handle = io.open(NON_EDL_JOURNAL, "a")
        if journal_handle then
            journal_handle:write(record)
            journal_handle:close()
        else
            M.log("error", "Failed to open NON-EDL journal:", NON_EDL_JOURNAL)
        end
    end

    if success then
        send_OSD("SNITCHED: "..path:gsub("\\", "/"), 3)
    end
end

local function SNITCH_file()
    local filename = mp.get_property("filename")
    local path = mp.get_property("path")
    local fileclass = get_file_class(filename)
    local record = nil
    local journal_type = "edl"

    if fileclass == "unrecognised" then
        send_OSD("Unrecognised file type: "..path:gsub("\\", "/"), 2)
        return
    end

    local SNITCHfilename = nil
    
    if fileclass == "video" or fileclass == "audio" then
        SNITCHfilename = SNITCH_DIR.."/clip_SNITCH_"..os.date('%d_%m_%y_%H')..".edl"
        if not create_edl_if_missing(SNITCHfilename) then return end
        local time_pos = mp.get_property_number("time-pos") or 0
        local start_second = math.floor(time_pos)
        record = path..","..start_second..","..SNITCH_SEGMENT_LENGTH.."\n"
        mp.command("seek "..SNITCH_SEGMENT_LENGTH)
    elseif fileclass == "image" then
        SNITCHfilename = SNITCH_DIR.."/image_SNITCH_"..os.date('%d_%m_%y_%H')..".m3u"
        if not file_exists(SNITCHfilename) then
            local tmphandle = io.open(SNITCHfilename, "wb")
            if tmphandle then tmphandle:close() end
        end
        record = path.."\n"
        journal_type = "non_edl"
        mp.command("playlist-next")
    end

    if record then
        write_that_SNITCH(SNITCHfilename, record, journal_type, path)
    end
end

local function ditch_file()
    local path = mp.get_property("path")
    if not path or not DITCHED_FILE_PATH then
        send_OSD("DITCH FAILED: Path or EDLSRC/ditched.txt path missing.", 3)
        return
    end

    local strPath = "rm -v "..'"'..path..'"'.."\n"
    local ditch_handle = io.open(DITCHED_FILE_PATH, "a")
    if ditch_handle then
        ditch_handle:write(strPath)
        ditch_handle:close()
        send_OSD("DITCHED: "..strPath, 1)
        mp.command("playlist-next")
    else
        M.log("error", "Failed to open ditch file:", DITCHED_FILE_PATH)
        send_OSD("DITCH FAILED: Cannot open file", 2)
    end
end

function M.toggle_ditch_snitch()
    DITCH_MODE = (DITCH_MODE == "SNITCH") and "DITCH" or "SNITCH"
    send_OSD("DITCH_MODE = "..DITCH_MODE, 1)
end

function M.ditch_or_snitch()
    if DITCH_MODE == "SNITCH" then
        SNITCH_file()
    else
        ditch_file()
    end
end

-- Subtitle/Chapter Handling
local function write_subtitles(chaptime_length)
    if SUBTITLES_ENABLED and line_count > 0 then
        local msg_text = tostring(lines[step_count]):gsub("\r", "")
        mp.osd_message(msg_text, chaptime_length)
        step_count = (step_count % line_count) + 1
    end
end

function M.new_chapter()
    local chapterlist = mp.get_property_native("chapter-list")
    local chapter = mp.get_property_native("chapter")

    if chapter and chapterlist and chapter + 1 <= #chapterlist then
        local chaptime_time = chapterlist[chapter + 1].time
        chaptime_time = chaptime_time or 0 
        
        local chaptime_length = chaptime_time - previous_chapter_time
        previous_chapter_time = chaptime_time
        
        if chapter == 0 and chaptime_time > 0 then
            chaptime_length = chaptime_time
            previous_chapter_time = 0
        end

        write_subtitles(chaptime_length)
    end
end

-- Cutting Functions
local function valid_for_cutting()
    local fileclass = get_file_class(mp.get_property("filename") or "")
    if fileclass == "video" or fileclass == "audio" then
        return true
    else
        send_OSD("Wrong file type for cutting: "..fileclass, 2)
        return false
    end
end

function M.start_cut()
    if not valid_for_cutting() then return end
    local time_pos = mp.get_property_number("time-pos")
    g_start_second = math.floor(time_pos or 0)
    send_OSD("Start cut "..g_start_second, 1)
end

function M.end_cut()
    if not valid_for_cutting() then return end
    local time_pos = mp.get_property_number("time-pos") or 0
    local stop_second = math.floor(time_pos) - g_start_second
    
    if stop_second <= 0 then
        send_OSD("End time is before or same as start time. Cut aborted.", 3)
        g_start_second = 0
        return
    end

    local path = mp.get_property("path")
    local str_record = path..","..g_start_second..","..stop_second.."\n"
    local SNITCHfilename = "manual_cut_"..os.date('%d_%m_%y_%H')..".edl"
    local SNITCH_file = SNITCH_DIR.."/"..SNITCHfilename
    
    if SNITCH_DIR and create_edl_if_missing(SNITCH_file) then
        write_that_SNITCH(SNITCH_file, str_record, "edl", path)
        send_OSD("Cut recorded: "..g_start_second.." for "..stop_second.."s", 2)
    else
        send_OSD("Cut failed: SNITCH_DIR or file error.", 3)
    end
    g_start_second = 0
end

function M.delete_me()
    local filename = mp.get_property_native("path")
    if not filename then return end
    
    local delete_handle = io.open('/tmp/deleteMe.sh', "a")
    if delete_handle then
        local wrtString = "rm -v '"..filename.."'\n"
        delete_handle:write(wrtString)
        delete_handle:close()
        M.log("info", "Wrote delete command for:", filename)
        mp.command("playlist-next")
    else
        M.log("error", "Failed to open /tmp/deleteMe.sh")
    end
end

-- --- Database Hook Functions ---

function M.start_file()
    M.log("info", "Attempting to acquire database connection for this MPV instance.")
    
    local db = open_db(HISTORY_DB_PATH, "history")
    check_and_create_table(db)
    
    previous_chapter_time = 0 
end

function M.file_loaded()
    local db = DB_CONNECTIONS.history 
    if not db then return M.log("error", "History DB not connected in file_loaded.") end

    local path = mp.get_property("path") or "N/A"
    local filename = mp.get_property("filename") or "N/A"
    local title = mp.get_property("media-title") or "N/A"
    local date_str = os.date("%Y-%m-%d %H:%M")

    local safe_path = string.gsub(path, "'", "''")
    local safe_filename = string.gsub(filename, "'", "''")
    local safe_title = string.gsub(title, "'", "''")

    local video_query = string.format([[
        INSERT INTO history_item (path, filename, title, date)
        VALUES(
            '%s',
            '%s',
            '%s',
            '%s'
        );
        SELECT LAST_INSERT_ROWID();
    ]], safe_path, safe_filename, safe_title, date_str)

    local last_id = nil
    local res = db:exec(video_query, function(udata, cols, values, names)
        last_id = tonumber(values[1])
        return 0
    end, nil)
    
    if res == sqlite3.OK and last_id then
        mp.set_property_number("script-opts/history-id", last_id)
        M.log("info", "New history ID recorded in MPV property:", last_id)
    else
        M.log("error", "Failed to insert history item:", db:errmsg())
    end
end

function M.on_unload()
    local db = DB_CONNECTIONS.history
    if not db then return M.log("error", "History DB not connected in on_unload.") end

    local time_pos = tonumber(mp.get_property("percent-pos"))
    local current_id = tonumber(mp.get_property("script-opts/history-id"))

    if not current_id then
        return M.log("info", "No history ID found for current file. Skipping update.")
    end
    if time_pos == nil then
        return M.log("info", "No time position found. Skipping update.")
    end

    local query = string.format([[
        UPDATE history_item
        SET time_pos = %d
        WHERE id = %d;
    ]], math.floor(time_pos), current_id)

    local res = db:exec(query)
    if res ~= sqlite3.OK then
        M.log("error", "Failed to update time position:", db:errmsg())
    else
        M.log("info", "Time position updated for ID:", current_id)
    end
end

function M.shutdown()
    for name, db_handle in pairs(DB_CONNECTIONS) do
        if db_handle then
            M.log("info", "Closing", name, "database.")
            db_handle:close()
        end
    end
end

-- --- EXECUTION FLOW ---

-- 1. Check required environment variables and exit if missing.
if not M.check_environment() then
    -- Execution flow terminates here if variables are missing due to mp.abort_script
end

-- 2. Initialization Logic (Runs only if environment check passes)
-- OSD properties
mp.set_property("osd-align-y", "bottom")
mp.set_property("osd-align-x", "center")
mp.set_property("image-display-duration", message_display_time)

-- Load subtitles if available
if subtitles_file then
    local path_norm = subtitles_file:gsub("\\", "/")
    if file_exists(path_norm) then
        for line in io.lines(path_norm) do
            local trimmed = all_trim(line)
            if string.len(trimmed) >= 1 then
                lines[#lines + 1] = trimmed
                line_count = line_count + 1
            end
        end
        SUBTITLES_ENABLED = line_count > 0
        M.log("info", "Subtitles loaded:", line_count, "lines.")
    else
        M.log("info", "Subtitles file not found at:", path_norm)
    end
end

-- 3. Register MPV Hooks
mp.register_event("start-file", M.start_file)
mp.register_event("file-loaded", M.file_loaded)
mp.add_hook("on_unload", 50, M.on_unload)
mp.register_event("shutdown", M.shutdown)

mp.observe_property("chapter", "number", M.new_chapter)

-- Key bindings
mp.add_key_binding("D", "toggle_ditch_snitch", M.toggle_ditch_snitch, {repeatable=true})
mp.add_key_binding("MBTN_Right", "ditch_or_snitch", M.ditch_or_snitch, {repeatable=true})
mp.add_key_binding("KP1", "start_cut", M.start_cut, {repeatable=true})
mp.add_key_binding("KP2", "end_cut", M.end_cut, {repeatable=true})
mp.add_key_binding("Ctrl+DEL", "deleteMe", M.delete_me, {repeatable=true})

M.log("info", "mpv_db_handler.lua loaded. Current mode:", DITCH_MODE)

return M