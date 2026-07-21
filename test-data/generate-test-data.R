library(readr)
library(dplyr)

# 75 minutes = 4500 seconds
total_seconds <- 4500 

# Generate healthy baseline data
test_data <- tibble(
  Uptime_s = 1:total_seconds,
  Min_Light = sample(790:810, total_seconds, replace = TRUE),
  Max_Light = sample(805:825, total_seconds, replace = TRUE),
  Avg_Light = sample(795:815, total_seconds, replace = TRUE),
  Read_Count = sample(8100:8200, total_seconds, replace = TRUE)
)

# Inject Flicker 1 at 5 minutes (300 seconds)
test_data$Min_Light[300] <- 120
test_data$Avg_Light[300] <- 450

# Inject Flicker 2 exactly 63 minutes later (300 + 3780 = 4080 seconds)
test_data$Min_Light[4080] <- 110
test_data$Avg_Light[4080] <- 420

# Write to file
write_csv(test_data, "LOG_000.CSV")
cat("Success: LOG_000.CSV generated with 75 minutes of test data!\n")