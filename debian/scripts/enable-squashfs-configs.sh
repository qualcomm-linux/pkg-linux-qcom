#!/bin/bash
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 /path/to/kernel-src"
  exit 1
fi

KERNEL_SRC=$(realpath "$1")
DEFCONFIG_REL="arch/arm64/configs/defconfig"
DEFCONFIG_PATH="$KERNEL_SRC/$DEFCONFIG_REL"

if [ ! -f "$DEFCONFIG_PATH" ]; then
  echo "Error: defconfig not found at $DEFCONFIG_PATH"
  exit 1
fi

REQUIRED_CONFIGS=(
  CONFIG_SQUASHFS
  CONFIG_SQUASHFS_XZ
  CONFIG_SQUASHFS_LZO
  CONFIG_SQUASHFS_XATTR
  CONFIG_SQUASHFS_ZLIB
  CONFIG_SQUASHFS_LZ4
)

MODIFIED=0
if ! grep -q "Added for Ubuntu SQUASHFS compatibility" "$DEFCONFIG_PATH"; then
  echo -e "\n# Added for Ubuntu SQUASHFS compatibility" >> "$DEFCONFIG_PATH"
  MODIFIED=1
fi

for cfg in "${REQUIRED_CONFIGS[@]}"; do
  if ! grep -qE "^($cfg=|# $cfg is not set)" "$DEFCONFIG_PATH"; then
    echo "$cfg=y" >> "$DEFCONFIG_PATH"
    MODIFIED=1
  fi
done

[ "$MODIFIED" -eq 1 ] && echo "[INFO] Updated SQUASHFS options in defconfig."
