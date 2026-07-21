library(dplyr)
library(readr)
library(purrr)

# --- 1. Define Thresholds ---
DARK_THRESH   <- 150  
BRIGHT_THRESH <- 700  
ABRUPT_DIFF   <- 400  

# --- 2. Load the Data ---
# Find all files matching the "LOG_NNN.CSV" pattern in the working directory
file_list <- list.files(pattern = "^LOG_[0-9]{3}\\.CSV$", full.names = TRUE)

# Read all matching files and automatically append a 'filename' column
df <- map_dfr(file_list, ~read_csv(.x, show_col_types = FALSE) %>% 
                mutate(filename = basename(.x)))

# --- 3. Analyze and Filter ---
df_analyzed <- df %>%
  arrange(filename, Uptime_s) %>% # Ensure data is chronological per file
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
    
    # Classification
    is_flicker = (Min_Light < DARK_THRESH) & 
                 was_bright & 
                 returns_bright & 
                 (abrupt_intra | abrupt_drop | abrupt_rise | 
                  lag(abrupt_intra, 1) | lead(abrupt_intra, 1)),
    
    is_powered_off = (Max_Light < DARK_THRESH) & !was_bright & !returns_bright
  ) %>%
  
  # Filter out dead air (when the rig is actually turned off)
  filter(!is_powered_off) %>%
  
  # Keep only the relevant columns, now including the filename
  select(filename, Uptime_s, Min_Light, Max_Light, Avg_Light, Read_Count, is_flicker)

# --- 4. VIEW THE EVIDENCE ---
# Extract and print only the rows where a flicker was confirmed
flicker_events <- df_analyzed %>% filter(is_flicker == TRUE)
print(flicker_events)