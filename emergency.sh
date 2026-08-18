#!/bin/bash
# Fence Emergency Wipe Script
# Run with: sudo ./emergency.sh

set -e

echo "=== Fence Emergency Wipe ==="

# 1. Stop daemon
echo "Stopping daemon..."
launchctl bootout system/org.eyebeam.selfcontrold 2>/dev/null || echo "Daemon not running"

# 2. Clear firewall rules
echo "Clearing firewall rules..."
# Flush rules from anchor
pfctl -a org.eyebeam -F all 2>/dev/null || echo "No pf rules to clear"
# Empty the anchor file
: > /etc/pf.anchors/org.eyebeam 2>/dev/null || true
# Remove org.eyebeam references from pf.conf
if [ -f /etc/pf.conf ]; then
    sed -i '' '/org\.eyebeam/d' /etc/pf.conf
    echo "Cleaned pf.conf"
fi
# Reload pf config
pfctl -f /etc/pf.conf 2>/dev/null || true

# 3. Clear hosts file
echo "Clearing hosts file..."
sed -i '' '/# BEGIN SELFCONTROL BLOCK/,/# END SELFCONTROL BLOCK/d' /etc/hosts

# 4. Flush DNS cache
echo "Flushing DNS cache..."
dscacheutil -flushcache
killall -HUP mDNSResponder 2>/dev/null || true

# 5. Clear Fence's settings plist. SCSettings derives the filename from the
# hardware serial; do the same here so an emergency wipe can never delete an
# unrelated hidden plist in /usr/local/etc.
echo "Clearing settings plist..."
SERIAL_NUMBER=$(/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice | /usr/bin/awk -F'"' '/IOPlatformSerialNumber/{print $(NF-1); exit}')
if [ -z "$SERIAL_NUMBER" ]; then
    echo "Unable to determine the Fence settings filename" >&2
    exit 1
fi
SETTINGS_HASH=$(printf 'SelfControlUserPreferences%s' "$SERIAL_NUMBER" | /usr/bin/shasum -a 1 | /usr/bin/awk '{print $1}')
SETTINGS_FILE="/usr/local/etc/.${SETTINGS_HASH}.plist"
rm -f -- "$SETTINGS_FILE"

# 6. Clear schedule/commitment data from user defaults (run as actual user, not root)
echo "Clearing user defaults..."
CONSOLE_USER=$(stat -f "%Su" /dev/console)
sudo -u "$CONSOLE_USER" defaults delete org.eyebeam.Fence SCIsCommitted 2>/dev/null || true
sudo -u "$CONSOLE_USER" defaults delete org.eyebeam.Fence SCWeeklySchedules 2>/dev/null || true
sudo -u "$CONSOLE_USER" defaults delete org.eyebeam.Fence SCRecurringCommitment 2>/dev/null || true
sudo -u "$CONSOLE_USER" defaults delete org.eyebeam.Fence SCActiveTimedBreak 2>/dev/null || true

# Clear week-specific keys (check for any SCWeekSchedules_* or SCWeekCommitment_*)
for key in $(sudo -u "$CONSOLE_USER" defaults read org.eyebeam.Fence 2>/dev/null | grep -oE "SCWeek(Schedules|Commitment)_[0-9-]+" | sort -u); do
    echo "  Deleting $key..."
    sudo -u "$CONSOLE_USER" defaults delete org.eyebeam.Fence "$key" 2>/dev/null || true
done

# 7. Uninstall schedule launchd jobs
echo "Uninstalling schedule jobs..."
CONSOLE_USER=$(stat -f "%Su" /dev/console)
CONSOLE_UID=$(id -u "$CONSOLE_USER")
for plist in /Users/"$CONSOLE_USER"/Library/LaunchAgents/org.eyebeam.selfcontrol.schedule.*.plist; do
    if [ -f "$plist" ]; then
        label=$(basename "$plist" .plist)
        sudo -u "$CONSOLE_USER" launchctl bootout gui/"$CONSOLE_UID"/"$label" 2>/dev/null || true
        rm "$plist"
        echo "  Removed $label"
    fi
done

echo ""
echo "=== Wipe Complete ==="

# Return a fixed-format, non-sensitive postcondition token to the app. The app
# consumes an emergency credit only when every physical layer verifies clean.
SETTINGS_CLEARED=1
HOSTS_CLEAN=1
PF_CLEAN=1

if [ -e "$SETTINGS_FILE" ] || [ -L "$SETTINGS_FILE" ]; then
    SETTINGS_CLEARED=0
fi

if grep -q '# BEGIN SELFCONTROL BLOCK' /etc/hosts 2>/dev/null; then
    HOSTS_CLEAN=0
fi

PF_RULES=$(pfctl -a org.eyebeam -sr 2>/dev/null || true)
if [ -n "$(printf '%s' "$PF_RULES" | tr -d '[:space:]')" ] || \
   grep -q 'org\.eyebeam' /etc/pf.conf 2>/dev/null || \
   [ -s /etc/pf.anchors/org.eyebeam ]; then
    PF_CLEAN=0
fi

printf 'FENCE_EMERGENCY_VERIFY settings=%s hosts=%s pf=%s\n' \
    "$SETTINGS_CLEARED" "$HOSTS_CLEAN" "$PF_CLEAN"
