-- lsqlite3_test.lua
-- Minimal script to verify lsqlite3 is correctly loaded and accessible by mpv.

local sqlite3_ok, sqlite3 = pcall(require, "lsqlite3")

local mp = require("mp")

if not sqlite3_ok then
    -- Log a fatal error if the module cannot be found
    mp.msg.error("FATAL: Cannot load lsqlite3. Check your package.cpath setup!")
    mp.abort_script("lsqlite3 module not found.")
end

mp.msg.info("lsqlite3 module loaded successfully.")

-- --- Database Test ---
local db_path = ":memory:" -- Use in-memory for a non-file-system test

local db, err = sqlite3.open(db_path)

if not db then
    mp.msg.error("Failed to open SQLite database: " .. tostring(err))
    mp.abort_script("SQLite open failure.")
end

-- Create a table and insert data
db:exec[[CREATE TABLE test (id INTEGER, name TEXT);]]
db:exec[[INSERT INTO test VALUES (1, 'Alice');]]
db:exec[[INSERT INTO test VALUES (2, 'Michelle');]]
db:exec[[INSERT INTO test VALUES (3, 'Bob');]]

-- Query and log results
mp.msg.info("--- SQLite Query Results ---")
for row in db:nrows("SELECT id, name FROM test ORDER BY id") do
    -- Log output to MPV's console/log file
    mp.msg.info(string.format("ID: %s, Name: %s", tostring(row.id), tostring(row.name)))
end
mp.msg.info("----------------------------")

-- Close the database
db:close()

mp.msg.info("lsqlite3 test finished successfully.")