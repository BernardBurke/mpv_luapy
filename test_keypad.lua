-- test_keypad.lua
-- Purpose: Test which Numpad key names register in mpv audio-only mode.

local mp = require('mp')
local msg = require('mp.msg')

-- This is the function we will bind to all key names
local function announce_key(key_name)
    local message = "KEYPAD TEST SUCCESS: " .. key_name .. " WAS PRESSED!"
    msg.warn(message)
    mp.osd_message(message, 3)
    -- Also write to a file just in case console output is flaky
    local log_handle = io.open("/tmp/test_keypad_log.txt", "a")
    if log_handle then
        log_handle:write(os.date("%H:%M:%S").. " " .. message .. "\n")
        log_handle:close()
    end
end

-- --- Key Bindings ---

-- 3. Key bindings
M.log("info", "EXECUTION: Setting key bindings.")
-- Using only the known/working simple key names (KP1, KP2, KP0)
-- The 'force=true' option ensures these bindings override the default 'contrast' actions.

mp.add_key_binding("n", "user-skip-next", function() mp.command("playlist-next") end, {repeatable=false, force=true})
mp.add_key_binding("KP1", "start_cut", M.start_cut, {repeatable=false, force=true})
mp.add_key_binding("KP2", "end_cut", M.end_cut, {repeatable=false, force=true})
mp.add_key_binding("KP0", "snap_SNITCH", M.snap_SNITCH, {repeatable=true, force=true})
mp.add_key_binding("g", "goldKey", M.goldKey, {repeatable=true, force=true})

M.log("info", "EXECUTION: All key bindings set.")

msg.warn("Keypad Test Script Loaded Successfully.")

return {}