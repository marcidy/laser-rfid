import time
from subprocess import run
from serial import Serial
from util import (
    report_attempt,
    load_whitelist,
)


class Laser:

    USB_PATH = "/sys/bus/usb/devices/usb1/authorized"
    # would prefer if the ATTINY weren't so opinionated about what to do.
    # why save to eeprom when you can just send information about if the
    # laser is firing to the rpi and save it there?
    # Why using such a slow baudrate?  ATTINYs are fast.

    def __init__(self, port='/dev/ttyACM0', baudrate=9600):
        self.conn = Serial(port, baudrate)
        self.enabled = False  # Do I need to send disable on service start?
        self.authorized = None
        self.odometer = ''
        self.rfid_flag = ''

    def write(self, msg):
        self.conn.write('{}\n'.format(msg).encode('ascii'))

    def raw_read(self):
        return self.conn.read_until()  # default terminator is '\n'

    def read(self):
        more = True
        data = ''
        while more:
            data += self.raw_read()
            if self.conn.in_waiting <= 0:
                more = False
        if data:
            return data.decode('ascii')
        else:
            return ''

    def enable(self):
        self.write("e")
        self.enabled = True

    def disable(self):
        self.write("d")
        self.enabled = False

    def reset_usb(self):
        run(["echo", "0", self.USB_PATH])
        run(["echo", "1", self.USB_PATH])
        time.sleep(2)

    def display(self, line1='', line2=''):
        if line1:
            self.write('p'+line1)
        if line2:
            self.write('q'+line2)

    def status(self):
        self.write('o')
        data = self.read()
        if data:
            try:
                self.odometer, self.rfid_flag = data[1:].split('x')
            except Exception:
                print("Error: status - {}".format(data))

    def rfid(self):
        self.write("r")
        data = self.read()
        return data[1:]

    def reset_cut_time(self):
        self.write('x')

    def update_cut_time(self):
        self.write('y')

    def read_cut_time(self):
        self.write('z')


if __name__ == '__main__':
    print("Laser service starting....")
    print(time.time())
    rfid_update_time = 0
    last_scanned_rfid = None
    authorized_rfids = []
    authorized = False
    laser = Laser()

    while True:
        if time.time() - rfid_update_time > 60:
            authorized_rfids = load_whitelist()
            rfid_update_time = time.time()

        Laser.status()

        if Laser.rfid_flag == '1':
            rfid = Laser.rfid()
            if rfid:
                authorized = rfid in authorized_rfids
                report_attempt(rfid, authorized)
            Laser.rfid_flag = '0'
        # What is the enble vs authorized flow?

        time.sleep(.001)  # sleep to the OS for 1ms
