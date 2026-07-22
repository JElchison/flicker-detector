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

run_generated_data_analysis() {
    local output_file
    output_file="$(mktemp)"

    if ! bash -c "cd '$SCRIPT_DIR/test-data' && Rscript --vanilla ../analyze-csv-for-flickers.R" | tee "$output_file"; then
        rm -f "$output_file"
        return 1
    fi

    if ! grep -q "# A tibble:" "$output_file"; then
        echo "No flickers detected in generated test data."
        rm -f "$output_file"
        return 1
    fi

    rm -f "$output_file"
    return 0
}

run_rollover_boundary_analysis() {
    local tmpdir
    local output_file

    tmpdir="$(mktemp -d)"
    output_file="$(mktemp)"

    cat > "$tmpdir/LOG_000.CSV" <<'CSV'
Uptime_s,Address,Min_Light,Max_Light,Avg_Light,Read_Count
86399,0,800,820,810,8100
CSV

    cat > "$tmpdir/LOG_001.CSV" <<'CSV'
Uptime_s,Address,Min_Light,Max_Light,Avg_Light,Read_Count
86400,0,20,820,420,8100
86401,0,800,820,810,8100
86402,0,800,820,810,8100
86403,0,800,820,810,8100
CSV

    if ! bash -c "cd '$tmpdir' && Rscript --vanilla '$SCRIPT_DIR/analyze-csv-for-flickers.R'" | tee "$output_file"; then
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
            arduino-cli compile --fqbn arduino:avr:uno "$SCRIPT_DIR"
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

# --- End-to-end test-data run ---
if command -v Rscript >/dev/null 2>&1; then
    run_check "generate test data" \
        bash -c "cd '$SCRIPT_DIR/test-data' && Rscript --vanilla generate-test-data.R"
    run_check "analyze generated test data" \
        run_generated_data_analysis
    run_check "analyze rollover boundary test data" \
        run_rollover_boundary_analysis
    run_check "run analyzer over all data sets" \
        find data/ -mindepth 1 -type d -exec bash -c 'pushd {}; echo === {} ===; Rscript --vanilla ~/git/flicker-detector/analyze-csv-for-flickers.R; popd;' \;

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
