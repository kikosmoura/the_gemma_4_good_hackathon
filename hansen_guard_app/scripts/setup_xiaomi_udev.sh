#!/usr/bin/env bash
set -euo pipefail

RULE_FILE="/etc/udev/rules.d/51-android-xiaomi.rules"
RULE_CONTENT='SUBSYSTEM=="usb", ATTR{idVendor}=="2717", MODE="0660", GROUP="plugdev", TAG+="uaccess"'

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Execute este script com sudo: sudo $0" >&2
  exit 1
fi

printf '%s\n' "$RULE_CONTENT" > "$RULE_FILE"
udevadm control --reload-rules
udevadm trigger

echo "Regra instalada em $RULE_FILE"
echo "Agora reconecte o telefone e rode: $HOME/Android/Sdk/platform-tools/adb devices"