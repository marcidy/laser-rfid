// include the library code:
#include <LiquidCrystal.h>
#include <EEPROM.h>
#include "EEPROMAnything.h"

// Pins for LCD
#define PIN_LCD_D7 16
#define PIN_LCD_D6 17
#define PIN_LCD_D5 18
#define PIN_LCD_D4 19
#define PIN_LCD_RS 21
#define PIN_LCD_EN 20

#define MAX_DISPLAY_WIDTH 16
#define MAX_DISPLAY_HEIGHT 2

// Input pin from laser cutter mobo
#define LASER_PIN 			0
// 5v from laser power supply
#define LASER_POWER_PIN 	1
// laser pin is active low
#define LASER_PIN_FIRING	0
// power pin is active high
#define LASER_PIN_PWR_ON	1

// Button connected here will reset the counter
// #define RESET_PIN 4

// Relay to enable or disable the laser
#define ENABLE_PIN 10
// Transistor controlling the LCD backlight
#define BACKLIGHT_PIN 12

// Minimum interval between successive EEPROM writes (seconds)
#define MIN_SAVE_INTERVAL	30
// Interval the spinner should appear after last laser event_callback (seconds)
#define SPINNER_TIME		2

#define RFID_CODE_LENGTH 10
#define RFID_CODE_START 0x02
#define RFID_CODE_END 0x03

// ID-12LA RFID reader connected via the UART
HardwareSerial Uart = HardwareSerial();

// initialize the library with the numbers of the interface pins
LiquidCrystal lcd(PIN_LCD_RS, PIN_LCD_EN, PIN_LCD_D4, PIN_LCD_D5, PIN_LCD_D6, PIN_LCD_D7);

// last write address to the EEPROM
int lastPos;
// total accumulated odometer time (seconds)
unsigned long time_total=0;

void read_odo()
{
	lastPos = EEPROM.read(0);
	if(lastPos == 0x11) 
	{
		EEPROM_readAnything(0x11, time_total);
	} 
	else if(lastPos == 0x22) 
	{
		EEPROM_readAnything(0x22, time_total);
	} 
	else 
	{
		lastPos = 0x22;
		time_total = 0;
	}
}

void write_odo()
{
	if(lastPos == 0x11) 
	{
		EEPROM_writeAnything(0x22, time_total);
		EEPROM.write(0, 0x22);
		lastPos = 0x22;
	} 
	else 
	{
		EEPROM_writeAnything(0x11, time_total);
		EEPROM.write(0, 0x11);
		lastPos = 0x11;
	}
}

void setup() 
{
	Serial.begin(9600);
	Uart.begin(9600);

	pinMode(ENABLE_PIN, OUTPUT);
	digitalWrite(ENABLE_PIN, LOW);
	pinMode(BACKLIGHT_PIN, OUTPUT);
	digitalWrite(BACKLIGHT_PIN, HIGH);
	
	// set up the LCD's number of columns and rows: 
	lcd.begin(MAX_DISPLAY_WIDTH, MAX_DISPLAY_HEIGHT);
	// Print a message to the LCD.
	lcd.print("	 Please	 Wait	 ");
	
	pinMode(LASER_PIN, INPUT);
	digitalWrite(LASER_PIN, HIGH); // enable internal pullup
	
	pinMode(LASER_POWER_PIN, INPUT);
	digitalWrite(LASER_POWER_PIN, HIGH);
	
	read_odo();
	
	time_last = millis();
}

void loop() 
{
	static unsigned char rfidByteIndex = 0;
	static unsigned char rfid[RFID_CODE_LENGTH];
	unsigned char rfidByte;
	static unsigned char rfidFlag = 0;
	
	static unsigned char serialCommand = 0;
	static unsigned char serialDisplayBuffer[MAX_DISPLAY_WIDTH + 1];
	static unsigned char serialDisplayBufferIndex = 0;
	unsigned char serialByte;
	static unsigned long lastIndicatorTime = 0;
	static unsigned long lastWriteTime = time_total;
	// accumulated fractional time in ms
	static unsigned long time_ms = 0;
	
	if (Serial.available() > 0) 
	{
		serialByte = Serial.read();
	 
		switch (serialCommand) 
		{
			case 'e':
					// enable laser
					if (serialByte == '\n') 
					{
						digitalWrite(ENABLE_PIN, HIGH);
						serialCommand = 0;
					}
					break;
			case 'd':
					// disable laser
					if (serialByte == '\n') 
					{
						digitalWrite(ENABLE_PIN, LOW);
						serialCommand = 0;
					}
					break;
			case 'p':
			case 'q':
					// display a message
					// p = first line, q = second line
					if (serialByte == '\n') 
					{
						// buffer is full, terminate it and display the message
						serialDisplayBuffer[serialDisplayBufferIndex] = 0;
						
						lcd.setCursor(0, (serialCommand == 'p') ? 0 : 1);
						lcd.print((char*)serialDisplayBuffer);
						
						// clear rest of line
						while (serialDisplayBufferIndex++ < MAX_DISPLAY_WIDTH)
							lcd.print(" ");
						
						serialDisplayBufferIndex = 0;
						serialCommand = 0;
					} 
					else 
					{
						// append data to buffer
						if (serialDisplayBufferIndex < MAX_DISPLAY_WIDTH)
							serialDisplayBuffer[serialDisplayBufferIndex++] = serialByte;
					}
					break;
			case 'o':
					// report status: odometer and rfid scanned flag
					if (serialByte == '\n') 
					{
						Serial.print("o");
						Serial.print(time_total + (time_ms+500)/1000);
						Serial.print("x");
						Serial.print(rfidFlag);
						Serial.print("\n");
						serialCommand = 0;
					}
					break;
			case 'r':
					// report RFID access
					if (serialByte == '\n') 
					{
						if (rfidFlag) 
						{
							Serial.print("r");
							Serial.write(rfid, RFID_CODE_LENGTH);
							rfidFlag = 0;
						}
						Serial.print("\n");
					}
					serialCommand = 0;
					break;
			default:
				// ignore unknown commands
				serialCommand = serialByte;
				break;
		}
	 
	}
	
	if (Uart.available() > 0) 
	{
		rfidByte = Uart.read();
		if (rfidByte == RFID_CODE_START) 
		{
			rfidByteIndex = 0;
		} 
		else if (rfidByteIndex < RFID_CODE_LENGTH) 
		{
			rfid[rfidByteIndex++] = rfidByte;
		} 
		else if (rfidByte == RFID_CODE_END) 
		{
			// done reading RFID
			rfidFlag = 1;
			// flash the backlight to indicate success
			digitalWrite(BACKLIGHT_PIN, LOW);
			delay(250);
			digitalWrite(BACKLIGHT_PIN, HIGH);
		}
	}
	
	if((digitalRead(LASER_PIN) == LASER_PIN_FIRING) &&
	   (digitalRead(LASER_POWER_PIN) == LASER_PIN_PWR_ON)) 
	{
		time_ms += millis() - time_last;
		time_total += time_ms / 1000;
		time_ms = time_ms % 1000;
		lastIndicatorTime = millis();
	}
	// save the odometer if either the accumulated laser time is >30s or 
	// the laser hasn't fired in 30s and the last value isn't accurate
	if(time_total - lastWriteTime > MIN_SAVE_INTERVAL 
		|| (time_total != lastWriteTime && 
			(millis()-lastIndicatorTime)/1000 > MIN_SAVE_INTERVAL))
	{
		write_odo();
		lastWriteTime = time_total;
	}
	
	time_last = millis();
		
	lcd.setCursor(7,1);
	if((millis() - lastIndicatorTime) < SPINNER_TIME*1000) 
	{
		switch(time_ms / 250) 
		{
			case 0: lcd.print('|'); break;
			case 1: lcd.print('/'); break;
			case 2: lcd.print('-'); break;
			case 3: lcd.print('\\'); break;
		}
	}
}
