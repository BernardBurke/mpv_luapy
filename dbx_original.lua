local utils = require("mp.utils")

SNITCH_DIR = os.getenv("BCHU")
USCR = os.getenv("USCR")
HI = os.getenv("HI")

SNITCH_SEGMENT_LENGTH = 30
MESSAGE_DISPLAY_TIME_DEFAULT = 15
SUBTITLES_ENABLED = false

DITCH_MODE = "SNITCH"
if os.getenv("DITCH_MODE") then
    DITCH_MODE = "DITCH"
    message_display_time = 15
    print("DITCH_MODE")

end

local function isempty(s)
    return s == nil or s == ''
end

if isempty(os.getenv("MESSAGE_DISPLAY_TIME")) then
    message_display_time = MESSAGE_DISPLAY_TIME_DEFAULT
else
    message_display_time = os.getenv("MESSAGE_DISPLAY_TIME")
    print("Using custom message display time: "..tostring(message_display_time))
end
-- now shared by all writers
EDL_SNITCH_JOURNAL = SNITCH_DIR.."/edl_journal.edl"
NON_EDL_JOURNAL = SNITCH_DIR.."/m3u_journal.m3u"
USCR_CMD = USCR.."\\snapped.sh"

-- required for subtitles array and timing
lines = {}
chapter_time = 0
step_count = 1
line_count = 0

-- required to derive chapter_length from previous time

previous_chapter_time = 0

-- for one_off cut style

g_start_second = 0

local subtitles_file = os.getenv("IMGSUBTITLES")

function all_trim(s)
    return s:match( "^%s*(.-)%s*$" )
end

function send_OSD(message_string, seconds)

    local message_str = mp.get_property("osd-ass-cc/0")..message_string..mp.get_property("osd-ass-cc/1")

    print("osd message ".. message_str)

    mp.osd_message(message_str, seconds)

end

function file_exists(file)
    local f = io.open(file, "rb")
    if f then f:close() end
    return f ~= nil
end

if subtitles_file ~= nil then
    local subtitles_file = subtitles_file:gsub("\\","/")
    print("subtitles environment set via IMGSUBTITLES")
    
    if file_exists(subtitles_file) then
        print("loading "..subtitles_file)
        for line in io.lines(subtitles_file) do 
            print("reading "..line)
            if (string.len(all_trim(line)) >= 1) then 
                lines[#lines + 1] = line
                line_count = line_count + 1
            end
        end

        SUBTITLES_ENABLED = true

    else
        print("IMGSUBTITLES points at a file we cant open, file"..subtitles_file)
    end
else
    print("subtitles unavailable")
end

mp.set_property("osd-align-y","bottom")
mp.set_property("osd-align-x","center")
mp.set_property("image-display-duration",message_display_time)
--mp.set_property("volume",20)
--mp.set_property("screen",0)
--mp.set_property("fullscreen")
--mp.set_property("fs-screen",0)

print("Good morning")

 
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

local function toggle_SNITCH()
    if DITCH_MODE == "SNITCH" then
        DITCH_MODE = "DITCH"
    else
        DITCH_MODE = "SNITCH"
    end
    send_OSD("DITCH_MODE = "..DITCH_MODE, 1)
end

local function create_edl_if_missing(bfile)
    local hndl
    if not file_exists(bfile) then
        hndl = io.open(bfile, "wb")
        hndl:write("# mpv EDL v0\n")
        hndl:close()
        print("created "..bfile)
    end
end

local function get_the_edl_record(full_path,record_number)
    --- read the inscope edl file, fetch the current record - ahhhh
    print("full path "..full_path)
      if not file_exists(full_path) then return {} end
      lines = {}
      for line in io.lines(full_path) do 
        --print("lion "..line)
        if string.sub(line,1,1) ~= "#" then 
            lines[#lines + 1] = line
        end
      end
      return lines[record_number+1]
    
    end

local function day_journal(record)
    --local TEMPDIR = os.getenv("TEMP")
    local DAY_journal_name = "/tmp/edl_day_journal.edl"
    create_edl_if_missing(DAY_journal_name)
    local DAY_handle = io.open(DAY_journal_name, "a")
    DAY_handle:write(record)
    DAY_handle:close()

end

local function write_that_SNITCH(SNITCHfilename,record,journal_type,path)

    local SNITCH_handle = io.open(SNITCHfilename, "a")    
    SNITCH_handle:write(record)
    SNITCH_handle:close()

    if journal_type == "edl" then
        create_edl_if_missing(EDL_SNITCH_JOURNAL)
        local journal_handle = io.open(EDL_SNITCH_JOURNAL,"a")
        local snap_handle = io.open(USCR_CMD,"a+")
        journal_handle:write(record)
        journal_handle:close()
        -- local fnam = Split(record,",")
        -- local file_name_only = fnam[1] 
        -- snap_handle:write("mpv --screen=2 --fs-screen=2 --volume=10 "..'"'..file_name_only..'"')
        -- snap_handle.close()
    else
        local journal_handle = io.open(NON_EDL_JOURNAL,"a")
        journal_handle:write(record)
        journal_handle:close()
    end

--    print("displaying path before gsub ", path)

    local message_string = path:gsub("\\","/")

--    print("displaying message_string before gsub of non slashes ", path)

--   print("displaying path before gsub ", path)
--    message_string = message_string:gsub("%(","")
--    message_string = message_string:gsub("%)","")

--    local message_str = mp.get_property("osd-ass-cc/0")..message_string..mp.get_property("osd-ass-cc/1")
--    print("Message is "..message_string)
    
    send_OSD("SNITCHED: "..message_string, 3)

end

local function SNITCH_file()
    
    local filename = mp.get_property("filename")
    local slart = file_type(filename)
    local path = mp.get_property("path")
    local firstchar = string.sub(slart,1,1)
    local record = nil
    local fileclass = get_file_class(filename)
    local journal_type = "edl"
    print("the path is "..path)

    if fileclass == "unrecognised" then
        print("Don't know what do do with "..filename)
        send_OSD("unrecognised file type: "..path:gsub("\\","/"), 2)
        do return end
    end
    
    print("the file class is "..fileclass)
    
    local chapter = mp.get_property_native("chapter")
    local record_number = chapter
    local time_pos = mp.get_property_number("time-pos")
    local start_second = math.floor(time_pos)

    local SNITCHfilename = SNITCH_DIR.."/edl_SNITCH"..os.date('%d_%m_%y_%H')..".edl"

    if fileclass == "edl" then
        create_edl_if_missing(SNITCHfilename)
        record = get_the_edl_record(mp.get_property_native("path"),record_number).."\n"
        print("an EDL "..record.." will be written to "..SNITCHfilename)
        mp.command("keypress PGUP")
    end

    if fileclass == "video" then
        create_edl_if_missing(SNITCHfilename)
        record = path..","..start_second..","..SNITCH_SEGMENT_LENGTH.."\n"
        print("edl snapped from video, record is "..record)
        mp.command("seek "..SNITCH_SEGMENT_LENGTH)
    end

    if fileclass == "image" then
        SNITCHfilename = SNITCH_DIR.."/image_SNITCH"..os.date('%d_%m_%y_%H')..".m3u" 
        if not file_exists(SNITCHfilename) then
            local tmphandle = io.open(SNITCHfilename,"wb")
            tmphandle:close()
        end
        record = path.."\n"
        print("SNITCHed an image file"..path)
        journal_type = "non_edl"
        mp.command("playlist-next")
    end

        write_that_SNITCH(SNITCHfilename,record,journal_type,path)

end

local function ditch_file()
    
    local filename = mp.get_property("filename")

    local path = mp.get_property("path")
    local strPath = "rm -v "..'"'..path..'"'.."\n"

    print("ditching ", path )

    local ditch_file = os.getenv("EDLSRC").."/".."ditched.txt"
    print("ditching to", ditch_file)

    ditch_handle = io.open(ditch_file, "a")    
    ditch_handle:write(strPath)
    send_OSD("ditched : "..strPath, 1)
    mp.command("playlist-next")
    ditch_handle:close()

end

local function ditch_or_SNITCH()
    if DITCH_MODE == "SNITCH" then
        print("SNITCHing")
        SNITCH_file()
    else
        print("Ditching")
        ditch_file()
    end
end


local function write_subtitles(chaptime_length)

    --display_time = message_display_time
    if SUBTITLES_ENABLED then
        
        msg = tostring(lines[step_count]):gsub("\r", "")
        mp.osd_message(msg,chaptime_length)
        if step_count == line_count then
            step_count = 1
        end
        step_count = step_count + 1
    end
    
    --chapter_time = 0
end


local function play_or_SNITCH(whatsitabout)
    print("Chapter or file change "..whatsitabout)
    if PLAY_MODE == "SNITCH" then
        print("SNITCHing - no subtitles")
    else
        print("subtitles On")
    end

end



local function new_chapter()
    local chapterlist = mp.get_property_native("chapter-list")
    local chapter = mp.get_property_native("chapter")
    local chaptermetadata = mp.get_property_native("chapter-metadata")

    if chapter~=nil then 

        print("New chapter "..chapter)
        print("Metadata ")

        --print_table(chapterlist)

        record_number = chapter+1

        --print(" how about you go to this file ", playlist)
        print("chapter time is ", chapterlist[chapter+1].time)
        chaptime_time = chapterlist[chapter+1].time
        if chaptime_time == 0 then -- I need to figure out why my zero base is off
            chaptime_time = 30 -- just a bandaid
        end
            
        chaptime_length = chaptime_time - previous_chapter_time
        print("Chapter Length is ",chaptime_length)
        
        print("record_number was ", record_number)
        previous_chapter_time = chaptime_time
        write_subtitles(chaptime_length)
    end
end

local function new_file(filename)
    print("New file "..filename)
    previous_chapter_time = 0
    --write_subtitles(message_display_time)
end

local function valid_for_cutting()
        local filename = mp.get_property("filename")
        local fileclass = get_file_class(filename)

        print("validating "..fileclass)

        if fileclass == "video" or fileclass == "audio" then
    
        return true

        else
            print("Wrong file type for cutting "..fileclass)
            send_OSD("Wrong file type for cutting "..fileclass,2)
            return false
        end

end

local function start_cut()
    
    if not valid_for_cutting() then return end

    local time_pos = mp.get_property_number("time-pos")
    g_start_second = math.floor(time_pos)
    print("Start cut issued ", g_start_second)
    send_OSD("Start cut "..g_start_second,1)
end

local function end_cut()

    if not valid_for_cutting() then return end

    local time_pos = mp.get_property_number("time-pos")
    stop_second = math.floor(time_pos) - g_start_second
    path = mp.get_property("path")
    local str_record= path..","..g_start_second..","..stop_second.."\n"

    local SNITCHfilename = "video_SNITCH_"..os.date('%d_%m_%y_%H')..".edl"
    local SNITCH_file = os.getenv("BCHU").."/"..SNITCHfilename

    print("Adding ",str_record)

    print("Writing ",SNITCH_file)

    create_edl_if_missing(SNITCH_file)

    write_that_SNITCH(SNITCH_file,str_record,"edl",EDL_SNITCH_JOURNAL,path)

    day_journal(str_record)

    print("Ready for next Cut")
    send_OSD("ready for next Cut",2)

end

local function witch()
    local timing=3
    print("witching")    
    mp.command("keypress CTRL+s")
    print("adjusting image display time to "..timing)
    mp.set_property("image-display-duration",timing)
    -- mp.command("playlist-next") this was happening to fast
end

local function snap_SNITCH()

    local filename = mp.get_property("filename")
    local slart = file_type(filename)
    local path = mp.get_property("path")
    local record = nil
    local fileclass = get_file_class(filename)
    
    print("the path is "..path)

    if fileclass == "unrecognised" then
        print("Don't know what do do with "..filename)
        send_OSD("unrecognised file type: "..path, 2)
        do return end
    end
    
    print("the file class is "..fileclass)
    

    print("snapping")

    if fileclass == "edl" then
        local chapter = mp.get_property_native("chapter")
        local record_number = chapter
        local record = get_the_edl_record(mp.get_property_native("path"),record_number)
        local fnam = Split(record,",")
        local start = fnam[2]
        local time_pos = mp.get_property_number("time-pos")
        local start_second = math.floor(time_pos)
        --start = start_second + start
        local file_name_only = fnam[1] 
        local CALL_OS = "mpv --screen=0 --fs-screen=0 --volume=10 --start="..start..' "'..file_name_only..'"'
        print(CALL_OS)
        print(start_second)
        --strCmd = 'start "" '..CALL_OS
        mp.command("keypress SPACE")
        os.execute(CALL_OS)
            -- snap_handle.close()
    end

    if fileclass == "video" then
        local time_pos = mp.get_property_number("time-pos")
        local start_second = math.floor(time_pos)
        --start = start_second + start
        local file_name_only = path:gsub("\\","/")
        local CALL_OS = "mpv --screen=0 --fs-screen=0 --volume=10 --start="..start_second..' "'..file_name_only..'"'
        print(CALL_OS)
        print(start_second)
        strCmd = CALL_OS
        mp.command("keypress SPACE")
        os.execute(strCmd)
            -- snap_handle.close()
    end

end

local function goldKey()
    print("Gold Key")
    local record = nil
    local fileclass = get_file_class(mp.get_property("filename"))
    local gold_file = HI.."/goldVaultCurrent.edl"
    create_edl_if_missing(gold_file)

    print("using gold_file"..gold_file)

    --print("fileclass: "..fileclass)

    if fileclass == "unrecognised" then
        print("Don't know what do do with "..filename)
        send_OSD("unrecognised file type: "..path, 2)
        do return end
    end

    print("file class: "..fileclass)

    if fileclass == "edl" then
        local chapter = mp.get_property_native("chapter")
        local record_number = chapter
        record = get_the_edl_record(mp.get_property_native("path"),record_number)
        local fnam = Split(record,",")
        print("length"..fnam[3])
        local start_second = fnam[2]
        local llength = fnam[3]
        local file_name_only = fnam[1]
        print("file name"..file_name_only)
        local time_pos = mp.get_property_number("time-pos")
        --local start_second = math.floor(time_pos)
        --start = start_second + start
        local file_name_only = fnam[1] 
        record = file_name_only..","..start_second..","..llength.."\n"

    else
        send_OSD("unrecognised file type:"..fileclass, 2)
        do return end
    end


    goldHandler = io.open(gold_file,"a")
    goldHandler:write(record)
    goldHandler:close()
    send_OSD("Gold Keyed wrote successfully record"..record,2)
    mp.command("playlist-next")

end

local function deleteMe()
    local filename = mp.get_property_native("path")
    print("writing "..filename.." to /tmp/deleteMe.sh")
    local delete_handle = io.open('/tmp/deleteMe.sh', "a")    
    local wrtString = "rm -v '"..filename.."'\n"
    print(wrtString)
    delete_handle:write(wrtString)
    delete_handle:close()
    mp.command("playlist-next")

end

print("dbx.lua loaded - waiting for new file or chapter")

mp.observe_property("filename","string",new_file)
--mp.observe_property("chapter","number",new_chapter("chapter"))
mp.observe_property("chapter","number",new_chapter)

print("Setting up key bindings")

mp.add_key_binding("D", "toggle_SNITCH", toggle_SNITCH, {repeatable=true})
mp.add_key_binding("g", "goldKey",goldKey, {repeatable=true})
mp.add_key_binding("KP0", "snap_SNITCH", snap_SNITCH, {repeatable=true})
mp.add_key_binding("MBTN_Right", "ditch_or_SNITCH", ditch_or_SNITCH, {repeatable=true})
mp.add_key_binding("KP1", "start_cut", start_cut, {repeatable=true})
mp.add_key_binding("KP2", "end_cut", end_cut, {repeatable=true})
--mp.add_key_binding("w", "witch",witch, {repeatable=true})
mp.add_key_binding("Ctrl+DEL", "deleteMe",deleteMe, {repeatable=true})

