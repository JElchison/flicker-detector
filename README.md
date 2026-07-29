# Flicker Detector

## Overview

This project is an Arduino-based diagnostic tool that detects and records abrupt flickers in a DMX LED light fixture directly on the Uno.

<img width="1231" height="927" alt="image" src="https://github.com/user-attachments/assets/217aab56-abfd-4860-a5b9-d3e3887bdaa6" />

## Design

### Core Constraints

- Hardware boundary: Arduino Uno (ATmega328P, 2KB SRAM, no hardware FPU, no RTC), a light sensor input path, and a FAT32 32GB SD card workflow.
- Fixture boundary: UBL12H wall washes using DMX and roughly 1920 Hz PWM dimming.
- Sampling boundary: approximately 3200 Hz across two sensor channels (reduced from 4000 Hz for stronger ISR timing margin on Uno hardware).
- Logging boundary: sustained 24+ hour runtime with a one-second logging interval for file-size and throughput stability; brief catch-up bursts are possible after main-loop stalls while ISR sampling continues.
- Baseline boundary: absolute brightness thresholds are unreliable because ambient light, time of day, and DMX color/dimming levels shift the baseline continuously.
- Event boundary: a flicker is an abrupt high-low-high dip. Entry/recovery use ratio gates and consecutive-sample requirements; long dips are tracked continuously until recovery (no timeout reset fragmentation).

### Rejected Approaches & Rationale

- 2ms / 10ms / 50ms simple moving averages:
  - Why rejected: a 2 ms window had too much noise.
  - Why rejected: a 10 ms window aliases against 1920 Hz PWM and produces beat artifacts.
  - Why rejected: a 50 ms window reduces aliasing but causes temporal smearing, so short real dips are diluted by surrounding bright samples.
- Non-rolling 1920 Hz window (about 0.521 ms):
  - Why rejected: at 3200 Hz, each PWM period is about 1.667 samples, which forces 1- or 2-sample approximations and unavoidable phase drift.
  - Why rejected: fixture and controller clock drift continuously desynchronize any fixed window alignment.
- Peak tracking / envelope detection:
  - Why rejected: it is robust to PWM phase drift but blind to duty-cycle modulation because dimming changes average energy more than peak amplitude.
- RAM buffering with micros()-paced main-loop sampling:
  - Why rejected: FAT32 SD writes can block for roughly 100-250 ms, creating blind periods if sampling depends on the main loop.

### Rationale for the Chosen Path

- Averaging over peaks: perceived flicker follows average light over time, so the detector tracks average behavior (fast vs slow EMA), not peak voltage.
- Background sampling: sampling and detector math must run in a hardware timer interrupt so SD latency cannot pause measurement.
- Integer-only timing-safe math: ISR calculations use 32-bit accumulators and shifts instead of floating-point operations to keep execution deterministic and fast.

### Final Design Decisions

Hardware Timer1 ISR sampling:

  - Decision: ADC sampling and detector updates run from Timer1 compare interrupts at 3200 Hz (every 312.5 microseconds).
  - Result: deterministic cadence that is effectively immune to SD card write stalls.

Bit-shift dual-EMA implementation:

  - Decision: fast and slow EMA behavior is implemented with 32-bit accumulators and right shifts instead of floating-point division.
  - Result: very low ISR cost and a stable moving baseline that adapts to natural dimming.

Fast EMA tuning for perceptual sensitivity:

  - Decision: FAST_N = 3 was selected to preserve sensitivity to visually distracting higher-frequency stutter while still damping PWM ripple.
  - Result: better alignment with peripheral flicker sensitivity than heavier smoothing.

High-low-high state machine gating:

  - Decision: dips arm below 83% (standard) or 79% (deep path) with consecutive-sample gates, and recover above 96%.
  - Decision: counted dips must also reach 75% or lower at least once, and startup suppression avoids early boot transients.
  - Decision: output filtering suppresses short + shallow rows (Dip_ms < 6 and Min_Ratio_Pct > 70) to reduce nuisance events.
  - Result: single PWM valleys are rejected while sensitivity is preserved for deeper visible dips.

Aggregated once-per-second CSV output:

  - Decision: the main loop logs one summary row per sensor each second.
  - Result: compact long-run logs with Uptime_s, Address, Baseline_Light, Read_Count, Flicker_Count, Min_Ratio_Pct, Dip_Sample_Count, Dip_ms, and Human_Visibility_Score.
  - Note: Dip_ms is computed from Dip_Sample_Count in the same one-second row (Dip_ms ~= Dip_Sample_Count / 3200 * 1000).

Event-only serial diagnostics:

  - Decision: serial prints only rows with Flicker_Count > 0 and inserts a spacer line after >5 s event gaps.
  - Result: easier live review during fixture testing with less serial noise.

## Method

The firmware starts by configuring Timer1, initializing the sensors, and creating a new CSV log file on the SD card. From that point on, the detector stays in the interrupt path and the main loop only handles periodic logging, file rollover, and the status LED.

- `ISR(TIMER1_COMPA_vect)` samples each sensor at a fixed 3200 Hz and updates the fast and slow EMAs.
- The detector computes a fast-vs-slow ratio, then uses a high-low-high state machine to confirm a flicker.
- The firmware keeps per-second counters for `Read_Count`, `Flicker_Count`, the lowest ratio seen in that second, and how many samples fell below the dip threshold.
- On a one-second interval, the main loop copies sensor snapshots and writes compact CSV rows for each input; after delays it may emit short catch-up bursts.
- Before writing, a short+shallow post-filter can suppress rows (`Dip_ms < 6` and `Min_Ratio_Pct > 70`) to reduce nuisance detections.
- On reboot or after 24 hours, the logger creates the next `LOG_XXX.CSV` file and continues without changing the detector logic.

### Handling LED PWM Dimming
Modern DMX fixtures achieve dimming through Pulse Width Modulation (PWM)—rapidly strobing the LEDs on and off thousands of times per second. For example, a fixture with a 1.9 kHz refresh rate completes a full on-off cycle every ~526 microseconds. The detector does not try to infer flickers from min/max extrema inside a wide window. Instead, it watches a fast EMA against a slow EMA and looks for a brief ratio dip that then recovers.

## Hardware List

This build uses a "stacked" approach with an Ethernet Shield to avoid needing a breadboard, making the unit compact and durable.

* **Arduino Uno R3** (The main microcontroller)
* **Arduino Ethernet Shield R3** (Used strictly for its built-in MicroSD card slot)
* **1x or 2x [TEMT6000 Light Sensor](https://a.co/d/0hPdW3Q8)** - *Note: The TEMT6000 phototransistor is required over a standard LDR because standard photoresistors react too slowly to catch rapid LED flickers.*
* **MicroSD Card (Max 32GB)** - *Must be formatted to FAT32. The Arduino cannot read exFAT formatted cards (64GB+).*
* **[Jumper Wires](https://a.co/d/01HLrKq2)** - *Used to connect the sensors directly to the top of the stacked shield.*
* **Standard LED (Any color, 3mm or 5mm)** - *Used as a visual status heartbeat.*
* **220-ohm Resistor** - *To safely step down voltage for the LED.*

*Note: You will need a soldering iron to attach the male header pins to the TEMT6000 sensor board before wiring.*

## Assembly & Wiring Guide

1. **Stack the Boards:** Firmly press the Arduino Ethernet Shield R3 down onto the headers of the Arduino Uno R3. All wiring will be done on the top black female headers of the Ethernet Shield.
2. **Insert SD Card:** Push your FAT32-formatted MicroSD card into the slot on the shield.

### The Light Sensors (TEMT6000)
Use two sensors so you can monitor two fixture points/channels at once. The logger writes each sensor as a separate row with an `Address` value.

#### Sensor Address 0 (A0)
* **VCC** -> Shield **5V**
* **GND** -> Shield **GND** *(Use the GND pin next to 5V)*
* **SIG** -> Shield **A0** *(Analog In 0, logged as `Address=0`)*

#### Sensor Address 1 (A1)
* **VCC** -> Shield **5V**
* **GND** -> Shield **GND** *(Any shared GND is fine)*
* **SIG** -> Shield **A1** *(Analog In 1, logged as `Address=1`)*

### The Status Heartbeat (External LED)
This LED will blink at 1Hz when the system is logging correctly, or lock on a solid light if there is an SD card error. To wire it inline without a breadboard:
* Take two jumper wires and plug the male ends into the shield at **Pin 7** and **GND** *(the GND near Pin 13)*.
* Push one leg of the **220-ohm resistor** into the female socket of the **Pin 7** wire.
* Twist the other leg of the resistor tightly around the **Long Leg (Anode)** of your LED.
* Push the **Short Leg (Cathode)** of the LED into the female socket of the **GND** wire.
* *Safety tip: Wrap the exposed twisted metal in a small piece of electrical tape so it cannot bend and short against the shield's metal Ethernet jack.*

## Software & Setup

1. Assemble the hardware.
2. Connect the Arduino Uno to your computer via USB.
3. Open the [Arduino IDE](https://www.arduino.cc/en/software/). Both required libraries (`SPI.h` and `SD.h`) are built directly into the IDE.
4. Upload the project's source code (`.ino` file) to the Arduino.

## Reading the Data

To capture a flicker, tape each sensor flat against a light fixture lens (or two different fixtures/channels). Plug the Arduino into a USB wall adapter to power it.

The system will automatically create a new file named `LOG_000.CSV` (incrementing on each reboot or every 24 hours). 

Each CSV row now includes an `Address` column:
* `Address=0` corresponds to **A0**
* `Address=1` corresponds to **A1**

`Uptime_s` in the CSV is raw uptime in seconds. The R script converts this into `Uptime_hms` for human-readable reporting.

The `Read_Count` column tracks system health per address - it should show roughly the same number of sensor reads every second.

The `Flicker_Count` column records how many high-low-high events were confirmed in that second (after short+shallow row filtering).

The `Min_Ratio_Pct` column records the deepest ratio dip seen that second, where lower numbers mean a more severe flicker.

The `Dip_Sample_Count` column records how many ISR samples in that second were at or below the dip threshold.

The `Dip_ms` column converts `Dip_Sample_Count` to milliseconds for that same second.

`Human_Visibility_Score` is a 0-100 heuristic combining depth, dip duration, and flicker count.

## Data Analysis

The Arduino now does the actual flicker detection. The provided R script (`summarize-firmware-flicker-logs.R`) is optional and only helps summarize the already-classified CSV logs.

### Prerequisites
You will need to have [R](https://cran.r-project.org/) installed on your computer. 

You will also need to install the required libraries. Open your R console or RStudio and run this once:
```r
install.packages(c("dplyr", "readr", "purrr"))
```

### Running the Analysis
The easiest way to process your data is directly from your computer's terminal or command prompt using `Rscript`.

1. Remove the MicroSD card from your Arduino and plug it into your computer.
2. Copy all of the `LOG_XXX.CSV` files from the SD card into a single folder on your computer.
3. Save the `summarize-firmware-flicker-logs.R` script into that exact same folder.
4. Open your terminal/command prompt and navigate to that folder:
   ```bash
   cd path/to/your/folder
   ```
5. Execute the script:
   ```bash
   Rscript --vanilla summarize-firmware-flicker-logs.R
   ```

### Reading the Output
The script will automatically stitch all of your daily log files together in chronological order and print the rows where `Flicker_Count > 0`.

The output will look like this:

```text
=== Address 0 ===
    filename Uptime_hms Address Baseline_Light Read_Count Flicker_Count Min_Ratio_Pct Dip_Sample_Count Dip_ms Human_Visibility_Score
 LOG_000.CSV    0:05:00       0            450       3202             1            64              180     56                     44
 LOG_000.CSV    1:08:00       0            420       3207             2            58              101     32                     57

=== Address 1 ===
    filename Uptime_hms Address Baseline_Light Read_Count Flicker_Count Min_Ratio_Pct Dip_Sample_Count Dip_ms Human_Visibility_Score
 LOG_000.CSV    0:15:00       1            430       3194             1            61              218     68                     37
 LOG_000.CSV    1:00:00       1            410       3207             1            55              206     64                     75
```

* **filename** & **Uptime_hms:** The exact file and second the flicker occurred.
* **Address:** Which analog input detected it (`0` for A0, `1` for A1).
* **Baseline_Light:** The slow EMA baseline that the fast EMA is compared against.
* **Flicker_Count:** How many valid high-low-high events the Arduino confirmed in that second.
* **Min_Ratio_Pct:** The lowest fast-vs-slow ratio seen that second. Lower numbers mean deeper dips.
* **Dip_Sample_Count / Dip_ms:** How much of that second was under dip threshold, in samples and milliseconds.
* **Human_Visibility_Score:** 0-100 heuristic score to prioritize likely noticeable events.

## Validation

The repository includes a single `test.sh` harness that exercises the important paths end to end.

- `arduino-cli compile --fqbn arduino:avr:uno` verifies the sketch builds for the Uno and fits within flash and SRAM limits.
- `make -C sim test` builds and runs the native C simulator against synthetic flicker scenarios.
- The R scripts are parsed and run against generated firmware-style CSV data, including a rollover boundary case.

If you want to validate only the simulator, run `make -C sim test` from the repo root.
