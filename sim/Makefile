CC ?= cc
CFLAGS ?= -std=c11 -Wall -Wextra -Wpedantic -O2
SIM_BUILD_DIR := build
TARGET := $(SIM_BUILD_DIR)/flicker-sim
SOURCES := flicker_sim.c

.PHONY: all test clean

all: $(TARGET)

$(TARGET): $(SOURCES)
	@mkdir -p $(SIM_BUILD_DIR)
	$(CC) $(CFLAGS) -o $@ $(SOURCES)

test: $(TARGET)
	./$(TARGET)

clean:
	rm -rf $(SIM_BUILD_DIR)
