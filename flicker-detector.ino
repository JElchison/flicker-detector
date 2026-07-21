#include <SPI.h>
#include <SD.h>

// Pin assignments
const int chipSelect = 4;
const int lightPin = A0;
const int statusLed = 7; // External LED for heartbeat

File logFile;

// Variables to track data over a 1-second window
int minVal = 1023;
int maxVal = 0;
unsigned long sumVal = 0;
unsigned long readCount = 0;

// Non-blocking timer variables
unsigned long lastLogTimeMs = 0;
unsigned long lastBlinkTimeMs = 0;
bool ledState = LOW;

// Daily Rollover Variables
const unsigned long ONE_DAY_MS = (unsigned long) (24UL * 60UL * 60UL * 1000UL); // 24 hours in milliseconds
unsigned long lastRolloverTimeMs = 0;
char currentFileName[13]; // Buffer to hold "LOG_XXX.CSV"
int fileIndex = 0;

// Helper function to trigger the error state
void triggerError() {
  Serial.println("SYSTEM ERROR. Halting.");
  digitalWrite(statusLed, HIGH); // Solid ON for error
  while (1) {
    delay(10);
  }
}

// Function to generate the next available filename and write the header
void createNewLogFile() {
  while (true) {
    sprintf(currentFileName, "LOG_%03d.CSV", fileIndex);
    if (!SD.exists(currentFileName)) {
      break;
    }
    fileIndex++;
  }

  logFile = SD.open(currentFileName, FILE_WRITE);
  if (logFile) {
    // Just the clean CSV column headers, no extra text
    logFile.println("Uptime_s,Min_Light,Max_Light,Avg_Light,Read_Count");
    logFile.close();

    Serial.print("Created new log file: ");
    Serial.println(currentFileName);
  } else {
    Serial.print("Error creating ");
    Serial.println(currentFileName);
    triggerError();
  }
}

void setup() {
  Serial.begin(115200);

  pinMode(statusLed, OUTPUT);
  digitalWrite(statusLed, LOW);

  // Disable the Ethernet controller by pulling Pin 10 HIGH
  pinMode(10, OUTPUT);
  digitalWrite(10, HIGH);

  Serial.print("Initializing SD card...");
  if (!SD.begin(chipSelect)) {
    Serial.println("Card failed, or not present.");
    triggerError();
  }
  Serial.println("SD card initialized.");

  createNewLogFile();
}

void loop() {
  unsigned long currentTimeMs = millis();

  // 1. NON-BLOCKING LED HEARTBEAT (1 Hz)
  if (currentTimeMs - lastBlinkTimeMs >= 500) {
    lastBlinkTimeMs = currentTimeMs;
    ledState = !ledState;
    digitalWrite(statusLed, ledState);
  }

  // 2. CHECK FOR 24-HOUR FILE ROLLOVER
  if (currentTimeMs - lastRolloverTimeMs >= ONE_DAY_MS) {
    lastRolloverTimeMs = currentTimeMs;
    fileIndex++;
    createNewLogFile();
  }

  // 3. READ LIGHT SENSOR
  int currentLight = analogRead(lightPin);

  if (currentLight < minVal) { minVal = currentLight; }
  if (currentLight > maxVal) { maxVal = currentLight; }
  sumVal += currentLight;
  readCount++;

  // 4. LOG DATA EVERY 1 SECOND
  if (currentTimeMs - lastLogTimeMs >= 1000) {
    lastLogTimeMs = currentTimeMs;

    // Convert milliseconds to seconds for logging
    unsigned long currentTimeSeconds = currentTimeMs / 1000;

    int avgVal = (readCount == 0) ? 0 : (sumVal / readCount);

    logFile = SD.open(currentFileName, FILE_WRITE);
    if (logFile) {
      logFile.print(currentTimeSeconds);
      logFile.print(",");
      logFile.print(minVal);
      logFile.print(",");
      logFile.print(maxVal);
      logFile.print(",");
      logFile.print(avgVal);
      logFile.print(",");
      logFile.println(readCount); // Hz
      logFile.close();
    } else {
      Serial.println("Error writing to file during loop");
      triggerError();
    }

    Serial.print("File: "); Serial.print(currentFileName);
    Serial.print(" | Uptime: "); Serial.print(currentTimeSeconds);
    Serial.print("s | Min: "); Serial.print(minVal);
    Serial.print(" | Max: "); Serial.print(maxVal);
    Serial.print(" | Avg: "); Serial.print(avgVal);
    Serial.print(" | Reads: "); Serial.println(readCount);

    // Reset aggregates for the next second
    minVal = 1023;
    maxVal = 0;
    sumVal = 0;
    readCount = 0;
  }
}
