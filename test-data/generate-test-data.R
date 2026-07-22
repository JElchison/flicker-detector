library(readr)
library(dplyr)


set.seed(42)

# 75 minutes = 4500 seconds
total_seconds <- 4500

make_address_stream <- function(address_value, seconds_total) {
  tibble(
    Uptime_s = 1:seconds_total,
    Address = address_value,
    Min_Light = sample(790:810, seconds_total, replace = TRUE),
    Max_Light = sample(805:825, seconds_total, replace = TRUE),
    Avg_Light = sample(795:815, seconds_total, replace = TRUE),
    Read_Count = sample(8100:8200, seconds_total, replace = TRUE)
  )
}

inject_flickers <- function(df, flicker_seconds, min_values, avg_values) {
  for (i in seq_along(flicker_seconds)) {
    second_idx <- flicker_seconds[[i]]
    df$Min_Light[df$Uptime_s == second_idx] <- min_values[[i]]
    df$Avg_Light[df$Uptime_s == second_idx] <- avg_values[[i]]
  }
  df
}

# Address 0 baseline + flickers
addr0 <- make_address_stream(0L, total_seconds)
addr0 <- inject_flickers(
  addr0,
  flicker_seconds = c(300, 4080),
  min_values = c(20, 15),
  avg_values = c(450, 420)
)

# Address 1 baseline + different flickers
addr1 <- make_address_stream(1L, total_seconds)
addr1 <- inject_flickers(
  addr1,
  flicker_seconds = c(900, 3600),
  min_values = c(18, 12),
  avg_values = c(430, 410)
)

# Interleave rows by second, then address, matching firmware output pattern.
test_data <- bind_rows(addr0, addr1) |>
  arrange(Uptime_s, Address)

# Write to file
write_csv(test_data, "LOG_000.CSV")
cat("Success: LOG_000.CSV generated with dual-address test data\n")

