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
modprobe snd_sun8i_codec 2>/dev/null || true
modprobe snd_sun8i_codec_analog 2>/dev/null || true
modprobe snd_sun4i_i2s 2>/dev/null || true

# Wait for ALSA card to appear
sleep 1

# Set default mixer levels if amixer is available
if command -v amixer >/dev/null 2>&1; then
    # Unmute and set headphone volume to 70%
    amixer -q sset 'Headphone' 70% unmute 2>/dev/null || true
    # Unmute and set speaker/lineout
    amixer -q sset 'Line Out' 70% unmute 2>/dev/null || true
    # Unmute DAC
    amixer -q sset 'DAC' 80% unmute 2>/dev/null || true
    # Store ALSA state
    alsactl store 2>/dev/null || true
    echo "Audio: mixer levels set"
else
    echo "Audio: amixer not found, skipping mixer setup"
fi
