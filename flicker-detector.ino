#include <SPI.h>
#include <SD.h>


// --- FIXTURE-SPECIFIC CONSTANTS ---
// ADJ UBL12H PWM Refresh Rate = 1.9KHz (1 cycle = ~526 microseconds).
// We need a window slightly larger than one cycle to absorb the dithering.
// 2000us (2 milliseconds) safely captures ~3.8 cycles for a highly stable average.
const unsigned long WINDOW_SIZE_US = 2000;

// Pin assignments
const int chipSelect = 4;
const int lightPin = A0;
const int statusLed = 7; // External LED for heartbeat

File logFile;

// 1-Second Aggregates
int minVal = 1023;  // analog max
int maxVal = 0;  // analog min
unsigned long sumVal = 0;
unsigned long readCount = 0;

// Tumbling Window Variables
unsigned long windowStartTime_us = 0;
unsigned long windowSum = 0;
unsigned int windowReads = 0;

// Non-blocking timer variables
unsigned long lastLogTime_ms = 0;
unsigned long lastBlinkTime_ms = 0;
bool ledState = LOW;

// Daily Rollover Variables
const unsigned long ONE_DAY_MS = (unsigned long) (24UL * 60UL * 60UL * 1000UL); // 24 hours in milliseconds
unsigned long lastRolloverTime_ms = 0;
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

  // Initialize the microsecond timer
  windowStartTime_us = micros();
}

void loop() {
  unsigned long currentTime_ms = millis();
  unsigned long currentTime_us = micros();

  // 1. NON-BLOCKING LED HEARTBEAT (1 Hz)
  if (currentTime_ms - lastBlinkTime_ms >= 500) {
    lastBlinkTime_ms = currentTime_ms;
    ledState = !ledState;
    digitalWrite(statusLed, ledState);
  }

  // 2. CHECK FOR 24-HOUR FILE ROLLOVER
  if (currentTime_ms - lastRolloverTime_ms >= ONE_DAY_MS) {
    lastRolloverTime_ms = currentTime_ms;
    fileIndex++;
    createNewLogFile();
  }

  // 3. READ LIGHT SENSOR
  int currentLight = analogRead(lightPin);

  // Add to the global 1-second total (for the Avg_Light column)
  sumVal += currentLight;
  readCount++;

  // Add to the micro-window bucket
  windowSum += currentLight;
  windowReads++;

  // 4. EVALUATE TUMBLING WINDOW
  // If the micro-bucket has reached its time limit
  if (currentTime_us - windowStartTime_us >= WINDOW_SIZE_US) {

    // Calculate the smoothed brightness over the last window
    int windowAvg = (windowReads == 0) ? 0 : (windowSum / windowReads);

    // Update the 1-second Min/Max using the smoothed values, not raw reads
    if (windowAvg < minVal) { minVal = windowAvg; }
    if (windowAvg > maxVal) { maxVal = windowAvg; }

    // Reset the bucket for the next window
    windowSum = 0;
    windowReads = 0;
    windowStartTime_us = currentTime_us;
  }

  // 5. LOG DATA EVERY 1 SECOND
  if (currentTime_ms - lastLogTime_ms >= 1000) {
    lastLogTime_ms = currentTime_ms;

    unsigned long currentTime_s = currentTime_ms / 1000;
    int avgVal = (readCount == 0) ? 0 : (sumVal / readCount);

    logFile = SD.open(currentFileName, FILE_WRITE);
    if (logFile) {
      logFile.print(currentTime_s);
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
    Serial.print("Uptime: "); Serial.print(currentTime_s);
    Serial.print("s | Min: "); Serial.print(minVal);
    Serial.print(" | Max: "); Serial.print(maxVal);
    Serial.print(" | Avg: "); Serial.print(avgVal);
    Serial.print(" | Reads: "); Serial.println(readCount);

    // Reset 1-second aggregates
    minVal = 1023;
    maxVal = 0;
    sumVal = 0;
    readCount = 0;
  }
}
