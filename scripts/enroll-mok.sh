#!/usr/bin/env bash
# One-time Machine Owner Key (MOK) enrollment so the Roland Capture kernel
# module can be signed while keeping Secure Boot enabled.
#
# Run this ONCE. It generates an RSA keypair, enrolls the public key into the
# MOK database, and prompts you to reboot and confirm the enrollment in the
# firmware MokManager. After that, install-native-driver.sh signs the module
# automatically before installing it.
#
# Usage:
#   ./scripts/enroll-mok.sh
set -euo pipefail

key_dir=/etc/mok
priv=$key_dir/octa-capture.priv
der=$key_dir/octa-capture.der

for c in openssl mokutil install; do
    command -v "$c" >/dev/null || { echo "Missing required command: $c" >&2; exit 1; }
done

if [[ -f $priv && -f $der ]]; then
    echo "A MOK keypair already exists at $key_dir"
else
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    echo "Generating an RSA signing keypair..."
    openssl req -new -x509 -newkey rsa:2048 \
        -keyout "$tmp/octa-capture.priv" \
        -outform DER -out "$tmp/octa-capture.der" \
        -nodes -days 36500 -subj "/CN=Octa Capture module signing/" \
        >/dev/null 2>&1
    sudo install -d -m 0700 "$key_dir"
    sudo install -m 0600 "$tmp/octa-capture.priv" "$priv"
    sudo install -m 0644 "$tmp/octa-capture.der" "$der"
    echo "Generated MOK keypair at $key_dir"
fi

echo
echo "Enrolling the public key into the MOK database. You will be prompted to"
echo "choose a one-time password (used only at the next boot to confirm)."
sudo mokutil --import "$der"

cat <<'EOF'

Next steps:
  1. Reboot. The firmware MokManager menu will appear.
     Select: "Enroll MOK" -> "Continue" -> "Yes" -> enter the password you
     just chose -> reboot.
  2. (Optional) confirm the key is enrolled: mokutil --list-enrolled
  3. Build and install the signed driver: ./scripts/install-native-driver.sh

The private key lives at /etc/mok/octa-capture.priv (root-only). Keep it; it is
required to re-sign the module after each kernel upgrade.
EOF
