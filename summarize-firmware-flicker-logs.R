suppressPackageStartupMessages(library(dplyr))
suppressPackageStartupMessages(library(readr))
suppressPackageStartupMessages(library(purrr))


# The Arduino now detects flickers in real time. This script is a lightweight
# viewer for the firmware's summary CSVs, so archived logs are easier to inspect
# without re-running any DSP on the host.

required_cols <- c(
  "Uptime_s",
  "Address",
  "Baseline_Light",
  "Read_Count",
  "Flicker_Count",
  "Min_Ratio_Pct"
)

result_cols <- c(
  "filename",
  "Uptime_hms",
  "Address",
  "Baseline_Light",
  "Read_Count",
  "Flicker_Count",
  "Min_Ratio_Pct",
  "Dip_Sample_Count",
  "Dip_ms",
  "Human_Visibility_Score"
)

load_one_log <- function(file) {
  temp_df <- read_csv(file, show_col_types = FALSE, progress = FALSE)

  if (nrow(temp_df) == 0) {
    return(NULL)
  }

  if (!all(required_cols %in% names(temp_df))) {
    warning(sprintf("Skipping %s (missing firmware log columns).", basename(file)))
    return(NULL)
  }

  temp_df |>
    transmute(
      filename = basename(file),
      Uptime_s = as.double(.data$Uptime_s),
      Address = as.integer(.data$Address),
      Baseline_Light = as.double(.data$Baseline_Light),
      Read_Count = as.double(.data$Read_Count),
      Flicker_Count = as.integer(.data$Flicker_Count),
      Min_Ratio_Pct = as.integer(.data$Min_Ratio_Pct),
      Dip_Sample_Count = if ("Dip_Sample_Count" %in% names(temp_df)) {
        as.integer(.data$Dip_Sample_Count)
      } else {
        NA_integer_
      },
      Dip_ms = if ("Dip_ms" %in% names(temp_df)) {
        as.integer(.data$Dip_ms)
      } else {
        NA_integer_
      },
      Human_Visibility_Score = if ("Human_Visibility_Score" %in% names(temp_df)) {
        as.integer(.data$Human_Visibility_Score)
      } else {
        NA_integer_
      }
    )
}

load_logs <- function() {
  file_list <- list.files(pattern = "^LOG_[0-9]{3}\\.CSV$", full.names = TRUE)

  if (length(file_list) == 0) {
    stop("No LOG_XXX.CSV files found in the current directory.")
  }

  df <- map_dfr(file_list, load_one_log)
  if (nrow(df) == 0) {
    stop("No usable firmware log rows found in LOG_XXX.CSV files.")
  }

  df
}

format_uptime <- function(uptime_seconds) {
  hours <- floor(uptime_seconds / 3600)
  minutes <- floor((uptime_seconds %% 3600) / 60)
  seconds <- uptime_seconds %% 60
  sprintf("%d:%02d:%02d", hours, minutes, seconds)
}

print_events <- function(events_df, address_value) {
  cat("\n=== Address", address_value, "===\n")
  if (nrow(events_df) == 0) {
    cat("No flickers detected.\n")
    return(invisible(NULL))
  }

  old_width <- getOption("width")
  on.exit(options(width = old_width), add = TRUE)
  options(width = 200)
  print(as.data.frame(events_df), row.names = FALSE)
  invisible(NULL)
}

df <- load_logs()

flicker_events <- df |>
  filter(.data$Flicker_Count > 0) |>
  mutate(Uptime_hms = format_uptime(.data$Uptime_s)) |>
  select(all_of(result_cols))

address_values <- sort(unique(df$Address))

if (nrow(flicker_events) == 0) {
  cat("No flickers detected.\n")
} else {
  walk(address_values, function(address_value) {
    print_events(flicker_events |> filter(.data$Address == address_value), address_value)
  })
}

invisible(flicker_events)
