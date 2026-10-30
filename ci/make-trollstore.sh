#!/bin/bash
# Builds the TrollStore .tipa (EspressU-TrollStore.tipa) from an unsigned Payload/, fake-signed with the
# entitlements the RAM donor needs (increased memory limit, extended virtual addressing, memorystatus).
#
#   ci/make-trollstore.sh <dir containing Payload/> <output dir>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$2"
# Absolute paths: build_variant changes directory before it zips.
SRC="$(cd "$1" && pwd)"
OUT="$(cd "$2" && pwd)"

write_entitlements() { # <file> <keys...>
  local file="$1"; shift
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    for key in "$@"; do echo "<key>$key</key><true/>"; done
    echo '</dict></plist>'
  } > "$file"
}

build_variant() { # <name> <app entitlements file> <extension entitlements file>
  local name="$1" app_ent="$2" ext_ent="$3"
  local work; work="$(mktemp -d)"
  cp -R "$SRC/Payload" "$work/Payload"
  local app="$work/Payload/EspressU.app"
  ldid -S"$app_ent" "$app/EspressU"
  ldid -S"$ext_ent" "$app/PlugIns/EspressURamDonor.appex/EspressURamDonor"
  echo "== $name: app entitlements"; ldid -e "$app/EspressU" | grep '<key>' || true
  (cd "$work" && zip -qry "$OUT/EspressU-$name.tipa" Payload)
  rm -rf "$work"
}

TMP="$(mktemp -d)"
# dynamic-codesigning is deliberately left out: with it TrollStore installs the app but iOS 16.3.1 refuses
# to launch it ("Failed to Open"). JIT is enabled by the attached enabler instead.
MEM1=com.apple.developer.kernel.increased-memory-limit
MEM2=com.apple.developer.kernel.extended-virtual-addressing
STATUS=com.apple.private.memorystatus

write_entitlements "$TMP/app.plist" get-task-allow $MEM1 $MEM2 $STATUS
write_entitlements "$TMP/ext.plist" get-task-allow $MEM1 $STATUS

build_variant TrollStore "$TMP/app.plist" "$TMP/ext.plist"

ls -l "$OUT"
