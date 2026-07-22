suppressPackageStartupMessages(library(dplyr))
suppressPackageStartupMessages(library(readr))
suppressPackageStartupMessages(library(purrr))


# --- 1. Define Thresholds ---
DARK_THRESH   <- 50
BRIGHT_THRESH <- 300
ABRUPT_DIFF   <- 250

# --- 2. Load the Data ---
# Find all files matching the "LOG_NNN.CSV" pattern in the working directory
file_list <- list.files(pattern = "^LOG_[0-9]{3}\\.CSV$", full.names = TRUE)

# Force strict column types so empty files don't default to 'character'
log_col_types <- cols(
  Uptime_s = col_double(),
  Min_Light = col_double(),
  Max_Light = col_double(),
  Avg_Light = col_double(),
  Read_Count = col_double()
)

# Read files safely, discarding any that contain zero data rows
df <- map_dfr(file_list, function(file) {
  temp_df <- read_csv(file, col_types = log_col_types)

  if (nrow(temp_df) == 0) {
    return(NULL) # map_dfr will gracefully ignore NULL returns
  }

  temp_df %>% mutate(filename = basename(file))
})

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

  # -- FORMAT TIME STRING --
  mutate(
    hours = floor(Uptime_s / 3600),
    minutes = floor((Uptime_s %% 3600) / 60),
    seconds = Uptime_s %% 60,
    # sprintf pads minutes and seconds with leading zeros (e.g., 01:05:09)
    Uptime_hms = sprintf("%d:%02d:%02d", hours, minutes, seconds)
  ) |>

  # Keep relevant columns
  select(filename, Uptime_hms, Min_Light, Max_Light, Avg_Light, Read_Count, is_flicker)

# --- 4. VIEW THE EVIDENCE ---
# Extract and print only the rows where a flicker was confirmed
flicker_events <- df_analyzed |> filter(is_flicker == TRUE)
flicker_events |> print(n = Inf)
