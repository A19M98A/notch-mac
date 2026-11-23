#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
USER_NAME="$(whoami)"
HELPER_SRC="$ROOT_DIR/scripts/overlay_vpn_core.sh"
HELPER_DST="/usr/local/libexec/overlay-vpn-core.sh"
SUDOERS_FILE="/etc/sudoers.d/overlay-vpn"

echo "Installing standalone root-owned VPN core helper to $HELPER_DST..."
sudo mkdir -p /usr/local/libexec
sudo cp "$HELPER_SRC" "$HELPER_DST"
sudo chown root:wheel "$HELPER_DST"
sudo chmod 755 "$HELPER_DST"

TMP_SUDOERS="$(mktemp)"
cat > "$TMP_SUDOERS" <<EOF
$USER_NAME ALL=(root) NOPASSWD: $HELPER_DST *
EOF

echo "Validating sudoers rule..."
sudo visudo -cf "$TMP_SUDOERS"

echo "Installing sudoers rule to $SUDOERS_FILE..."
sudo cp "$TMP_SUDOERS" "$SUDOERS_FILE"
sudo chown root:wheel "$SUDOERS_FILE"
sudo chmod 440 "$SUDOERS_FILE"
rm -f "$TMP_SUDOERS"

echo "Done! Overlay can now connect/disconnect VPNs standalone without password prompts."
