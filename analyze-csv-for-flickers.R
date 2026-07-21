suppressPackageStartupMessages(library(dplyr))
suppressPackageStartupMessages(library(readr))
suppressPackageStartupMessages(library(purrr))

# --- 1. Define Thresholds ---
DARK_THRESH   <- 150
BRIGHT_THRESH <- 700
ABRUPT_DIFF   <- 400

# --- 2. Load the Data ---
# Find all files matching the "LOG_NNN.CSV" pattern in the working directory
file_list <- list.files(pattern = "^LOG_[0-9]{3}\\.CSV$", full.names = TRUE)

# Read all matching files and automatically append a 'filename' column
df <- map_dfr(file_list, ~read_csv(.x, show_col_types = FALSE) |>
                mutate(filename = basename(.x)))

# --- 3. Analyze and Filter ---
df_analyzed <- df |>
  arrange(filename, Uptime_s) |>

  # -- ISOLATE POWER CYCLES --
  mutate(
    # Check the gap between this row's time and the previous row's time
    time_gap = Uptime_s - lag(Uptime_s, default = first(Uptime_s)),
    # It's a new session if time went backward (reboot) or jumped > 5 seconds (unplugged)
    is_new_session = time_gap < 0 | time_gap > 5,
    # Create a unique ID for each continuous block of time
    session_id = cumsum(is_new_session)
  ) |>

  # Force lag() and lead() to stay within the current continuous session
  group_by(session_id) |>

  mutate(
    # Establish context
    was_bright = lag(Max_Light, 1, default = 0) > BRIGHT_THRESH |
                 lag(Max_Light, 2, default = 0) > BRIGHT_THRESH,

    returns_bright = lead(Max_Light, 1, default = 0) > BRIGHT_THRESH |
                     lead(Max_Light, 2, default = 0) > BRIGHT_THRESH |
                     lead(Max_Light, 3, default = 0) > BRIGHT_THRESH,

    # Prove abruptness
    abrupt_intra = (Max_Light > BRIGHT_THRESH) & (Min_Light < DARK_THRESH),
    abrupt_drop = (lag(Avg_Light, 1, default = 0) - Avg_Light) > ABRUPT_DIFF,
    abrupt_rise = (Avg_Light - lag(Avg_Light, 1, default = 0)) > ABRUPT_DIFF,

    # Classification (Using default = FALSE for logical lags at boundaries)
    is_flicker = (Min_Light < DARK_THRESH) &
                 was_bright &
                 returns_bright &
                 (abrupt_intra | abrupt_drop | abrupt_rise |
                  lag(abrupt_intra, 1, default = FALSE) | lead(abrupt_intra, 1, default = FALSE)),

    is_powered_off = (Max_Light < DARK_THRESH) & !was_bright & !returns_bright
  ) |>

  # Always ungroup after window calculations
  ungroup() |>

  # Filter out dead air
  filter(!is_powered_off) |>

  # Keep relevant columns
  select(filename, session_id, Uptime_s, Min_Light, Max_Light, Avg_Light, Read_Count, is_flicker)

# --- 4. VIEW THE EVIDENCE ---
# Extract and print only the rows where a flicker was confirmed
flicker_events <- df_analyzed |> filter(is_flicker == TRUE)
print(flicker_events)
