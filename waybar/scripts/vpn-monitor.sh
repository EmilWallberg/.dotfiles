#!/bin/bash

# Function to check current VPN state and output JSON to Waybar
check_vpn_status() {
    # Detects interfaces starting with tun, ppp, or vpn
    INTERFACE=$(ip addr show | grep -E "tun|ppp|vpn" | awk '{print $NF}' | head -n 1)
    
    if [ -z "$INTERFACE" ]; then
        # Send empty JSON to hide the module when disconnected
        echo "{\"text\": \"\", \"class\": \"disconnected\"}"
    else
        # Send icon and interface name when connected
        echo "{\"text\": \"󰆧 $INTERFACE\", \"class\": \"connected\", \"tooltip\": \"VPN active on $INTERFACE\"}"
    fi
}

# 1. Initial check when Waybar starts
check_vpn_status

# 2. Start the Listener: 'ip monitor' blocks and waits for Kernel Netlink events
# This uses effectively 0% CPU while waiting.
ip --monitor addr | while read -r line; do
    # If any address change involves a VPN interface, re-run the check
    if echo "$line" | grep -iqE "tun|ppp|vpn"; then
        check_vpn_status
    fi
done
