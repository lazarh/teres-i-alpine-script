#!/bin/sh
# Check if eDP display is connected, reboot if not

LOG_TAG="check-edp"

# Wait a bit for DRM to initialize
sleep 2

# Check eDP status (card1-eDP-1 is the eDP on Teres-I)
EDP_STATUS=$(cat /sys/class/drm/card1-eDP-1/status 2>/dev/null)

if [ "$EDP_STATUS" != "connected" ]; then
    echo "[$LOG_TAG] eDP not connected (status: $EDP_STATUS), rebooting in 5 seconds..."
    sleep 5
    reboot
else
    echo "[$LOG_TAG] eDP is connected"
fi
