#include <SPI.h>
#include <SD.h>


// --- Detector tuning --------------------------------------------------------
const uint16_t SAMPLE_RATE_HZ = 3200;
const uint16_t PWM_REFRESH_HZ = 1920;  // cut sheet says 1.9 kHz
// UBL12H fixtures dim with 1920 Hz PWM. A fast EMA around 80 Hz reacts quickly
// enough to catch visible flicker while still rejecting the carrier ripple.
const uint8_t FAST_N = 3;
// Slow EMA baseline: roughly a 1-2 second trailing average that adapts to fades
// and dimming without chasing the short dips we want to detect.
const uint8_t SLOW_N = 12;
// Dip/recovery thresholds are ratio-based so the detector follows the baseline
// instead of depending on an absolute light level.
const uint8_t THRESHOLD_DIP_PCT = 83;  // vs. MIN_CONSECUTIVE_LOW_SAMPLES
const uint8_t THRESHOLD_DEEP_DIP_PCT = 79;  // vs. MIN_CONSECUTIVE_DEEP_LOW_SAMPLES
const uint8_t THRESHOLD_RECOVER_PCT = 96;
const uint8_t MIN_COUNTED_DIP_PCT = 78;  // flicker isn't counted unless it gets this low
// Require multiple consecutive low samples so a PWM valley does not count as a
// real flicker.
const uint8_t PWM_SAMPLES_PER_CYCLE =
  (SAMPLE_RATE_HZ + PWM_REFRESH_HZ - 1) / PWM_REFRESH_HZ;
// Standard dips need one extra sample beyond a PWM cycle for stronger noise
// rejection. Deep dips can trigger at one-cycle length to preserve sensitivity
// to short but severe flickers.
const uint8_t MIN_CONSECUTIVE_LOW_SAMPLES = PWM_SAMPLES_PER_CYCLE + 1;
const uint8_t MIN_CONSECUTIVE_DEEP_LOW_SAMPLES = PWM_SAMPLES_PER_CYCLE;
const uint16_t STARTUP_SUPPRESS_MS = 10000UL;
const uint32_t STARTUP_SUPPRESS_SAMPLES =
  (uint32_t)SAMPLE_RATE_HZ * STARTUP_SUPPRESS_MS / 1000UL;
// If the light stays low for a full second, classify it as a blackout/fade and
// let the baseline continue adapting.
const uint16_t DIP_TIMEOUT_MS = 1000;
const uint16_t MAX_DIP_SAMPLES = (SAMPLE_RATE_HZ * DIP_TIMEOUT_MS) / 1000UL;

// --- Hardware pins ----------------------------------------------------------
const int chipSelect = 4;
const int statusLed = 7;
const uint8_t SENSOR_COUNT = 2;
const uint8_t sensorPins[SENSOR_COUNT] = {A0, A1};

const unsigned long LOG_INTERVAL_MS = 1000UL;
const unsigned long ONE_DAY_MS = 24UL * 60UL * 60UL * 1000UL;
const uint16_t TIMER1_TARGET_HZ = SAMPLE_RATE_HZ;
// Timer1 uses CS12:CS11:CS10 = 0:1:0 in configureTimer1() (CS11 set only),
// which is the datasheet's /8 prescaler mode. That makes a 16 MHz Uno tick
// Timer1 at 2 MHz, so OCR1A can be set to 624 for a 3200 Hz ISR cadence.
const uint8_t TIMER1_PRESCALER = 8;
// On an Uno, F_CPU is 16 MHz. With an 8x prescaler, Timer1 ticks at 2 MHz,
// so 2,000,000 / 3200 - 1 = 624.
const uint16_t TIMER1_TOP = (F_CPU / (TIMER1_PRESCALER * TIMER1_TARGET_HZ)) - 1;

static_assert(TIMER1_PRESCALER == 8,
              "TIMER1_PRESCALER must match CS12:CS11:CS10 = 0:1:0 (/8 mode).");
static_assert((F_CPU % (TIMER1_PRESCALER * TIMER1_TARGET_HZ)) == 0,
              "Timer1 divisor must divide F_CPU exactly for stable ISR cadence.");
static_assert(TIMER1_TOP == 624,
              "Expected Uno Timer1 TOP is 624 for 3200 Hz ISR at 16 MHz with /8 prescaler.");
static_assert(TIMER1_TOP <= 0xFFFF,
              "TIMER1_TOP must fit in the 16-bit OCR1A register.");
static_assert(THRESHOLD_DIP_PCT < THRESHOLD_RECOVER_PCT,
              "Dip threshold must be below recovery threshold.");
static_assert(THRESHOLD_DEEP_DIP_PCT <= THRESHOLD_DIP_PCT,
              "Deep dip threshold must be less than or equal to dip threshold.");
static_assert(MIN_COUNTED_DIP_PCT <= THRESHOLD_DEEP_DIP_PCT,
              "Counted dip threshold must be at or below deep-dip threshold.");
static_assert(MIN_CONSECUTIVE_LOW_SAMPLES >= 3,
              "Minimum low samples must reject PWM valleys at reduced sample rates.");
static_assert(MIN_CONSECUTIVE_DEEP_LOW_SAMPLES >= 2,
              "Deep dip gate still needs at least two consecutive low samples.");

File logFile;
char currentFileName[13];
int fileIndex = 0;
unsigned long lastLogTime_ms = 0;
unsigned long lastBlinkTime_ms = 0;
unsigned long lastRolloverTime_ms = 0;
bool ledState = LOW;

enum DetectionState : uint8_t {
  STATE_ARMED = 0,
  STATE_IN_DIP = 1,
};

struct SensorRuntime {
  uint8_t address;
  uint8_t pin;
  volatile int32_t fastAccumulator;
  volatile int32_t slowAccumulator;
  volatile uint16_t baselineLight;
  volatile uint16_t readCount;
  volatile uint16_t flickerCount;
  volatile uint8_t minRatio_pct;
  volatile uint8_t state;
  volatile uint8_t lowCount;
  volatile uint8_t deepLowCount;
  volatile uint16_t dipSampleCount;
  volatile uint8_t currentDipMin_pct;
  volatile uint32_t sampleCountSinceBoot;
};

struct SensorSnapshot {
  uint8_t address;
  uint16_t baselineLight;
  uint16_t readCount;
  uint16_t flickerCount;
  uint8_t minRatio_pct;
};

SensorRuntime sensors[SENSOR_COUNT];
SensorSnapshot snapshots[SENSOR_COUNT];

void triggerError() {
  Serial.println("SYSTEM ERROR. Halting.");
  digitalWrite(statusLed, HIGH);
  while (true) {
    delay(10);
  }
}

void resetSensorSecondCounters(SensorRuntime &sensor) {
  sensor.readCount = 0;
  sensor.flickerCount = 0;
  sensor.minRatio_pct = 100;
}

void configureAdcForIsrSampling() {
  // Two analogRead() calls run inside a 3200 Hz ISR. The default ADC /128 clock
  // can overrun that budget and starve loop(). Use /32 for extra headroom.
  // This trades some ADC precision for timing margin, which is acceptable here
  // because the detector uses relative EMA ratios rather than absolute lux.
  ADCSRA = (ADCSRA & ~(_BV(ADPS2) | _BV(ADPS1) | _BV(ADPS0))) | _BV(ADPS2) | _BV(ADPS0);
}

void initializeSensor(SensorRuntime &sensor, uint8_t address, uint8_t pin) {
  sensor.address = address;
  sensor.pin = pin;

  uint16_t initialLight = analogRead(pin);
  sensor.fastAccumulator = (int32_t)initialLight << FAST_N;
  sensor.slowAccumulator = (int32_t)initialLight << SLOW_N;
  sensor.baselineLight = initialLight;
  sensor.readCount = 0;
  sensor.flickerCount = 0;
  sensor.minRatio_pct = 100;
  sensor.state = STATE_ARMED;
  sensor.lowCount = 0;
  sensor.deepLowCount = 0;
  sensor.dipSampleCount = 0;
  sensor.currentDipMin_pct = 100;
  sensor.sampleCountSinceBoot = 0;
}

void initializeSensors() {
  for (uint8_t i = 0; i < SENSOR_COUNT; i++) {
    initializeSensor(sensors[i], i, sensorPins[i]);
  }
}

void createNewLogFile() {
  while (true) {
    sprintf(currentFileName, "LOG_%03d.CSV", fileIndex);
    if (!SD.exists(currentFileName)) {
      break;
    }
    fileIndex++;
  }

  logFile = SD.open(currentFileName, FILE_WRITE);
  if (!logFile) {
    Serial.print("Error creating ");
    Serial.println(currentFileName);
    triggerError();
  }

  logFile.println("Uptime_s,Address,Baseline_Light,Read_Count,Flicker_Count,Min_Ratio_Pct");
  logFile.close();
  Serial.print("Created new log file: ");
  Serial.println(currentFileName);
}

void configureTimer1() {
  noInterrupts();
  TCCR1A = 0;
  TCCR1B = 0;
  TCNT1 = 0;
  OCR1A = TIMER1_TOP;
  TCCR1B |= _BV(WGM12);
  TCCR1B |= _BV(CS11);
  TIMSK1 |= _BV(OCIE1A);
  interrupts();
}

void validateTimer1ConfigOrHalt() {
  // Ensure register-level timer setup matches the constants above.
  if (OCR1A != TIMER1_TOP) {
    Serial.println(F("Timer1 config mismatch: OCR1A"));
    triggerError();
  }

  if ((TCCR1B & (_BV(CS12) | _BV(CS11) | _BV(CS10))) != _BV(CS11)) {
    Serial.println(F("Timer1 config mismatch: prescaler bits"));
    triggerError();
  }

  if ((TCCR1B & _BV(WGM12)) == 0) {
    Serial.println(F("Timer1 config mismatch: CTC mode"));
    triggerError();
  }
}

void updateSensorState(SensorRuntime &sensor, uint16_t currentLight) {
  int32_t fastDelta = (int32_t)currentLight - (sensor.fastAccumulator >> FAST_N);
  int32_t slowDelta = (int32_t)currentLight - (sensor.slowAccumulator >> SLOW_N);

  sensor.fastAccumulator += fastDelta;
  sensor.slowAccumulator += slowDelta;

  uint16_t fastLight = (uint16_t)(sensor.fastAccumulator >> FAST_N);
  uint16_t slowLight = (uint16_t)(sensor.slowAccumulator >> SLOW_N);

  sensor.baselineLight = slowLight;
  sensor.readCount++;
  sensor.sampleCountSinceBoot++;

  uint8_t ratio_pct = 100;
  if (slowLight > 10) {
    ratio_pct = (uint8_t)((fastLight * 100UL) / slowLight);
  }
  if (ratio_pct > 100) {
    ratio_pct = 100;
  }

  if (ratio_pct < sensor.minRatio_pct) {
    sensor.minRatio_pct = ratio_pct;
  }

  if (sensor.state == STATE_ARMED) {
    if (ratio_pct <= THRESHOLD_DIP_PCT) {
      sensor.lowCount++;
    } else {
      sensor.lowCount = 0;
    }

    if (ratio_pct <= THRESHOLD_DEEP_DIP_PCT) {
      sensor.deepLowCount++;
    } else {
      sensor.deepLowCount = 0;
    }

    if (sensor.lowCount >= MIN_CONSECUTIVE_LOW_SAMPLES ||
        sensor.deepLowCount >= MIN_CONSECUTIVE_DEEP_LOW_SAMPLES) {
        sensor.state = STATE_IN_DIP;
        sensor.dipSampleCount = sensor.lowCount;
        if (sensor.deepLowCount > sensor.dipSampleCount) {
          sensor.dipSampleCount = sensor.deepLowCount;
        }
        sensor.currentDipMin_pct = ratio_pct;
    }
    return;
  }

  sensor.dipSampleCount++;
  if (ratio_pct < sensor.currentDipMin_pct) {
    sensor.currentDipMin_pct = ratio_pct;
  }

  if (ratio_pct >= THRESHOLD_RECOVER_PCT) {
    if (sensor.dipSampleCount < MAX_DIP_SAMPLES) {
      if (sensor.sampleCountSinceBoot >= STARTUP_SUPPRESS_SAMPLES &&
          sensor.currentDipMin_pct <= MIN_COUNTED_DIP_PCT) {
        sensor.flickerCount++;
        if (sensor.currentDipMin_pct < sensor.minRatio_pct) {
          sensor.minRatio_pct = sensor.currentDipMin_pct;
        }
      }
    }

    sensor.state = STATE_ARMED;
    sensor.lowCount = 0;
    sensor.deepLowCount = 0;
    sensor.dipSampleCount = 0;
    sensor.currentDipMin_pct = 100;
    return;
  }

  if (sensor.dipSampleCount >= MAX_DIP_SAMPLES) {
    sensor.state = STATE_ARMED;
    sensor.lowCount = 0;
    sensor.deepLowCount = 0;
    sensor.dipSampleCount = 0;
    sensor.currentDipMin_pct = 100;
  }
}

ISR(TIMER1_COMPA_vect) {
  for (uint8_t i = 0; i < SENSOR_COUNT; i++) {
    uint16_t currentLight = analogRead(sensors[i].pin);
    updateSensorState(sensors[i], currentLight);
  }
}

void writeSensorRow(File &file, const SensorSnapshot &snapshot, unsigned long uptimeSeconds) {
  file.print(uptimeSeconds);
  file.print(",");
  file.print(snapshot.address);
  file.print(",");
  file.print(snapshot.baselineLight);
  file.print(",");
  file.print(snapshot.readCount);
  file.print(",");
  file.print(snapshot.flickerCount);
  file.print(",");
  file.println(snapshot.minRatio_pct);

  Serial.print("File: ");
  Serial.print(currentFileName);
  Serial.print(" | Addr: ");
  Serial.print(snapshot.address);
  Serial.print(" | Uptime: ");
  Serial.print(uptimeSeconds);
  Serial.print("s | Baseline: ");
  Serial.print(snapshot.baselineLight);
  Serial.print(" | Reads/sec: ");
  Serial.print(snapshot.readCount);
  Serial.print(" | Flickers/sec: ");
  Serial.print(snapshot.flickerCount);
  Serial.print(" | Min ratio: ");
  Serial.println(snapshot.minRatio_pct);
}

void copyAndResetSecondCounters() {
  noInterrupts();
  for (uint8_t i = 0; i < SENSOR_COUNT; i++) {
    snapshots[i].address = sensors[i].address;
    snapshots[i].baselineLight = sensors[i].baselineLight;
    snapshots[i].readCount = sensors[i].readCount;
    snapshots[i].flickerCount = sensors[i].flickerCount;
    snapshots[i].minRatio_pct = sensors[i].minRatio_pct;
    resetSensorSecondCounters(sensors[i]);
  }
  interrupts();
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

  configureAdcForIsrSampling();

  initializeSensors();
  createNewLogFile();

  lastLogTime_ms = millis();
  lastBlinkTime_ms = lastLogTime_ms;
  lastRolloverTime_ms = lastLogTime_ms;

  configureTimer1();
  validateTimer1ConfigOrHalt();
  Serial.println("System armed. Timer1 ISR sampling at 3200 Hz.");
}

void loop() {
  unsigned long currentTime_ms = millis();

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

  // 3. ONE-SECOND LOGGING INTERVAL (WITH CATCH-UP AFTER STALLS)
  if (currentTime_ms - lastLogTime_ms >= LOG_INTERVAL_MS) {
    lastLogTime_ms += LOG_INTERVAL_MS;

    // 4. SNAPSHOT ISR COUNTERS FOR A CONSISTENT PER-SECOND ROW
    copyAndResetSecondCounters();

    // 5. APPEND ONE ROW PER SENSOR TO THE ACTIVE LOG FILE
    unsigned long uptimeSeconds = currentTime_ms / 1000UL;
    logFile = SD.open(currentFileName, FILE_WRITE);
    if (!logFile) {
      Serial.println("Error writing to file during loop");
      triggerError();
    }

    for (uint8_t i = 0; i < SENSOR_COUNT; i++) {
      writeSensorRow(logFile, snapshots[i], uptimeSeconds);
    }
    logFile.close();
  }
}
