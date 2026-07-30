library(readr)
library(dplyr)

set.seed(42)

# 315 minutes = 18900 seconds (aligns exactly with 63-min and 45-min FFT bins)
total_seconds <- 18900

make_address_stream <- function(address_value, seconds_total) {
  dip_samples <- sample(0:5, seconds_total, replace = TRUE)
  tibble(
    Uptime_s = 1:seconds_total,
    Address = address_value,
    Baseline_Light = sample(790:810, seconds_total, replace = TRUE),
    Read_Count = sample(3190:3210, seconds_total, replace = TRUE),
    Flicker_Count = 0L,
    Min_Ratio_Pct = sample(96:100, seconds_total, replace = TRUE),
    Dip_Sample_Count = dip_samples,
    Dip_ms = as.integer(round(dip_samples * 1000 / 3200)),
    Human_Visibility_Score = 0L
  )
}

inject_flickers <- function(df, flicker_seconds, baseline_values, flicker_counts, min_ratios) {
  for (i in seq_along(flicker_seconds)) {
    second_idx <- flicker_seconds[[i]]
    df$Baseline_Light[df$Uptime_s == second_idx] <- baseline_values[[i]]
    df$Flicker_Count[df$Uptime_s == second_idx] <- flicker_counts[[i]]
    df$Min_Ratio_Pct[df$Uptime_s == second_idx] <- min_ratios[[i]]
    event_dip_samples <- sample(80:240, 1)
    df$Dip_Sample_Count[df$Uptime_s == second_idx] <- event_dip_samples
    df$Dip_ms[df$Uptime_s == second_idx] <- as.integer(round(event_dip_samples * 1000 / 3200))
    df$Human_Visibility_Score[df$Uptime_s == second_idx] <- sample(25:90, 1)
  }
  df
}

addr0 <- make_address_stream(0L, total_seconds)
addr0 <- inject_flickers(
  addr0,
  flicker_seconds = seq(300, by = 3780, length.out = 5),
  baseline_values = c(450, 430, 420, 415, 425),
  flicker_counts = c(1L, 1L, 2L, 1L, 2L),
  min_ratios = c(64L, 62L, 58L, 60L, 57L)
)

addr1 <- make_address_stream(1L, total_seconds)
addr1 <- inject_flickers(
  addr1,
  flicker_seconds = seq(900, by = 2700, length.out = 7),
  baseline_values = c(430, 420, 410, 405, 412, 409, 407),
  flicker_counts = c(1L, 1L, 1L, 2L, 1L, 1L, 2L),
  min_ratios = c(61L, 59L, 55L, 54L, 57L, 56L, 53L)
)

test_data <- bind_rows(addr0, addr1) |>
  arrange(Uptime_s, Address)

write_csv(test_data, "LOG_000.CSV")
cat("Success: LOG_000.CSV generated with dual-address firmware-style test data\n")
