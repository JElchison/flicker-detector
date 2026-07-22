# Flicker Detector

## Overview

This project is an Arduino-based diagnostic tool designed to definitively prove and track high-speed dropouts (flickers) in a DMX LED light fixture over long periods. 

Standard visual observation or low-speed logging can miss microsecond dropouts. To solve this, the microcontroller continuously polls an ultra-fast phototransistor as fast as its processor allows (thousands of times per second). Every second, it calculates the **Minimum**, **Maximum**, and **Average** light levels across that second's sampling window and writes a single line of data to a MicroSD card. 

If the light momentarily flickers, the `Min_Light` value for that second will plummet, leaving an undeniable, timestamped record in the CSV file.

<img width="1231" height="927" alt="image" src="https://github.com/user-attachments/assets/217aab56-abfd-4860-a5b9-d3e3887bdaa6" />

### Handling LED PWM Dimming (The Tumbling Window)
Modern DMX fixtures achieve dimming through Pulse Width Modulation (PWM)—rapidly strobing the LEDs on and off thousands of times per second. For example, a fixture with a 1.9KHz refresh rate completes a full on-off cycle every ~526 microseconds. Because this logger polls the sensor at over 8,000 Hz, it is actually fast enough to "see" the microsecond gaps where the fixture intentionally turns off to dim, which would normally trigger a false flicker alarm. 

To solve this, the code uses a high-speed "Tumbling Window." It chunks the raw sensor reads into 2-millisecond buckets, averaging them together to perfectly smooth out the natural PWM duty cycle. The 1-second minimum and maximum values are then calculated using these smoothed 2ms buckets. This ensures the system ignores standard dimming dithering while still instantly catching any genuine, multi-millisecond hardware dropouts.

## Hardware List

This build uses a "stacked" approach with an Ethernet Shield to avoid needing a breadboard, making the unit compact and durable.

* **Arduino Uno R3** (The main microcontroller)
* **Arduino Ethernet Shield R3** (Used strictly for its built-in MicroSD card slot)
* **[TEMT6000 Light Sensor](https://a.co/d/0hPdW3Q8)** - *Note: The TEMT6000 phototransistor is required over a standard LDR because standard photoresistors react too slowly to catch rapid LED flickers.*
* **MicroSD Card (Max 32GB)** - *Must be formatted to FAT32. The Arduino cannot read exFAT formatted cards (64GB+).*
* **[Jumper Wires](https://a.co/d/01HLrKq2)** - *Used to connect the sensors directly to the top of the stacked shield.*
* **Standard LED (Any color, 3mm or 5mm)** - *Used as a visual status heartbeat.*
* **220-ohm Resistor** - *To safely step down voltage for the LED.*

*Note: You will need a soldering iron to attach the male header pins to the TEMT6000 sensor board before wiring.*

## Assembly & Wiring Guide

1. **Stack the Boards:** Firmly press the Arduino Ethernet Shield R3 down onto the headers of the Arduino Uno R3. All wiring will be done on the top black female headers of the Ethernet Shield.
2. **Insert SD Card:** Push your FAT32-formatted MicroSD card into the slot on the shield.

### The Light Sensor (TEMT6000)
Using three jumper wires, connect the sensor directly to the shield:
* **VCC** -> Shield **5V**
* **GND** -> Shield **GND** *(Use the GND pin next to 5V)*
* **SIG** -> Shield **A0** *(Analog In 0)*

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

To capture a flicker, tape the sensor flat against the light fixture's lens. Plug the Arduino into a USB wall adapter to power it.

The system will automatically create a new file named `LOG_000.CSV` (incrementing on each reboot or every 24 hours). 

When you pull the SD card and open the CSV in Excel or a data analysis tool, you will see a continuous X-axis timeline of system uptime in hours:minutes:seconds (`Uptime_hms`), accompanied by the min, max, and average brightness for that second. The `Read_Count` column tracks system health—it should show roughly the same number of sensor reads every second (i.e., Hz).

To spot a momentary flicker, simply look for severe dips in the `Min_Light` column.

## Data Analysis

To find the exact moments the fixture flickered, use the provided R script (`analyze-csv-for-flickers.R`). This script scans your SD card data, filters out normal operation and intentional power-downs, and isolates the specific seconds where an abrupt drop in light intensity occurred.

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
3. Save the `analyze-csv-for-flickers.R` script into that exact same folder.
4. Open your terminal/command prompt and navigate to that folder:
   ```bash
   cd path/to/your/folder
   ```
5. Execute the script:
   ```bash
   Rscript --vanilla analyze-csv-for-flickers.R
   ```

### Reading the Output
The script will automatically stitch all of your daily log files together in chronological order, run the analysis, and print a summary table directly to your terminal. 

The output will look like this:

```text
# A tibble: 2 × 7
  filename    Uptime_hms Min_Light Max_Light Avg_Light Read_Count is_flicker
  <chr>       <chr>          <dbl>     <dbl>     <dbl>      <dbl> <lgl>
1 LOG_000.CSV 0:05:00          120       822       450       8103 TRUE
2 LOG_000.CSV 1:08:00          110       818       420       8162 TRUE
```

* **filename** & **Uptime_hms:** The exact file and second the flicker occurred.
* **Min_Light:** This number will be exceptionally low (below 150), proving the DMX fixture went dark while the `Max_Light` for that same second confirms it was otherwise supposed to be fully powered on.
