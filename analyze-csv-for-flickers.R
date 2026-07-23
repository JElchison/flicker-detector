suppressPackageStartupMessages(library(dplyr))
suppressPackageStartupMessages(library(readr))
suppressPackageStartupMessages(library(purrr))


# --- 1. Define Thresholds ---
# Set just above your true "dark" floor (with fixture on) so normal PWM dips stay above it.
# Start from the 1st percentile of Min_Light during stable operation, then add a small margin.
DARK_THRESH   <- 250
# Set below your true "bright" ceiling so normal on-state samples exceed it.
# Start from the 5th percentile of Max_Light during stable operation, then subtract a small margin.
BRIGHT_THRESH <- 400
# Minimum one-second Avg_Light jump/drop required to count as abrupt.
# Increase to reduce false positives from noise; decrease to catch subtler flickers.
ABRUPT_DIFF   <- 250

# --- 2. Load and Normalize Data ---
required_cols <- c("Uptime_s", "Min_Light", "Max_Light", "Avg_Light", "Read_Count")
result_cols <- c("filename", "Uptime_hms", "Min_Light", "Max_Light", "Avg_Light", "Read_Count", "is_flicker")

load_one_log <- function(file) {
  temp_df <- read_csv(file, show_col_types = FALSE, progress = FALSE)

  if (nrow(temp_df) == 0) {
    return(NULL)
  }

  if (!all(required_cols %in% names(temp_df))) {
    warning(sprintf("Skipping %s (missing required columns).", basename(file)))
    return(NULL)
  }

  # Backward compatibility with older logs that did not include Address.
  if (!("Address" %in% names(temp_df))) {
    temp_df <- temp_df |> mutate(Address = 0)
  }

  temp_df |>
    transmute(
      filename = basename(file),
      Uptime_s = as.double(.data$Uptime_s),
      Address = as.integer(.data$Address),
      Min_Light = as.double(.data$Min_Light),
      Max_Light = as.double(.data$Max_Light),
      Avg_Light = as.double(.data$Avg_Light),
      Read_Count = as.double(.data$Read_Count)
    )
}

load_logs <- function() {
  file_list <- list.files(pattern = "^LOG_[0-9]{3}\\.CSV$", full.names = TRUE)

  if (length(file_list) == 0) {
    stop("No LOG_XXX.CSV files found in the current directory.")
  }

  df <- map_dfr(file_list, load_one_log)
  if (nrow(df) == 0) {
    stop("No usable data rows found in LOG_XXX.CSV files.")
  }

  df
}

# --- 3. Analyze One Address ---
analyze_one_address <- function(df, address_value) {
  df |>
    filter(.data$Address == address_value) |>
    arrange(.data$filename, .data$Uptime_s) |>
    mutate(
      time_gap = .data$Uptime_s - lag(.data$Uptime_s, default = first(.data$Uptime_s)),
      is_new_session = .data$time_gap < 0 | .data$time_gap > 5,
      session_id = cumsum(.data$is_new_session)
    ) |>
    # Keep lag/lead continuity across daily file rollovers inside the same session.
    group_by(.data$session_id) |>
    mutate(
      was_bright = lag(.data$Max_Light, 1, default = 0) > BRIGHT_THRESH |
                   lag(.data$Max_Light, 2, default = 0) > BRIGHT_THRESH,
      returns_bright = lead(.data$Max_Light, 1, default = 0) > BRIGHT_THRESH |
                       lead(.data$Max_Light, 2, default = 0) > BRIGHT_THRESH |
                       lead(.data$Max_Light, 3, default = 0) > BRIGHT_THRESH,
      abrupt_intra = (.data$Max_Light > BRIGHT_THRESH) & (.data$Min_Light < DARK_THRESH),
      abrupt_drop = (lag(.data$Avg_Light, 1, default = 0) - .data$Avg_Light) > ABRUPT_DIFF,
      abrupt_rise = (.data$Avg_Light - lag(.data$Avg_Light, 1, default = 0)) > ABRUPT_DIFF,
      is_flicker = (.data$Min_Light < DARK_THRESH) &
                   .data$was_bright &
                   .data$returns_bright &
                   (.data$abrupt_intra | .data$abrupt_drop | .data$abrupt_rise |
                    lag(.data$abrupt_intra, 1, default = FALSE) | lead(.data$abrupt_intra, 1, default = FALSE)),
      is_powered_off = (.data$Max_Light < DARK_THRESH) & !.data$was_bright & !.data$returns_bright
    ) |>
    ungroup() |>
    filter(!.data$is_powered_off) |>
    mutate(
      hours = floor(.data$Uptime_s / 3600),
      minutes = floor((.data$Uptime_s %% 3600) / 60),
      seconds = .data$Uptime_s %% 60,
      Uptime_hms = sprintf("%d:%02d:%02d", .data$hours, .data$minutes, .data$seconds)
    ) |>
    select(all_of(result_cols))
}

print_flicker_table <- function(flicker_df, address_value) {
  cat("\n=== Address", address_value, "===\n")
  if (nrow(flicker_df) == 0) {
    cat("No flickers detected.\n")
    return(invisible(NULL))
  }

  print(flicker_df, n = Inf)
  invisible(NULL)
}

# --- 4. Run Analysis for All Addresses ---
df <- load_logs()
address_values <- sort(unique(df$Address))

analysis_by_address <- map(address_values, function(addr) {
  analyze_one_address(df, addr)
})

flickers_by_address <- map(analysis_by_address, function(tbl) {
  tbl |> filter(is_flicker)
})

walk2(flickers_by_address, address_values, print_flicker_table)

# Combined tibble retained for optional downstream use.
flicker_events <- bind_rows(flickers_by_address)
invisible(flicker_events)
