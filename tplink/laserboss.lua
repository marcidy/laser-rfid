#!/usr/bin/lua
-- config
PORT_NAME = "/dev/ttyACM0"
READ_TIMEOUT = 2000	-- in ms
DB_FILE = "/root/laser.db"
COST_PER_MIN = 0.25
USB_PATH = "/sys/bus/usb/devices/usb1/authorized"
UPDATE_INTERVAL = 3600
RETRY_INTERVAL = 300

-- open / create laser database
sqlite3 = require("luasql.sqlite3")
env = sqlite3.sqlite3()
conn = env:connect(DB_FILE)
conn:execute("CREATE TABLE IF NOT EXISTS log (id INTEGER PRIMARY KEY, time INTEGER, user_key_id TEXT, odometer INTEGER, evtype TEXT)")
conn:commit()

-- serial port
rs232 = require("luars232")

-- socket library
http = require("socket.http")
ltn12 = require("ltn12")
dofile("key.lua")

-- DO NOT CALL THIS WITH REMOTELY RETURNED DATA (like error messages!!!!)
function logger(msg)
	print(msg)
	os.execute(('logger -t laserboss "%q"'):format(msg))
end

-- error handling device
function try(f, catch_f)
	local status, exception = pcall(f)
	if not status then catch_f(exception) end
end

function update_keys()
	local t = {}
	local b, c = http.request{ url = "https://acemonstertoys.wpengine.com/wp-json/amt/v1/rfids/active",
		headers = {["X-Amt-Auth"] = WP_KEY},
		method = "GET",
		redirect = true,
		sink = ltn12.sink.table(t)
		}
	assert(c == 200, "Got " .. c .. " instead of 200")
	assert(b == 1, "Got " .. b .. " instead of 1")
	local json_str = table.concat(t)
	assert(string.sub(json_str, 3, 4) == 'OK', "Got " .. json_str)
	local outtbl = {}
	local i = 0
	for k in string.gmatch(string.sub(json_str, 5, -1), '\"(%w+)\"') do
		outtbl[k] = true
		i = i+1
	end
	assert(i > 0, "Got 0 keys")
	logger("Updated active key list, " .. i .. " entries")
	active_keys = outtbl
end

function submit_event(ts, evtype, userid, odo)
	local t = {}
	local b, c = http.request{ url = "https://acemonstertoys.org/laser/api.php?timestamp=" .. ts .. "&odometer=" .. odo .. "&event=" .. evtype .. "&rfid=" .. userid,
		headers = {["X-Amt-Auth"] = LASER_KEY},
		method = "GET",
		redirect = true,
		sink = ltn12.sink.table(t)
		}
	assert(c == 200, "Got " .. c .. " instead of 200 when submitting event")
	assert(b == 1, "Got " .. b .. " instead of 1 when submitting event")
	local response = table.concat(t)
	assert(string.sub(response, 1, 2) == 'OK', "Response is " .. response)
	print("Submitted event: ", ts, evtype, userid, odo)
end

function upload_journal()
	-- query the db
	local cur = conn:execute("SELECT * from log ORDER BY id")
	local row = {}
	local ok
	-- fetch, submit, and delete each journal record
	repeat
		ok = cur:fetch(row, 'a')
		if ok then
			submit_event(row['time'], row['evtype'], row['user_key_id'], row['odometer'])
			conn:execute("DELETE FROM log WHERE id="..row['id'])
			conn:commit()
		end
	until ok == nil
end

function open_port()
	local e
	p = nil -- close port if it was already open
	e, p = rs232.open(PORT_NAME)
	assert(e == rs232.RS232_ERR_NOERROR, "Error opening port")
	assert(p:set_baud_rate(rs232.RS232_BAUD_9600) == rs232.RS232_ERR_NOERROR, "Error setting baud")
	assert(p:set_data_bits(rs232.RS232_DATA_8) == rs232.RS232_ERR_NOERROR, "Error setting 8 bits")
	assert(p:set_parity(rs232.RS232_PARITY_NONE) == rs232.RS232_ERR_NOERROR, "Error setting parity")
	assert(p:set_stop_bits(rs232.RS232_STOP_1) == rs232.RS232_ERR_NOERROR, "Error setting stop bits")
	assert(p:set_flow_control(rs232.RS232_FLOW_OFF) == rs232.RS232_ERR_NOERROR, "Error setting flow off")
	p:flush()
	-- if an rfid got scanned at some point before we booted, ignore it
	get_status()
	get_rfid()
end

function display (line1, line2)
	if line1 then
		p:write("p" .. line1 .. "\n")
	end
	if line2 then
		p:write("q" .. line2 .. "\n")
	end
end

-- trim whitespace from string
function trim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function reset_usb ()
	os.execute("echo 0 > " .. USB_PATH)
	os.execute("echo 1 > " .. USB_PATH)
	os.execute("sleep 2")
end

-- read a line from rs232 with timeout
function rs232_readline ()
	local s = ""
	repeat
		local e, d, sz = p:read(1, READ_TIMEOUT, 1)
		assert(e == rs232.RS232_ERR_NOERROR, "Error reading from port")
		s = s .. d
	until d == '\n'
	return s
end

function get_status ()
	p:write("o\n")
	stat = rs232_readline()
	-- print("stat: ", trim(stat))
	return string.gmatch(stat, 'o(%d+)x(%d+)')()
end

function get_rfid ()
	p:write("r\n")
	return string.gmatch(rs232_readline(), 'r(%w+)')()
end

function set_enabled (enabled)
	if enabled then
		p:write("e\n")
	else
		p:write("d\n")
	end
end

function dblog (user, odometer, evtype)
	nr = conn:execute("INSERT INTO log (time, user_key_id, odometer, evtype) VALUES (" .. os.time() .. ",\""
			.. conn:escape(user) .. "\", " .. odometer .. ",\"" .. evtype .. "\")")
	assert(nr == 1, "Rows written to db not 1")
	conn:commit()
	journal_dirty = true
end

function display_idle (odo)
	display("Tag your fob...", "Odo: " .. odo .. " s")
end

function display_active (odo_start, odo)
	print(odo_start, odo)
	local minutes = math.floor((odo-odo_start)/60)
	local seconds = (odo-odo_start) % 60
	display(" Time:   Cost:", string.format("%3.0f",minutes) .. ":" ..
				string.format("%02.0f",seconds) .. "   $" .. 
				string.format("%3.2f", COST_PER_MIN * (odo-odo_start)/60))
end

function is_valid_user(userid)
	return (active_keys == nil or active_keys[userid] ~= nil)
end
	
local isEnabled = false
local user, odo_start
local time_last_update = os.time()
local time_last_jrnl = 0
journal_dirty = true
try(function() 
	update_keys()
end, function(e)
	logger("Could not load key list")
	print(e)
end)

try(function() 
	open_port()
	set_enabled(false)
end, function(e)
	print("Failed to open port: ", e)
end)



while true do
	try(function()
		local odo, scanned = get_status()
		assert(odo ~= nil and scanned ~= nil, "Status is invalid")
		if os.time() - time_last_update > UPDATE_INTERVAL then
			try(function() 
				update_keys()
				time_last_update = os.time()
			end, function(e)
				logger("Could not update key list")
				print(e)
				time_last_update = time_last_update + RETRY_INTERVAL
			end)
		end
		
		try(function() 
			if (journal_dirty and os.time() - time_last_jrnl > RETRY_INTERVAL) then
				upload_journal()
				journal_dirty = false
				-- we don't update time_last_jrnl unless there is a failure
			end
		end, function(e)
			time_last_jrnl = os.time()
			logger("Failed to upload journal")
			print("Failed to upload journal: ", e)
		end)
		
		set_enabled(isEnabled)
		
		if isEnabled then
			if scanned == "1" then
				-- sign out
				dblog(user, odo, "logout")
				user2 = get_rfid()
				if (user2 ~= user) then
					logger("Logged out user " .. user)
					-- last person forgot to tag out
					if is_valid_user(user2) then
						logger("Logged in user " .. user2)
						dblog(user2, odo, "login")
						user = user2
						display("Welcome new user")
						os.execute("sleep 1")
						odo_start = odo
					else	
						logger("Attempted login from inactive fob: " .. user2)
						display("Fob not active")
						set_enabled(false)
						isEnabled = false
						os.execute("sleep 5")
					end
				else
					-- same person tagged out
					logger("Logged out user " .. user)
					set_enabled(false)
					display("Goodbye!")
					os.execute("sleep 5")
					isEnabled = false
				end
			else
				-- print("actv", odo_start, odo)
				display_active(odo_start, odo)
				os.execute("sleep 1")
			end
		else
			if scanned == "1" then
				-- sign in
				user = get_rfid()
				print(user)
				if is_valid_user(user) then
					logger("Logged in user " .. user)
					isEnabled = true
					set_enabled(true)
					dblog(user, odo, "login")
					odo_start = odo
					display("Welcome!")
					os.execute("sleep 2")
				else
					logger("Attempted login from inactive fob: " .. user)
					display("Fob not active")
					os.execute("sleep 5")
				end
			else
				display_idle(odo)
				os.execute("sleep 1")
			end
		end
	end, function(e)
		print("Error occurred: " .. e)
		local stat
		repeat
			logger("Trying to reset port")
			os.execute("sleep 1")
			try(function() 
				if p ~= nil then
					p:close()
				end
				reset_usb()
				open_port()
				set_enabled(isEnabled)
				stat = true
			end, function(e) print(e); stat = nil end)
		until stat
		logger("Port reset OK")
	end)
end
