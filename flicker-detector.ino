#include <SPI.h>
#include <SD.h>


// --- FIXTURE-SPECIFIC CONSTANTS ---
// ADJ UBL12H PWM Refresh Rate = 1.9KHz (1 cycle = ~526 microseconds).
// We need a window larger than one cycle to absorb the dithering.
const unsigned long WINDOW_SIZE_US = 10000;

// Pin assignments
const int chipSelect = 4;
const int statusLed = 7; // External LED for heartbeat

const uint8_t SENSOR_COUNT = 2;
const uint8_t sensorPins[SENSOR_COUNT] = {A0, A1};

File logFile;

struct SensorStats {
  uint8_t address;
  uint8_t pin;
  int minVal;
  int maxVal;
  unsigned long sumVal;
  unsigned long readCount;
  unsigned long windowSum;
  unsigned int windowReads;
};

SensorStats sensors[SENSOR_COUNT];

// Shared tumbling-window timer
unsigned long windowStartTime_us = 0;
unsigned long windowCountThisSecond = 0;

// Non-blocking timer variables
unsigned long lastLogTime_ms = 0;
unsigned long lastBlinkTime_ms = 0;
bool ledState = LOW;

// Daily Rollover Variables
const unsigned long ONE_DAY_MS = (unsigned long) (24UL * 60UL * 60UL * 1000UL); // 24 hours in milliseconds
unsigned long lastRolloverTime_ms = 0;
char currentFileName[13]; // Buffer to hold "LOG_XXX.CSV"
int fileIndex = 0;

void resetSecondAggregates(SensorStats &sensor) {
  sensor.minVal = 1023;
  sensor.maxVal = 0;
  sensor.sumVal = 0;
  sensor.readCount = 0;
}

void resetWindowAggregates(SensorStats &sensor) {
  sensor.windowSum = 0;
  sensor.windowReads = 0;
}

void initSensor(SensorStats &sensor, uint8_t address, uint8_t pin) {
  sensor.address = address;
  sensor.pin = pin;
  resetSecondAggregates(sensor);
  resetWindowAggregates(sensor);
}

void initSensors() {
  for (uint8_t i = 0; i < SENSOR_COUNT; i++) {
    initSensor(sensors[i], i, sensorPins[i]);
  }
}

int averageOrZero(unsigned long sum, unsigned long count) {
  return (count == 0) ? 0 : (sum / count);
}

void sampleSensor(SensorStats &sensor) {
  int currentLight = analogRead(sensor.pin);
  sensor.sumVal += currentLight;
  sensor.readCount++;
  sensor.windowSum += currentLight;
  sensor.windowReads++;
}

void applyWindowAverage(SensorStats &sensor) {
  if (sensor.windowReads == 0) {
    return;
  }

  int windowAvg = sensor.windowSum / sensor.windowReads;
  if (windowAvg < sensor.minVal) { sensor.minVal = windowAvg; }
  if (windowAvg > sensor.maxVal) { sensor.maxVal = windowAvg; }
  resetWindowAggregates(sensor);
}

void writeSensorRow(File &file, unsigned long currentTime_s, const SensorStats &sensor, unsigned long windowCount) {
  int avgVal = averageOrZero(sensor.sumVal, sensor.readCount);

  file.print(currentTime_s);
  file.print(",");
  file.print(sensor.address);
  file.print(",");
  file.print(sensor.minVal);
  file.print(",");
  file.print(sensor.maxVal);
  file.print(",");
  file.print(avgVal);
  file.print(",");
  file.print(sensor.readCount); // reads/sec
  file.print(",");
  file.println(windowCount); // windows/sec

  Serial.print("File: "); Serial.print(currentFileName);
  Serial.print(" | Addr: "); Serial.print(sensor.address);
  Serial.print(" | Uptime: "); Serial.print(currentTime_s);
  Serial.print("s | Min: "); Serial.print(sensor.minVal);
  Serial.print(" | Max: "); Serial.print(sensor.maxVal);
  Serial.print(" | Avg: "); Serial.print(avgVal);
  Serial.print(" | Reads/sec: "); Serial.print(sensor.readCount);
  Serial.print(" | Windows/sec: "); Serial.println(windowCount);
}

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
    logFile.println("Uptime_s,Address,Min_Light,Max_Light,Avg_Light,Read_Count,Window_Count");
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

  initSensors();
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

  // 3. READ BOTH LIGHT SENSORS
  for (uint8_t i = 0; i < SENSOR_COUNT; i++) {
    sampleSensor(sensors[i]);
  }

  // 4. EVALUATE TUMBLING WINDOW
  // If the micro-bucket has reached its time limit
  if (currentTime_us - windowStartTime_us >= WINDOW_SIZE_US) {
    for (uint8_t i = 0; i < SENSOR_COUNT; i++) {
      applyWindowAverage(sensors[i]);
    }
    windowCountThisSecond++;
    windowStartTime_us = currentTime_us;
  }

  // 5. LOG DATA EVERY 1 SECOND (single SD open/close cycle)
  if (currentTime_ms - lastLogTime_ms >= 1000) {
    lastLogTime_ms = currentTime_ms;

    unsigned long currentTime_s = currentTime_ms / 1000;

    logFile = SD.open(currentFileName, FILE_WRITE);
    if (logFile) {
      for (uint8_t i = 0; i < SENSOR_COUNT; i++) {
        writeSensorRow(logFile, currentTime_s, sensors[i], windowCountThisSecond);
      }
      logFile.close();
    } else {
      Serial.println("Error writing to file during loop");
      triggerError();
    }

    // Reset per-sensor 1-second aggregates
    for (uint8_t i = 0; i < SENSOR_COUNT; i++) {
      resetSecondAggregates(sensors[i]);
    }
    windowCountThisSecond = 0;
  }
}
