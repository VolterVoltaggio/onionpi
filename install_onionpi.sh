#!/bin/bash

set -e

# ============================================================
# OnionPi Installer
# Raspberry Pi Tor WiFi AP — hostapd + Pi-hole + Tor
# ============================================================

echo "=== OnionPi Installer ==="
echo ""

# ------------------------------------------------------------
# 0. System update
# ------------------------------------------------------------
echo "[*] Updating system..."
sudo apt update && sudo apt upgrade

# ------------------------------------------------------------
# 1. rfkill — unblock wifi, then disable systemd-rfkill
#    (systemd-rfkill persists the soft-block across reboots)
# ------------------------------------------------------------
echo "[*] Unblocking WiFi..."
sudo rfkill unblock wifi
echo "[*] Disabling systemd-rfkill to prevent re-block on reboot..."
sudo systemctl stop systemd-rfkill
sudo systemctl disable systemd-rfkill
sudo rm -f /var/lib/systemd/rfkill/*

# ------------------------------------------------------------
# 2. Wireless interface selection
# ------------------------------------------------------------
IFACES=($(iw dev | awk '/Interface/ {print $2}'))

if [ ${#IFACES[@]} -eq 0 ]; then
    whiptail --title "OnionPi Installer" --msgbox \
        "No wireless interfaces found.\nPlug in your WiFi adapter and restart the script." \
        10 50
    exit 1
fi

# Build the whiptail menu items: each entry needs a tag and a description
MENU_ITEMS=()
for iface in "${IFACES[@]}"; do
    MENU_ITEMS+=("$iface" "")
done

WLAN_IFACE=$(whiptail --title "OnionPi Installer" \
    --menu "Select the wireless interface to use as AP:" \
    15 50 6 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3)

# Exit code 1 means the user pressed Cancel or ESC
if [ $? -ne 0 ] || [ -z "$WLAN_IFACE" ]; then
    echo "[!] No interface selected. Aborting."
    exit 1
fi

echo "[*] Selected interface: $WLAN_IFACE"

sudo ip link set "$WLAN_IFACE" up

# ------------------------------------------------------------
# 2b. Detect MAC and pin interface name via udev
# ------------------------------------------------------------
MAC=$(ip link show "$WLAN_IFACE" | awk '/ether/ {print $2}')
echo "[*] Detected MAC for $WLAN_IFACE: $MAC"
echo "[*] Pinning $WLAN_IFACE to wlan1 via udev rule..."

sudo sh -c 'cat > /etc/udev/rules.d/70-persistent-net.rules' <<EOF
SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="$MAC", NAME="wlan1"
EOF

# From this point on, the interface will always be wlan1 after reboot.
# Update WLAN_IFACE to match so all subsequent config is consistent.
WLAN_IFACE="wlan1"

# ------------------------------------------------------------
# 3. Configuration wizard
# ------------------------------------------------------------
SSID=$(whiptail --title "OnionPi Installer" \
    --inputbox "Network SSID:" \
    8 40 "OnionPi" 3>&1 1>&2 2>&3)
SSID="${SSID:-OnionPi}"

WIFI_PASS=$(whiptail --title "OnionPi Installer" \
    --passwordbox "WiFi password (min 8 chars, leave empty for open network):" \
    8 50 3>&1 1>&2 2>&3)

WIFI_CHANNEL=$(whiptail --title "OnionPi Installer" \
    --inputbox "WiFi 2.4GHz channel:" \
    8 40 "11" 3>&1 1>&2 2>&3)
WIFI_CHANNEL="${WIFI_CHANNEL:-11}"

COUNTRY_CODE=""
while [ -z "$COUNTRY_CODE" ]; do
    COUNTRY_CODE=$(whiptail --title "OnionPi Installer" \
        --inputbox "Country code (e.g. US, IT, DE):" \
        8 40 3>&1 1>&2 2>&3)
done

# ------------------------------------------------------------
# 4. Disable NetworkManager on the AP interface
# ------------------------------------------------------------
echo "[*] Configuring NetworkManager unmanaged device..."
sudo mkdir -p /etc/NetworkManager/conf.d/
sudo sh -c 'cat > /etc/NetworkManager/conf.d/onionpi-unmanaged.conf' <<EOF
[keyfile]
unmanaged-devices=interface-name:$WLAN_IFACE
EOF

sudo systemctl restart NetworkManager 2>/dev/null || true

# ------------------------------------------------------------
# 5. Static IP assignment
# ------------------------------------------------------------
echo "[*] Assigning static IP to $WLAN_IFACE..."
sudo ip addr flush dev "$WLAN_IFACE"
sudo ip addr add 10.0.0.1/24 dev "$WLAN_IFACE"
sudo ip link set "$WLAN_IFACE" up

# Persist static IP via /etc/network/interfaces
sudo sh -c 'cat > /etc/network/interfaces.d/onionpi' <<EOF
auto $WLAN_IFACE
iface $WLAN_IFACE inet static
    address 10.0.0.1
    netmask 255.255.255.0
EOF

# ------------------------------------------------------------
# 6. Regulatory domain
# ------------------------------------------------------------
echo "[*] Setting regulatory domain ($COUNTRY_CODE)..."
sudo iw reg set "$COUNTRY_CODE"
# Persist regulatory domain
sudo raspi-config nonint do_wifi_country "$COUNTRY_CODE" 2>/dev/null || \
    sudo sh -c 'cat > /etc/default/crda' <<EOF
REGDOMAIN=$COUNTRY_CODE
EOF

# ------------------------------------------------------------
# 7. Install packages
# ------------------------------------------------------------
echo "[*] Installing packages..."
sudo apt install -y hostapd tor iptables

sudo systemctl unmask hostapd

# ------------------------------------------------------------
# 8. hostapd configuration
# ------------------------------------------------------------
echo "[*] Writing hostapd.conf..."
sudo sh -c 'cat > /etc/hostapd/hostapd.conf' <<EOF
interface=$WLAN_IFACE
driver=nl80211
ssid=$SSID
hw_mode=g
channel=$WIFI_CHANNEL
country_code=$COUNTRY_CODE
ieee80211n=1
wmm_enabled=1
macaddr_acl=0
auth_algs=1
EOF

if [ -n "$WIFI_PASS" ]; then
sudo sh -c 'cat >> /etc/hostapd/hostapd.conf' <<EOF
wpa=2
wpa_passphrase=$WIFI_PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
else
sudo sh -c 'cat >> /etc/hostapd/hostapd.conf' <<EOF
wpa=0
EOF
fi

sudo sh -c 'cat > /etc/default/hostapd' <<EOF
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF

# systemd override: Type=simple avoids issues with USB drivers and the -B fork flag
sudo mkdir -p /etc/systemd/system/hostapd.service.d/
sudo sh -c 'cat > /etc/systemd/system/hostapd.service.d/override.conf' <<EOF
[Service]
Type=simple
ExecStart=
ExecStart=/usr/sbin/hostapd /etc/hostapd/hostapd.conf
EOF

# ------------------------------------------------------------
# 9. Pi-hole installation and configuration
# ------------------------------------------------------------
echo "[*] Installing Pi-hole..."
curl -sSL https://install.pi-hole.net | sudo bash -s -- --unattended

echo ""
echo "[*] Configuring Pi-hole for OnionPi..."

echo "[*] Upstreaming DNS to 127.0.0.1 by port 9053 (Tor DNSPort)..."
sudo pihole --config dns.upstreams '["127.0.0.1#9053"]'

echo "[*] Your interface will be wlan1..."
sudo pihole --config dns.interface wlan1

echo "[*] Your DHCP is active (range 10.0.0.10-10.0.0.50, router 10.0.0.1)..."
sudo pihole --config dhcp.active true
sudo pihole --config dhcp.start 10.0.0.10
sudo pihole --config dhcp.end 10.0.0.50
sudo pihole --config dhcp.router 10.0.0.1

echo "[*] Local listening mode..."
sudo pihole --config dns.listeningMode LOCAL

echo "[*] Restarting Pi-hole FTL..."
sudo systemctl restart pihole-FTL

# ------------------------------------------------------------
# 10. Tor configuration
# ------------------------------------------------------------
echo "[*] Writing torrc..."
sudo sh -c 'cat > /etc/tor/torrc' <<EOF
VirtualAddrNetworkIPv4 10.192.0.0/10
AutomapHostsOnResolve 1
AutomapHostsSuffixes .exit,.onion

TransPort 10.0.0.1:9040
DNSPort 127.0.0.1:9053

Log notice file /var/log/tor/notices.log
EOF

# ------------------------------------------------------------
# 11. Disable IPv6
# ------------------------------------------------------------
echo "[*] Disabling IPv6..."
sudo sh -c 'cat > /etc/sysctl.d/99-onionpi-ipv6.conf' <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
sudo sysctl -p /etc/sysctl.d/99-onionpi-ipv6.conf

# ------------------------------------------------------------
# 12. IP forwarding
# ------------------------------------------------------------
echo "[*] Enabling IP forwarding..."
sudo sh -c 'cat > /etc/sysctl.d/99-onionpi-forward.conf' <<EOF
net.ipv4.ip_forward = 1
EOF
sudo sysctl -p /etc/sysctl.d/99-onionpi-forward.conf

# ------------------------------------------------------------
# 13. iptables
# ------------------------------------------------------------
echo "[*] Configuring iptables..."

# Flush
sudo iptables -F
sudo iptables -t nat -F

# NAT outbound on ethernet interface
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i eth0 -o "$WLAN_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i "$WLAN_IFACE" -o eth0 -j ACCEPT

# Redirect DNS to Tor DNSPort
sudo iptables -t nat -A PREROUTING -i "$WLAN_IFACE" -p udp --dport 53 -j REDIRECT --to-ports 9053

# Redirect TCP traffic to Tor TransPort
sudo iptables -t nat -A PREROUTING -i "$WLAN_IFACE" -p tcp --syn -j REDIRECT --to-ports 9040

# Save rules
sudo mkdir -p /etc/iptables/
sudo sh -c 'iptables-save > /etc/iptables/rules.v4'

# Create service to restore rules on boot
sudo sh -c 'cat > /etc/systemd/system/iptables-restore.service' <<EOF
[Unit]
Description=Restore OnionPi iptables rules
Before=network.target
Before=hostapd.service

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable iptables-restore.service

# ------------------------------------------------------------
# 14. Enable and start services
# ------------------------------------------------------------
echo "[*] Enabling and starting services..."
sudo systemctl enable tor
sudo systemctl enable pihole-FTL
sudo systemctl enable hostapd

sudo systemctl restart tor
sudo systemctl restart pihole-FTL
sudo systemctl restart hostapd

# ------------------------------------------------------------
# Done
# ------------------------------------------------------------
echo ""
echo "=== Installation complete ==="
echo "    SSID:       $SSID"
echo "    Interface:  $WLAN_IFACE"
echo "    AP gateway: 10.0.0.1"
echo "    Channel:    $WIFI_CHANNEL"
echo "    Country:    $COUNTRY_CODE"
echo ""
echo "Reboot the Pi to apply all changes:"
echo "    sudo reboot"
