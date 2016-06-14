-- config
PORT_NAME = "/dev/ttyUSB0"
READ_TIMEOUT = 1
DB_FILE = "/var/db/laser.db"

-- open / create laser database
sqlite3 = require("luasql.sqlite3")
env = sqlite3.sqlite3()
conn = env:connect(DB_FILE)
conn:execute("CREATE TABLE IF NOT EXISTS log (id INTEGER PRIMARY KEY, time INTEGER, user_key_id TEXT, odometer INTEGER, evtype TEXT)")
conn:commit()

-- open serial port
rs232 = require("luars232")
local e, p = rs232.open(PORT_NAME)
assert(e == rs232.RS232_ERR_NOERROR)
assert(p:set_baud_rate(rs232.RS232_BAUD_9600) == rs232.RS232_ERR_NOERROR)
assert(p:set_data_bits(rs232.RS232_DATA_8) == rs232.RS232_ERR_NOERROR)
assert(p:set_parity(rs232.RS232_PARITY_NONE) == rs232.RS232_ERR_NOERROR)
assert(p:set_stop_bits(rs232.RS232_STOP_1) == rs232.RS232_ERR_NOERROR)
assert(p:set_flow_control(rs232.RS232_FLOW_OFF) == rs232.RS232_ERR_NOERROR)

function display (line1, line2)
	if line1 then
		p:write("p1" .. line1 .. "\n")
	end
	if line2 then
		p:write("p2" .. line2 .. "\n")
	end
end

function rs232_readline ()
	local s = ""
	repeat
		local e, d, sz = p:read(1, READ_TIMEOUT)
		s = s .. d
		assert(e == rs232.RS232_ERR_NOERROR)
	until d == '\n'
	return s
end


function get_status ()
	p:write("o\n")
	stat = rs232_readline()
	return string.gmatch(stat, 'o(%d+)x(%d+)')()
end


