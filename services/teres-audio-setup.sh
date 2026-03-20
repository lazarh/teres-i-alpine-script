#!/bin/sh
# teres-audio-setup.sh — Initialize ALSA mixer for Teres-I (Allwinner A64)
#
# The A64 has an internal audio codec (sun8i-codec) with analog output.
# This script loads the necessary modules and sets reasonable default levels.
#
# NOTE: This script is intentionally NOT run at boot to avoid disrupting the
# debug serial UART when using an audio-cable serial adapter. Call it manually
# after login or let startx invoke it via .xinitrc.
#
# Usage:
#   teres-audio-setup        (manual)
#   startx                   (invoked from .xinitrc automatically)

# Load audio modules
modprobe snd_soc_sunxi 2>/dev/null || true
modprobe snd_sun4i_i2s 2>/dev/null || true
modprobe snd_sun8i_codec 2>/dev/null || true
modprobe snd_sun8i_codec_analog 2>/dev/null || true

# Wait for ALSA card to appear
sleep 2

# Find the A64 audio card number (may not be card 0 if HDMI audio is present)
CARD=$(aplay -l 2>/dev/null \
    | grep -i "sun50i\|a64\|sun8i" \
    | grep -o "card [0-9]*" | head -1 | grep -o "[0-9]*")
CARD=${CARD:-0}
echo "Audio: using ALSA card ${CARD}"

# Set mixer levels — try both long and short control name variants
amixer -q -c "$CARD" sset 'Headphone Playback Volume' 100% 2>/dev/null || \
    amixer -q -c "$CARD" sset 'Headphone' 100% 2>/dev/null || true

amixer -q -c "$CARD" sset 'Headphone Playback Switch' on 2>/dev/null || \
    amixer -q -c "$CARD" sset 'Headphone' unmute 2>/dev/null || true

amixer -q -c "$CARD" sset 'Line Out Playback Volume' 80% 2>/dev/null || \
    amixer -q -c "$CARD" sset 'Line Out' 80% 2>/dev/null || true

amixer -q -c "$CARD" sset 'Line Out Playback Switch' on 2>/dev/null || \
    amixer -q -c "$CARD" sset 'Line Out' unmute 2>/dev/null || true

amixer -q -c "$CARD" sset 'DAC Playback Volume' 100% 2>/dev/null || \
    amixer -q -c "$CARD" sset 'DAC' 100% 2>/dev/null || true

amixer -q -c "$CARD" sset 'Master Playback Volume' 100% 2>/dev/null || true

# Store ALSA state for next session
alsactl store -c "$CARD" 2>/dev/null || true
echo "Audio: mixer levels set on card ${CARD}"
