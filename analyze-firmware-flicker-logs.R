suppressPackageStartupMessages(library(dplyr))
suppressPackageStartupMessages(library(readr))
suppressPackageStartupMessages(library(purrr))


# The Arduino now detects flickers in real time. This script is a lightweight
# viewer for the firmware's summary CSVs, so archived logs are easier to inspect
# without re-running any DSP on the host.

# Modern firmware summary schema (event-aware rows).
modern_required_cols <- c(
  "Uptime_s",
  "Address",
  "Baseline_Light",
  "Read_Count",
  "Flicker_Count",
  "Min_Ratio_Pct"
)

# Legacy schema predates Flicker_Count/HVS and only includes light windows.
legacy_required_cols <- c(
  "Uptime_s",
  "Address",
  "Min_Light",
  "Max_Light",
  "Avg_Light",
  "Read_Count"
)

SAMPLE_RATE_HZ <- 3200L
MIN_IGNORED_DIP_MS <- 6L
MAX_IGNORED_MIN_RATIO_PCT <- 70L

result_cols <- c(
  "filename",
  "Uptime_s",
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

dip_samples_to_ms <- function(dip_sample_count) {
  output <- rep(NA_integer_, length(dip_sample_count))
  valid_idx <- which(!is.na(dip_sample_count))
  if (length(valid_idx) == 0) {
    return(output)
  }

  output[valid_idx] <- as.integer(
    ((as.double(dip_sample_count[valid_idx]) * 1000) + (SAMPLE_RATE_HZ / 2)) / SAMPLE_RATE_HZ
  )
  output
}

compute_hvs_from_fields <- function(flicker_count, min_ratio_pct, dip_ms) {
  # Mirror firmware row filtering and weighted visibility scoring so old logs
  # and modern logs are comparable in FFT analysis.
  flicker_count <- as.integer(dplyr::coalesce(flicker_count, 0L))
  min_ratio_pct <- as.integer(dplyr::coalesce(min_ratio_pct, 100L))
  dip_ms <- as.integer(dplyr::coalesce(dip_ms, 0L))

  ignore_row <- flicker_count > 0L &
    dip_ms < MIN_IGNORED_DIP_MS &
    min_ratio_pct > MAX_IGNORED_MIN_RATIO_PCT

  filtered_count <- ifelse(ignore_row, 0L, flicker_count)
  effective_dip_ms <- ifelse(ignore_row, 0L, dip_ms)

  depth_score <- pmax(0L, 100L - pmin(min_ratio_pct, 100L))
  duration_score <- pmin(pmax(effective_dip_ms, 0L), 100L)
  count_score <- pmin(filtered_count * 20L, 100L)

  weighted_score <- (depth_score * 60L) + (duration_score * 30L) + (count_score * 10L)
  visibility_score <- ifelse(filtered_count == 0L, 0L, weighted_score %/% 100L)

  as.integer(pmin(pmax(visibility_score, 0L), 100L))
}

load_one_log <- function(file) {
  temp_df <- read_csv(file, show_col_types = FALSE, progress = FALSE)

  if (nrow(temp_df) == 0) {
    return(NULL)
  }

  has_modern_schema <- all(modern_required_cols %in% names(temp_df))
  has_legacy_schema <- all(legacy_required_cols %in% names(temp_df))

  if (!has_modern_schema && !has_legacy_schema) {
    warning(sprintf("Skipping %s (unsupported log schema).", basename(file)))
    return(NULL)
  }

  has_hvs_col <- "Human_Visibility_Score" %in% names(temp_df)
  has_dip_ms_col <- "Dip_ms" %in% names(temp_df)

  temp_df |>
    transmute(
      filename = basename(file),
      Uptime_s = as.double(.data$Uptime_s),
      Address = as.integer(.data$Address),
      Baseline_Light = if (has_modern_schema) {
        as.double(.data$Baseline_Light)
      } else {
        as.double(.data$Avg_Light)
      },
      Read_Count = as.double(.data$Read_Count),
      Flicker_Count = if (has_modern_schema) {
        as.integer(.data$Flicker_Count)
      } else {
        # Legacy rows do not carry event counts; keep them as non-events.
        rep.int(0L, nrow(temp_df))
      },
      Min_Ratio_Pct = if (has_modern_schema) {
        as.integer(.data$Min_Ratio_Pct)
      } else {
        # Approximate minimum ratio from legacy min/avg brightness snapshot.
        min_ratio_estimate <- ifelse(
          .data$Avg_Light > 0,
          (.data$Min_Light * 100) / .data$Avg_Light,
          100
        )
        as.integer(round(pmin(pmax(min_ratio_estimate, 0), 100)))
      },
      Dip_Sample_Count = if ("Dip_Sample_Count" %in% names(temp_df)) {
        as.integer(.data$Dip_Sample_Count)
      } else {
        NA_integer_
      },
      Dip_ms_Raw = if (has_dip_ms_col) {
        as.integer(.data$Dip_ms)
      } else {
        NA_integer_
      },
      Human_Visibility_Score_Raw = if (has_hvs_col) {
        as.integer(.data$Human_Visibility_Score)
      } else {
        NA_integer_
      }
    ) |>
    mutate(
      # Reconstruct missing fields for older firmware exports when possible.
      Dip_ms = dplyr::coalesce(.data$Dip_ms_Raw, dip_samples_to_ms(.data$Dip_Sample_Count)),
      Human_Visibility_Score = dplyr::coalesce(
        .data$Human_Visibility_Score_Raw,
        compute_hvs_from_fields(.data$Flicker_Count, .data$Min_Ratio_Pct, .data$Dip_ms)
      ),
      HVS_Backfilled = is.na(.data$Human_Visibility_Score_Raw)
    ) |>
    select(-any_of(c("Dip_ms_Raw", "Human_Visibility_Score_Raw")))
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

  backfilled_rows <- sum(df$HVS_Backfilled, na.rm = TRUE)
  if (backfilled_rows > 0) {
    cat(sprintf("Backfilled Human_Visibility_Score for %d legacy rows.\n", backfilled_rows))
  }

  df
}

format_uptime <- function(uptime_seconds) {
  hours <- floor(uptime_seconds / 3600)
  minutes <- floor((uptime_seconds %% 3600) / 60)
  seconds <- uptime_seconds %% 60
  sprintf("%d:%02d:%02d", hours, minutes, seconds)
}

build_fft_signal <- function(address_df, address_events_df) {
  uptime_min <- floor(min(address_df$Uptime_s, na.rm = TRUE))
  uptime_max <- ceiling(max(address_df$Uptime_s, na.rm = TRUE))

  if (!is.finite(uptime_min) || !is.finite(uptime_max) || uptime_max <= uptime_min) {
    return(NULL)
  }

  signal_seconds <- seq.int(from = uptime_min, to = uptime_max, by = 1)
  signal_hvs <- numeric(length(signal_seconds))

  if (nrow(address_events_df) > 0) {
    event_hvs <- address_events_df |>
      group_by(.data$Uptime_s) |>
      summarise(
        HVS_sum = sum(.data$Human_Visibility_Score, na.rm = TRUE),
        .groups = "drop"
      )

    hvs_idx <- match(event_hvs$Uptime_s, signal_seconds)
    valid_idx <- which(!is.na(hvs_idx))
    if (length(valid_idx) > 0) {
      signal_hvs[hvs_idx[valid_idx]] <- event_hvs$HVS_sum[valid_idx]
    }
  }

  list(seconds = signal_seconds, hvs = signal_hvs)
}

compute_fft_period_spectrum <- function(address_df, address_events_df, address_value) {
  signal_obj <- build_fft_signal(address_df, address_events_df)
  if (is.null(signal_obj)) {
    return(NULL)
  }

  signal_hvs <- signal_obj$hvs
  # If no event energy exists, skip FFT output for this address.
  if (all(signal_hvs == 0)) {
    return(NULL)
  }

  n <- length(signal_hvs)
  if (n < 8) {
    return(NULL)
  }

  demeaned_signal <- signal_hvs - mean(signal_hvs)
  fft_values <- fft(demeaned_signal)
  half_n <- floor(n / 2)

  if (half_n < 2) {
    return(NULL)
  }

  frequency_hz <- (0:(half_n - 1)) / n
  amplitude <- Mod(fft_values[1:half_n]) / (n / 2)

  period_minutes <- rep(Inf, half_n)
  non_dc <- frequency_hz > 0
  period_minutes[non_dc] <- (1 / frequency_hz[non_dc]) / 60

  tibble(
    Address = as.integer(address_value),
    frequency_hz = frequency_hz,
    period_minutes = period_minutes,
    amplitude = amplitude
  )
}

find_peak_period <- function(spectrum_df, preferred_min_minutes = 10, preferred_max_minutes = 75) {
  candidate_df <- spectrum_df |>
    filter(
      is.finite(.data$period_minutes),
      .data$period_minutes >= preferred_min_minutes,
      .data$period_minutes <= preferred_max_minutes
    )

  if (nrow(candidate_df) == 0) {
    candidate_df <- spectrum_df |>
      filter(is.finite(.data$period_minutes), .data$period_minutes > 0)
  }

  if (nrow(candidate_df) == 0) {
    return(NULL)
  }

  max_amplitude <- max(candidate_df$amplitude, na.rm = TRUE)
  prominent_df <- candidate_df |>
    filter(.data$amplitude >= (max_amplitude * 0.98))

  if (nrow(prominent_df) > 0) {
    candidate_df <- prominent_df
  }

  candidate_df |>
    arrange(desc(.data$period_minutes), desc(.data$amplitude)) |>
    slice(1)
}

collect_peak_interval_matches <- function(address_events_df, peak_period_minutes, pair_mode = "all") {
  if (nrow(address_events_df) < 2 || is.na(peak_period_minutes) || !is.finite(peak_period_minutes)) {
    return(tibble())
  }

  tolerance_minutes <- max(1, peak_period_minutes * 0.10)
  pair_mode <- match.arg(pair_mode, choices = c("all", "consecutive"))

  ordered_events <- address_events_df |>
    arrange(.data$Uptime_s)

  if (pair_mode == "consecutive") {
    matched_pairs <- ordered_events |>
      mutate(
        Next_Uptime_s = dplyr::lead(.data$Uptime_s),
        Next_Uptime_hms = dplyr::lead(.data$Uptime_hms),
        Next_filename = dplyr::lead(.data$filename),
        Next_Human_Visibility_Score = dplyr::lead(.data$Human_Visibility_Score),
        Interval_minutes = (.data$Next_Uptime_s - .data$Uptime_s) / 60
      ) |>
      filter(
        !is.na(.data$Interval_minutes),
        abs(.data$Interval_minutes - peak_period_minutes) <= tolerance_minutes
      ) |>
      transmute(
        filename = .data$filename,
        Uptime_hms = .data$Uptime_hms,
        Human_Visibility_Score = .data$Human_Visibility_Score,
        Next_filename = .data$Next_filename,
        Next_Uptime_hms = .data$Next_Uptime_hms,
        Next_Human_Visibility_Score = .data$Next_Human_Visibility_Score,
        Interval_minutes = round(.data$Interval_minutes, 3),
        Peak_period_minutes = round(peak_period_minutes, 3)
      )

    return(matched_pairs)
  }

  idx_grid <- expand.grid(
    start_idx = seq_len(nrow(ordered_events)),
    end_idx = seq_len(nrow(ordered_events)),
    KEEP.OUT.ATTRS = FALSE,
    stringsAsFactors = FALSE
  ) |>
    filter(.data$end_idx > .data$start_idx)

  matched_pairs <- idx_grid |>
    mutate(
      Start_Uptime_s = ordered_events$Uptime_s[.data$start_idx],
      End_Uptime_s = ordered_events$Uptime_s[.data$end_idx],
      Interval_minutes = (.data$End_Uptime_s - .data$Start_Uptime_s) / 60
    ) |>
    filter(abs(.data$Interval_minutes - peak_period_minutes) <= tolerance_minutes) |>
    transmute(
      filename = ordered_events$filename[.data$start_idx],
      Uptime_hms = ordered_events$Uptime_hms[.data$start_idx],
      Human_Visibility_Score = ordered_events$Human_Visibility_Score[.data$start_idx],
      Next_filename = ordered_events$filename[.data$end_idx],
      Next_Uptime_hms = ordered_events$Uptime_hms[.data$end_idx],
      Next_Human_Visibility_Score = ordered_events$Human_Visibility_Score[.data$end_idx],
      Interval_minutes = round(.data$Interval_minutes, 3),
      Peak_period_minutes = round(peak_period_minutes, 3)
    )

  matched_pairs
}

find_peak_period_with_matches <- function(
  spectrum_df,
  address_events_df,
  preferred_min_minutes = 10,
  preferred_max_minutes = 75,
  max_candidates = 60
) {
  max_flicker_period_minutes <- if (nrow(address_events_df) > 0) {
    max(address_events_df$Uptime_s, na.rm = TRUE) / 60
  } else {
    preferred_max_minutes
  }
  effective_max_minutes <- min(preferred_max_minutes, max_flicker_period_minutes)

  base_peak <- find_peak_period(
    spectrum_df,
    preferred_min_minutes = preferred_min_minutes,
    preferred_max_minutes = effective_max_minutes
  )
  if (is.null(base_peak)) {
    return(NULL)
  }

  candidate_df <- spectrum_df |>
    filter(
      is.finite(.data$period_minutes),
      .data$period_minutes >= preferred_min_minutes,
      .data$period_minutes <= effective_max_minutes
    ) |>
    arrange(desc(.data$amplitude))

  if (nrow(candidate_df) == 0) {
    candidate_df <- spectrum_df |>
      filter(is.finite(.data$period_minutes), .data$period_minutes > 0) |>
      arrange(desc(.data$amplitude))
  }

  if (nrow(candidate_df) > 0) {
    candidate_limit <- min(max_candidates, nrow(candidate_df))
    candidate_df <- candidate_df |> slice_head(n = candidate_limit)
  }

  if (nrow(candidate_df) == 0) {
    base_table <- collect_peak_interval_matches(address_events_df, base_peak$period_minutes[[1]], pair_mode = "all")
    return(list(
      peak_row = base_peak,
      interval_table = base_table,
      match_count = nrow(base_table)
    ))
  }

  matched_candidates <- list()
  for (idx in seq_len(nrow(candidate_df))) {
    candidate_row <- candidate_df[idx, , drop = FALSE]
    candidate_period <- candidate_row$period_minutes[[1]]
    candidate_table <- collect_peak_interval_matches(address_events_df, candidate_period, pair_mode = "all")
    match_count <- nrow(candidate_table)

    if (match_count > 0) {
      matched_candidates[[length(matched_candidates) + 1]] <- list(
        peak_row = candidate_row,
        interval_table = candidate_table,
        match_count = match_count
      )
    }
  }

  if (length(matched_candidates) > 0) {
    score_tbl <- tibble(
      idx = seq_along(matched_candidates),
      match_count = vapply(matched_candidates, function(x) x$match_count, numeric(1)),
      amplitude = vapply(matched_candidates, function(x) x$peak_row$amplitude[[1]], numeric(1))
    ) |>
      arrange(desc(.data$amplitude), desc(.data$match_count))

    best_idx <- score_tbl$idx[[1]]
    return(matched_candidates[[best_idx]])
  }

  base_table <- collect_peak_interval_matches(address_events_df, base_peak$period_minutes[[1]], pair_mode = "all")

  list(
    peak_row = base_peak,
    interval_table = base_table,
    match_count = nrow(base_table)
  )
}

print_peak_interval_table <- function(interval_df, address_value, peak_period_minutes) {
  cat(sprintf("\n=== Address %d Peak-Interval Flickers (%.3f min) ===\n", address_value, peak_period_minutes))
  if (nrow(interval_df) == 0) {
    cat("No flicker pairs matched the peak interval window.\n")
    return(invisible(NULL))
  }

  old_width <- getOption("width")
  on.exit(options(width = old_width), add = TRUE)
  options(width = 200)
  print(as.data.frame(interval_df), row.names = FALSE)
  invisible(NULL)
}

plot_fft_period_spectrum <- function(
  spectrum_df,
  selected_peaks_df = NULL,
  eligible_limits_df = NULL,
  output_file = "flicker-fft-period-spectrum.png",
  show_interactive = TRUE
) {
  plot_df <- spectrum_df |>
    filter(is.finite(.data$period_minutes), .data$period_minutes > 0)

  if (!is.null(eligible_limits_df) && nrow(eligible_limits_df) > 0) {
    plot_df <- plot_df |>
      left_join(
        eligible_limits_df |>
          select("Address", "Eligible_Max_Period_Minutes"),
        by = "Address"
      ) |>
      filter(
        is.na(.data$Eligible_Max_Period_Minutes) |
          .data$period_minutes <= .data$Eligible_Max_Period_Minutes
      ) |>
      select(-any_of("Eligible_Max_Period_Minutes"))
  }

  if (nrow(plot_df) == 0) {
    cat("\nNo FFT spectrum data available to plot.\n")
    return(invisible(NULL))
  }

  x_max <- max(75, ceiling(max(plot_df$period_minutes, na.rm = TRUE)))
  y_max <- max(plot_df$amplitude, na.rm = TRUE)
  if (!is.finite(y_max) || y_max <= 0) {
    y_max <- 1
  }

  address_ids <- sort(unique(plot_df$Address))
  address_colors <- grDevices::hcl.colors(length(address_ids), "Dark 3")

  draw_address_spectrum <- function(address_value, color_value, compact_margins = FALSE) {
    old_par <- par(no.readonly = TRUE)
    on.exit(par(old_par), add = TRUE)

    if (compact_margins) {
      par(mfrow = c(1, 1), mar = c(2.8, 2.8, 2.2, 0.8), mgp = c(1.6, 0.4, 0), cex = 0.9, new = FALSE)
    } else {
      par(mfrow = c(1, 1), mar = c(4, 4, 3, 1), mgp = c(2.2, 0.7, 0), new = FALSE)
    }

    address_plot <- plot_df |>
      filter(.data$Address == address_value) |>
      arrange(.data$period_minutes)

    if (nrow(address_plot) == 0) {
      plot.new()
      title(main = paste("Address", address_value, "Period Spectrum"))
      text(0.5, 0.5, "No eligible FFT bins to plot", cex = 0.95)
      return(invisible(NULL))
    }

    plot(
      NA,
      xlim = c(0, x_max),
      ylim = c(0, y_max * 1.05),
      xlab = "Period (minutes)",
      ylab = "|FFT|",
      main = paste("Address", address_value, "Period Spectrum")
    )
    grid(nx = NA, ny = NULL, col = "grey85")

    segments(
      x0 = address_plot$period_minutes,
      y0 = 0,
      x1 = address_plot$period_minutes,
      y1 = address_plot$amplitude,
      col = grDevices::adjustcolor(color_value, alpha.f = 0.55),
      lwd = 1
    )

    points(
      x = address_plot$period_minutes,
      y = address_plot$amplitude,
      pch = 16,
      cex = 0.45,
      col = grDevices::adjustcolor(color_value, alpha.f = 0.65)
    )

    if (!is.null(selected_peaks_df) && nrow(selected_peaks_df) > 0) {
      peak_row <- selected_peaks_df |>
        filter(.data$Address == address_value)

      if (nrow(peak_row) > 0) {
        peak_x <- peak_row$period_minutes[[1]]
        peak_y <- peak_row$amplitude[[1]]

        points(peak_x, peak_y, pch = 8, cex = 1.2, lwd = 1.5, col = "black")
        abline(v = peak_x, col = "black", lty = 2)
        text(
          x = peak_x,
          y = min(y_max * 1.02, peak_y + (0.06 * y_max)),
          labels = sprintf("Peak %.3f min", peak_x),
          pos = 4,
          cex = 0.85
        )
      }
    }
  }

  make_output_filename <- function(address_value) {
    base_file <- sub(
      "\\.png$",
      "",
      output_file,
      ignore.case = TRUE
    )

    if (identical(base_file, output_file)) {
      base_file <- output_file
    }

    paste0(base_file, "-address-", address_value, ".png")
  }

  if (show_interactive && interactive()) {
    walk2(address_ids, address_colors, function(address_value, color_value) {
      draw_address_spectrum(address_value, color_value, compact_margins = TRUE)
    })
  }

  output_files <- character(0)
  for (idx in seq_along(address_ids)) {
    address_value <- address_ids[[idx]]
    color_value <- address_colors[[idx]]
    output_name <- make_output_filename(address_value)

    grDevices::png(filename = output_name, width = 1400, height = 900, res = 140)
    draw_address_spectrum(address_value, color_value, compact_margins = FALSE)
    grDevices::dev.off()

    output_files <- c(output_files, output_name)
  }

  cat("\nFFT plot saved:", paste(output_files, collapse = ", "), "\n")
  if (show_interactive && interactive()) {
    cat("FFT plot also rendered to the active interactive graphics device.\n")
  }
  invisible(output_files)
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
  mutate(
    Uptime_hms = format_uptime(.data$Uptime_s),
    Human_Visibility_Score = dplyr::coalesce(.data$Human_Visibility_Score, 0L)
  ) |>
  select(all_of(result_cols))

address_values <- sort(unique(df$Address))

if (nrow(flicker_events) == 0) {
  cat("No flickers detected.\n")
} else {
  walk(address_values, function(address_value) {
    print_events(flicker_events |> filter(.data$Address == address_value), address_value)
  })
}

spectra_by_address <- map(address_values, function(address_value) {
  address_df <- df |> filter(.data$Address == address_value)
  address_events_df <- flicker_events |> filter(.data$Address == address_value)
  compute_fft_period_spectrum(address_df, address_events_df, address_value)
})

fft_spectrum <- bind_rows(compact(spectra_by_address))

if (nrow(fft_spectrum) == 0) {
  cat("\nNo FFT spectrum could be computed from available data.\n")
} else {
  eligible_limits <- map_dfr(address_values, function(address_value) {
    address_events_df <- flicker_events |> filter(.data$Address == address_value)
    eligible_max_minutes <- if (nrow(address_events_df) > 0) {
      min(75, max(address_events_df$Uptime_s, na.rm = TRUE) / 60)
    } else {
      75
    }

    tibble(
      Address = as.integer(address_value),
      Eligible_Max_Period_Minutes = eligible_max_minutes
    )
  })

  peak_results <- map(address_values, function(address_value) {
    address_spectrum <- fft_spectrum |> filter(.data$Address == address_value)
    address_events_df <- flicker_events |> filter(.data$Address == address_value)
    find_peak_period_with_matches(
      address_spectrum,
      address_events_df,
      preferred_min_minutes = 10,
      preferred_max_minutes = 75
    )
  })

  selected_peaks <- map2_dfr(address_values, peak_results, function(address_value, peak_result) {
    if (is.null(peak_result) || is.null(peak_result$peak_row)) {
      return(tibble())
    }

    tibble(
      Address = as.integer(address_value),
      period_minutes = peak_result$peak_row$period_minutes[[1]],
      amplitude = peak_result$peak_row$amplitude[[1]],
      match_count = if (is.null(peak_result$match_count)) {
        nrow(peak_result$interval_table)
      } else {
        as.integer(peak_result$match_count)
      }
    )
  })

  plot_fft_period_spectrum(
    fft_spectrum,
    selected_peaks_df = selected_peaks,
    eligible_limits_df = eligible_limits
  )

  walk2(address_values, peak_results, function(address_value, peak_result) {

    if (is.null(peak_result) || is.null(peak_result$peak_row)) {
      cat("\n=== Address", address_value, "Peak-Interval Flickers ===\n")
      cat("No FFT peak found for this address.\n")
      return(invisible(NULL))
    }

    peak_period_minutes <- peak_result$peak_row$period_minutes[[1]]
    peak_interval_df <- peak_result$interval_table
    print_peak_interval_table(peak_interval_df, address_value, peak_period_minutes)
    invisible(NULL)
  })
}

invisible(flicker_events)
