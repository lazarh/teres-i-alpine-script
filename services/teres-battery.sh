#!/bin/sh
# teres-battery.sh — Display AXP803 battery status from sysfs
#
# The Teres-I uses an AXP803 PMIC. The kernel exposes battery info at
# /sys/class/power_supply/axp20x-battery/ when CONFIG_BATTERY_AXP20X=m
# is loaded.

BATTERY_PATH="/sys/class/power_supply/axp20x-battery"
CHARGER_PATH="/sys/class/power_supply/axp20x-ac"

if [ ! -d "$BATTERY_PATH" ]; then
    # Try loading the module
    modprobe axp20x_battery 2>/dev/null
    sleep 1
fi

if [ ! -d "$BATTERY_PATH" ]; then
    echo "Battery: not detected (AXP20X battery module not loaded?)"
    exit 1
fi

status=$(cat "$BATTERY_PATH/status" 2>/dev/null || echo "Unknown")
capacity=$(cat "$BATTERY_PATH/capacity" 2>/dev/null || echo "?")
voltage=$(cat "$BATTERY_PATH/voltage_now" 2>/dev/null || echo "0")
current=$(cat "$BATTERY_PATH/current_now" 2>/dev/null || echo "0")

# Convert from microvolts/microamps to human-readable
voltage_v=$(awk "BEGIN {printf \"%.2f\", ${voltage}/1000000}")
current_ma=$(awk "BEGIN {printf \"%.0f\", ${current}/1000}")

echo "Battery: ${capacity}% (${status})"
echo "Voltage: ${voltage_v}V  Current: ${current_ma}mA"

# AC/charger status
if [ -d "$CHARGER_PATH" ]; then
    ac_online=$(cat "$CHARGER_PATH/online" 2>/dev/null || echo "0")
    if [ "$ac_online" = "1" ]; then
        echo "AC: connected"
    else
        echo "AC: disconnected"
    fi
fi
