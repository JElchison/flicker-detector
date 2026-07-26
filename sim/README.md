# Simulator

This directory contains a small C harness that mirrors the detector logic in [../flicker-detector.ino](../flicker-detector.ino).

It simulates PWM-like light levels at 50% dim, injects a brief 80 Hz flicker that drops below 50% and then returns, and also checks that a slower 1 Hz recovery flicker is still detected.

## Run

```bash
make test
```

That builds the simulator and runs it. The executable prints each scenario and exits with a nonzero status if the detector fails to flag an expected flicker.

## Clean

```bash
make clean
```

## Notes

The simulator is intentionally simple. It is not trying to emulate the Arduino hardware cycle-for-cycle; it is validating the detector state machine against synthetic input that resembles the data the firmware is designed to see.
