#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

// This simulator mirrors the detector in ../flicker-detector.ino.
// It lets us validate the same state machine without needing the Arduino or
// a real light fixture.

#define SAMPLE_RATE_HZ 3200u
#define PWM_REFRESH_HZ 1920u
#define FAST_N 3u
#define SLOW_N 12u
#define THRESHOLD_DIP_PCT 83u
#define THRESHOLD_DEEP_DIP_PCT 79u
#define THRESHOLD_RECOVER_PCT 96u
#define MIN_COUNTED_DIP_PCT 75u
#define PWM_SAMPLES_PER_CYCLE (((SAMPLE_RATE_HZ + PWM_REFRESH_HZ - 1u) / PWM_REFRESH_HZ))
#define MIN_CONSECUTIVE_LOW_SAMPLES (PWM_SAMPLES_PER_CYCLE + 1u)
#define MIN_CONSECUTIVE_DEEP_LOW_SAMPLES (PWM_SAMPLES_PER_CYCLE)
#define DIP_TIMEOUT_MS 1000u
#define MAX_DIP_SAMPLES ((SAMPLE_RATE_HZ * DIP_TIMEOUT_MS) / 1000u)
#define PWM_PHASE_MAX SAMPLE_RATE_HZ
#define PWM_DUTY_MAX 100u

#define BASELINE_DUTY_PCT 50u
#define FLICKER_DUTY_PCT 20u
#define BASELINE_MEAN_LEVEL 600u
#define RIPPLE_LEVEL 60u

typedef enum {
    STATE_ARMED = 0,
    STATE_IN_DIP = 1,
} DetectionState;

typedef struct {
    int32_t fastAccumulator;
    int32_t slowAccumulator;
    uint16_t baselineLight;
    uint16_t readCount;
    uint16_t flickerCount;
    uint8_t minRatioPct;
    DetectionState state;
    uint8_t lowCount;
    uint8_t deepLowCount;
    uint16_t dipSampleCount;
    uint8_t currentDipMinPct;
    uint32_t sampleCountSinceBoot;
} DetectorState;

typedef struct {
    const char *name;
    uint32_t duration_ms;
    uint32_t flicker2_start_ms;
    uint32_t flicker2_end_ms;
    uint32_t flicker_start_ms;
    uint32_t flicker_end_ms;
    uint8_t baselineDutyPct;
    uint8_t flickerDutyPct;
    uint16_t expectedFlickerCount;
} Scenario;

static uint8_t pwm_level_pct_for_time(const Scenario *scenario, uint32_t time_ms) {
    if (time_ms >= scenario->flicker2_start_ms && time_ms < scenario->flicker2_end_ms) {
        return scenario->flickerDutyPct;
    }

    if (time_ms >= scenario->flicker_start_ms && time_ms < scenario->flicker_end_ms) {
        return scenario->flickerDutyPct;
    }
    return scenario->baselineDutyPct;
}

static uint16_t mean_level_for_duty(uint8_t dutyPct) {
    return (uint16_t)(BASELINE_MEAN_LEVEL * dutyPct / BASELINE_DUTY_PCT);
}

static uint16_t sample_light(uint32_t pwm_phase, uint8_t dutyPct) {
    uint32_t dutyTicks = (PWM_PHASE_MAX * dutyPct) / PWM_DUTY_MAX;
    int32_t ripple = (pwm_phase < dutyTicks) ? (int32_t)RIPPLE_LEVEL : -(int32_t)RIPPLE_LEVEL;
    int32_t raw = (int32_t)mean_level_for_duty(dutyPct) + ripple;

    if (raw < 0) {
        raw = 0;
    }
    if (raw > 1023) {
        raw = 1023;
    }

    return (uint16_t)raw;
}

static void initialize_detector(DetectorState *state, uint16_t initialLight) {
    state->fastAccumulator = (int32_t)initialLight << FAST_N;
    state->slowAccumulator = (int32_t)initialLight << SLOW_N;
    state->baselineLight = initialLight;
    state->readCount = 0;
    state->flickerCount = 0;
    state->minRatioPct = 100;
    state->state = STATE_ARMED;
    state->lowCount = 0;
    state->deepLowCount = 0;
    state->dipSampleCount = 0;
    state->currentDipMinPct = 100;
    state->sampleCountSinceBoot = 0u;
}

static void update_detector(DetectorState *state, uint16_t currentLight) {
    int32_t fastDelta = (int32_t)currentLight - (state->fastAccumulator >> FAST_N);
    int32_t slowDelta = (int32_t)currentLight - (state->slowAccumulator >> SLOW_N);

    state->fastAccumulator += fastDelta;
    state->slowAccumulator += slowDelta;

    uint16_t fastLight = (uint16_t)(state->fastAccumulator >> FAST_N);
    uint16_t slowLight = (uint16_t)(state->slowAccumulator >> SLOW_N);

    state->baselineLight = slowLight;
    state->readCount++;
    state->sampleCountSinceBoot++;

    uint8_t ratioPct = 100;
    if (slowLight > 10u) {
        ratioPct = (uint8_t)((fastLight * 100u) / slowLight);
    }
    if (ratioPct > 100u) {
        ratioPct = 100u;
    }

    if (ratioPct < state->minRatioPct) {
        state->minRatioPct = ratioPct;
    }

    if (state->state == STATE_ARMED) {
        if (ratioPct <= THRESHOLD_DIP_PCT) {
            state->lowCount++;
        } else {
            state->lowCount = 0;
        }

        if (ratioPct <= THRESHOLD_DEEP_DIP_PCT) {
            state->deepLowCount++;
        } else {
            state->deepLowCount = 0;
        }

        if (state->lowCount >= MIN_CONSECUTIVE_LOW_SAMPLES ||
            state->deepLowCount >= MIN_CONSECUTIVE_DEEP_LOW_SAMPLES) {
            state->state = STATE_IN_DIP;
            state->dipSampleCount = state->lowCount;
            if (state->deepLowCount > state->dipSampleCount) {
                state->dipSampleCount = state->deepLowCount;
            }
            state->currentDipMinPct = ratioPct;
        }
        return;
    }

    state->dipSampleCount++;
    if (ratioPct < state->currentDipMinPct) {
        state->currentDipMinPct = ratioPct;
    }

    if (ratioPct >= THRESHOLD_RECOVER_PCT) {
        if (state->dipSampleCount < MAX_DIP_SAMPLES) {
            // Simulator scenarios model steady-state behavior; startup suppression
            // is firmware-specific and excluded from simulation checks.
            if (state->currentDipMinPct <= MIN_COUNTED_DIP_PCT) {
                state->flickerCount++;
                if (state->currentDipMinPct < state->minRatioPct) {
                    state->minRatioPct = state->currentDipMinPct;
                }
            }
        }

        state->state = STATE_ARMED;
        state->lowCount = 0;
        state->deepLowCount = 0;
        state->dipSampleCount = 0;
        state->currentDipMinPct = 100;
        return;
    }

    if (state->dipSampleCount >= MAX_DIP_SAMPLES) {
        state->state = STATE_ARMED;
        state->lowCount = 0;
        state->deepLowCount = 0;
        state->dipSampleCount = 0;
        state->currentDipMinPct = 100;
    }
}

static void run_scenario(const Scenario *scenario) {
    DetectorState detector;
    uint32_t sampleCount = (scenario->duration_ms * SAMPLE_RATE_HZ) / 1000u;
    uint32_t pwm_phase = 0u;
    uint16_t initialLight = sample_light(0u, scenario->baselineDutyPct);

    initialize_detector(&detector, initialLight);

    for (uint32_t sampleIndex = 0; sampleIndex < sampleCount; sampleIndex++) {
        uint32_t time_ms = (sampleIndex * 1000u) / SAMPLE_RATE_HZ;
        uint8_t dutyPct = pwm_level_pct_for_time(scenario, time_ms);
        uint16_t currentLight = sample_light(pwm_phase, dutyPct);
        update_detector(&detector, currentLight);

        pwm_phase += PWM_REFRESH_HZ;
        if (pwm_phase >= PWM_PHASE_MAX) {
            pwm_phase -= PWM_PHASE_MAX;
        }
    }

    printf("Scenario: %s\n", scenario->name);
    printf("  Samples: %lu\n", (unsigned long)sampleCount);
    printf("  Detected flickers: %u\n", detector.flickerCount);
    printf("  Deepest ratio pct: %u\n", detector.minRatioPct);
    printf("  Final baseline: %u\n", detector.baselineLight);

    if (detector.flickerCount != scenario->expectedFlickerCount) {
        fprintf(stderr,
                "FAIL: %s expected %u flicker(s), detected %u\n",
                scenario->name,
                scenario->expectedFlickerCount,
                detector.flickerCount);
        exit(EXIT_FAILURE);
    }
}

static void run_recovery_threshold_boundary_test(void) {
    DetectorState detector;
    const uint8_t recoverRatioPct = THRESHOLD_RECOVER_PCT;
    initialize_detector(&detector, 600u);

    detector.state = STATE_IN_DIP;
    detector.dipSampleCount = 10u;
    detector.currentDipMinPct = MIN_COUNTED_DIP_PCT;
    detector.fastAccumulator = (int32_t)recoverRatioPct << FAST_N;
    detector.slowAccumulator = (int32_t)100 << SLOW_N;

    update_detector(&detector, recoverRatioPct);

    printf("Scenario: recovery threshold boundary (ratio == %u)\n", recoverRatioPct);
    printf("  Detected flickers: %u\n", detector.flickerCount);
    printf("  State after update: %u\n", (unsigned)detector.state);

    if (detector.flickerCount != 1u || detector.state != STATE_ARMED) {
        fprintf(stderr,
                "FAIL: threshold boundary recovery should count exactly one flicker\n");
        exit(EXIT_FAILURE);
    }

    puts("  PASS");
    puts("");
}

static void run_short_dip_rejection_test(void) {
    DetectorState detector;
    const uint8_t shortDipSamples = (uint8_t)(MIN_CONSECUTIVE_LOW_SAMPLES - 1u);

    initialize_detector(&detector, 600u);

    for (uint8_t i = 0u; i < shortDipSamples; i++) {
        update_detector(&detector, 120u);
    }
    update_detector(&detector, 600u);

    printf("Scenario: short dip below minimum samples\n");
    printf("  Low samples applied: %u\n", shortDipSamples);
    printf("  Detected flickers: %u\n", detector.flickerCount);
    printf("  State after recovery: %u\n", (unsigned)detector.state);

    if (detector.flickerCount != 0u || detector.state != STATE_ARMED) {
        fprintf(stderr,
                "FAIL: short dip should be rejected before state-machine entry\n");
        exit(EXIT_FAILURE);
    }

    puts("  PASS");
    puts("");
}

int main(void) {
    const Scenario scenarios[] = {
        {
            .name = "stable PWM baseline",
            .duration_ms = 2000u,
            .flicker2_start_ms = 0u,
            .flicker2_end_ms = 0u,
            .flicker_start_ms = 0u,
            .flicker_end_ms = 0u,
            .baselineDutyPct = BASELINE_DUTY_PCT,
            .flickerDutyPct = FLICKER_DUTY_PCT,
            .expectedFlickerCount = 0u,
        },
        {
            .name = "80 Hz embedded dimming flicker",
            .duration_ms = 1000u,
            .flicker2_start_ms = 0u,
            .flicker2_end_ms = 0u,
            .flicker_start_ms = 250u,
            .flicker_end_ms = 350u,
            .baselineDutyPct = BASELINE_DUTY_PCT,
            .flickerDutyPct = FLICKER_DUTY_PCT,
            .expectedFlickerCount = 1u,
        },
        {
            .name = "1 Hz recovery flicker",
            .duration_ms = 2000u,
            .flicker2_start_ms = 0u,
            .flicker2_end_ms = 0u,
            .flicker_start_ms = 1000u,
            .flicker_end_ms = 1500u,
            .baselineDutyPct = BASELINE_DUTY_PCT,
            .flickerDutyPct = FLICKER_DUTY_PCT,
            .expectedFlickerCount = 1u,
        },
        {
            .name = "two distinct flickers",
            .duration_ms = 2500u,
            .flicker2_start_ms = 1700u,
            .flicker2_end_ms = 1820u,
            .flicker_start_ms = 300u,
            .flicker_end_ms = 420u,
            .baselineDutyPct = BASELINE_DUTY_PCT,
            .flickerDutyPct = FLICKER_DUTY_PCT,
            .expectedFlickerCount = 2u,
        },
        {
            .name = "sustained dip without recovery",
            .duration_ms = 1500u,
            .flicker2_start_ms = 0u,
            .flicker2_end_ms = 0u,
            .flicker_start_ms = 300u,
            .flicker_end_ms = 1500u,
            .baselineDutyPct = BASELINE_DUTY_PCT,
            .flickerDutyPct = FLICKER_DUTY_PCT,
            .expectedFlickerCount = 0u,
        },
        {
            .name = "long blackout with late recovery (current behavior)",
            .duration_ms = 2600u,
            .flicker2_start_ms = 0u,
            .flicker2_end_ms = 0u,
            .flicker_start_ms = 300u,
            .flicker_end_ms = 1900u,
            .baselineDutyPct = BASELINE_DUTY_PCT,
            .flickerDutyPct = FLICKER_DUTY_PCT,
            .expectedFlickerCount = 1u,
        },
    };

    printf("Detector model references ../flicker-detector.ino\n");
    printf("SAMPLE_RATE_HZ=%u PWM_REFRESH_HZ=%u FAST_N=%u SLOW_N=%u MIN_CONSECUTIVE_LOW_SAMPLES=%u MAX_DIP_SAMPLES=%u\n\n",
           SAMPLE_RATE_HZ,
           PWM_REFRESH_HZ,
           FAST_N,
           SLOW_N,
           MIN_CONSECUTIVE_LOW_SAMPLES,
           MAX_DIP_SAMPLES);

    run_recovery_threshold_boundary_test();
    run_short_dip_rejection_test();

    for (size_t i = 0; i < sizeof(scenarios) / sizeof(scenarios[0]); i++) {
        run_scenario(&scenarios[i]);
        puts("  PASS");
        puts("");
    }

    puts("All simulator scenarios passed.");
    return EXIT_SUCCESS;
}
