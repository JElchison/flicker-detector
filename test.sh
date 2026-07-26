#!/bin/bash

set -u -o pipefail

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
FAILED=0
STRICT_LINT="${STRICT_LINT:-0}"

run_check() {
    local label="$1"
    shift

    echo
    echo "==> $label"
    if "$@"; then
        echo "PASS: $label"
    else
        echo "FAIL: $label"
        FAILED=1
    fi
}

skip_check() {
    local label="$1"
    echo
    echo "==> $label"
    echo "SKIP: required tool not found"
}

collect_files() {
    local pattern="$1"
    find "$SCRIPT_DIR" -name "$pattern" -print0
}

run_shellcheck() {
    mapfile -d '' sh_files < <(collect_files "*.sh")
    if [[ "${#sh_files[@]}" -eq 0 ]]; then
        return 0
    fi
    shellcheck "${sh_files[@]}"
}

run_bashate() {
    mapfile -d '' sh_files < <(collect_files "*.sh")
    if [[ "${#sh_files[@]}" -eq 0 ]]; then
        return 0
    fi
    bashate -i E006 "${sh_files[@]}"
}

run_r_parse() {
    mapfile -d '' r_files < <(collect_files "*.R")
    local file
    for file in "${r_files[@]}"; do
        Rscript -e 'parse(file = commandArgs(trailingOnly = TRUE)[1])' "$file"
    done
}

run_r_lintr() {
    mapfile -d '' r_files < <(collect_files "*.R")
    local file
    for file in "${r_files[@]}"; do
        Rscript -e 'f <- commandArgs(trailingOnly = TRUE)[1]; l <- lintr::lint(f, linters = lintr::linters_with_defaults(line_length_linter = NULL)); print(l); if (length(l) > 0 && Sys.getenv("STRICT_LINT") == "1") quit(status = 1)' "$file"
    done
}

run_cppcheck() {
    mapfile -d '' ino_files < <(collect_files "*.ino")
    if [[ "${#ino_files[@]}" -eq 0 ]]; then
        return 0
    fi
    cppcheck --enable=warning,style,performance --language=c++ --std=c++11 \
        --suppress=missingIncludeSystem --suppress=missingInclude \
        "${ino_files[@]}"
}

run_c_simulator() {
    make -C "$SCRIPT_DIR/sim" test && make -C "$SCRIPT_DIR/sim" clean
}

extract_ino_constant() {
    local name="$1"
    local file="$SCRIPT_DIR/flicker-detector.ino"

    sed -n "s/^const [^ ]* ${name} = \([0-9][0-9]*\);.*$/\1/p" "$file" | head -n 1
}

extract_sim_define() {
    local name="$1"
    local file="$SCRIPT_DIR/sim/flicker_sim.c"

    sed -n "s/^#define ${name} \([0-9][0-9]*\)u$/\1/p" "$file" | head -n 1
}

run_sim_constant_sync_check() {
    local names=(
        SAMPLE_RATE_HZ
        PWM_REFRESH_HZ
        FAST_N
        SLOW_N
        THRESHOLD_DIP_PCT
        THRESHOLD_RECOVER_PCT
        DIP_TIMEOUT_MS
    )
    local name
    local ino_value
    local sim_value

    for name in "${names[@]}"; do
        ino_value="$(extract_ino_constant "$name")"
        sim_value="$(extract_sim_define "$name")"

        if [[ -z "$ino_value" || -z "$sim_value" ]]; then
            echo "Unable to extract constant '$name' from .ino or sim source."
            return 1
        fi

        if [[ "$ino_value" != "$sim_value" ]]; then
            echo "Constant drift detected for '$name': .ino=$ino_value sim=$sim_value"
            return 1
        fi
    done

    return 0
}

run_arduino_compile_uno() {
    local output_file
    local flash_bytes
    local flash_max
    local ram_bytes
    local ram_max

    output_file="$(mktemp)"
    if ! arduino-cli compile --fqbn arduino:avr:uno "$SCRIPT_DIR" 2>&1 | tee "$output_file"; then
        rm -f "$output_file"
        return 1
    fi

    flash_bytes="$(sed -n 's/^Sketch uses \([0-9][0-9]*\) bytes.*$/\1/p' "$output_file" | head -n 1)"
    flash_max="$(sed -n 's/^Sketch uses [0-9][0-9]* bytes.*Maximum is \([0-9][0-9]*\) bytes\.$/\1/p' "$output_file" | head -n 1)"
    ram_bytes="$(sed -n 's/^Global variables use \([0-9][0-9]*\) bytes.*$/\1/p' "$output_file" | head -n 1)"
    ram_max="$(sed -n 's/^Global variables use [0-9][0-9]* bytes.*Maximum is \([0-9][0-9]*\) bytes\.$/\1/p' "$output_file" | head -n 1)"

    rm -f "$output_file"

    if [[ -z "$flash_bytes" || -z "$flash_max" || -z "$ram_bytes" || -z "$ram_max" ]]; then
        echo "Unable to parse Uno size output from arduino-cli compile."
        return 1
    fi

    if (( flash_bytes > flash_max )); then
        echo "Flash usage $flash_bytes exceeds Uno limit $flash_max."
        return 1
    fi

    if (( ram_bytes > ram_max )); then
        echo "SRAM usage $ram_bytes exceeds Uno limit $ram_max."
        return 1
    fi

    return 0
}

run_generate_test_data() {
    local tmpdir

    tmpdir="$(mktemp -d)"
    if ! bash -c "cd '$tmpdir' && Rscript --vanilla '$SCRIPT_DIR/test-data/generate-test-data.R'"; then
        rm -rf "$tmpdir"
        return 1
    fi

    rm -rf "$tmpdir"
    return 0
}

run_generated_data_analysis() {
    local output_file
    local tmpdir

    tmpdir="$(mktemp -d)"
    output_file="$(mktemp)"

    if ! bash -c "cd '$tmpdir' && Rscript --vanilla '$SCRIPT_DIR/test-data/generate-test-data.R'"; then
        rm -f "$output_file"
        rm -rf "$tmpdir"
        return 1
    fi

    if ! bash -c "cd '$tmpdir' && Rscript --vanilla '$SCRIPT_DIR/summarize-firmware-flicker-logs.R'" | tee "$output_file"; then
        rm -f "$output_file"
        rm -rf "$tmpdir"
        return 1
    fi

    if ! grep -q "Flicker_Count" "$output_file"; then
        echo "No firmware flicker rows detected in generated test data."
        rm -f "$output_file"
        rm -rf "$tmpdir"
        return 1
    fi

    rm -f "$output_file"
    rm -rf "$tmpdir"
    return 0
}

run_rollover_boundary_analysis() {
    local tmpdir
    local output_file

    tmpdir="$(mktemp -d)"
    output_file="$(mktemp)"

    cat > "$tmpdir/LOG_000.CSV" <<'CSV'
Uptime_s,Address,Baseline_Light,Read_Count,Flicker_Count,Min_Ratio_Pct
86399,0,810,3200,0,100
CSV

    cat > "$tmpdir/LOG_001.CSV" <<'CSV'
Uptime_s,Address,Baseline_Light,Read_Count,Flicker_Count,Min_Ratio_Pct
86400,0,420,3200,1,58
86401,0,810,3200,0,100
86402,0,810,3200,0,100
86403,0,810,3200,0,100
CSV

    if ! bash -c "cd '$tmpdir' && Rscript --vanilla '$SCRIPT_DIR/summarize-firmware-flicker-logs.R'" | tee "$output_file"; then
        rm -f "$output_file"
        rm -rf "$tmpdir"
        return 1
    fi

    if ! grep -q "24:00:00" "$output_file"; then
        echo "Rollover boundary flicker was not detected."
        rm -f "$output_file"
        rm -rf "$tmpdir"
        return 1
    fi

    rm -f "$output_file"
    rm -rf "$tmpdir"
    return 0
}

# --- Shell scripts ---
if command -v shellcheck >/dev/null 2>&1; then
    run_check "shellcheck (*.sh)" run_shellcheck
else
    skip_check "shellcheck (*.sh)"
fi

if command -v bashate >/dev/null 2>&1; then
    run_check "bashate -i E006 (*.sh)" run_bashate
else
    skip_check "bashate -i E006 (*.sh)"
fi

# --- R scripts ---
if command -v Rscript >/dev/null 2>&1; then
    run_check "R parse (*.R)" run_r_parse

    if Rscript -e "quit(status = if (!requireNamespace('lintr', quietly = TRUE)) 10 else 0)" >/dev/null 2>&1; then
        run_check "lintr (*.R)" run_r_lintr
    else
        skip_check "lintr (*.R)"
    fi
else
    skip_check "R parse (*.R)"
    skip_check "lintr (*.R)"
fi

# --- C++/Arduino sketch checks ---
if command -v arduino-cli >/dev/null 2>&1; then
    if arduino-cli board listall | grep -q "arduino:avr:uno"; then
        run_check "arduino-cli compile (uno)" \
            run_arduino_compile_uno
    else
        skip_check "arduino-cli compile (uno)"
    fi
else
    skip_check "arduino-cli compile (uno)"
fi

if command -v cppcheck >/dev/null 2>&1; then
    run_check "cppcheck (*.ino)" run_cppcheck
else
    skip_check "cppcheck (*.ino)"
fi

run_check "sim/.ino constant sync" run_sim_constant_sync_check

if command -v make >/dev/null 2>&1; then
    run_check "C simulator (sim/)" run_c_simulator
else
    skip_check "C simulator (sim/)"
fi

# --- End-to-end test-data run ---
if command -v Rscript >/dev/null 2>&1; then
    run_check "generate test data" \
        run_generate_test_data
    run_check "analyze generated test data" \
        run_generated_data_analysis
    run_check "analyze rollover boundary test data" \
        run_rollover_boundary_analysis

else
    skip_check "generate test data"
    skip_check "analyze generated test data"
    skip_check "analyze rollover boundary test data"
fi

if [[ "$FAILED" -ne 0 ]]; then
    echo
    echo "One or more checks failed."
    exit 1
fi

echo
echo Complete
