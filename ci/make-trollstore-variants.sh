#!/bin/bash
# Builds several TrollStore .tipa variants from an unsigned Payload/, each with more entitlements than
# the last, so that a "Failed to Open" after installing can be traced to the first entitlement that breaks it.
#
#   ci/make-trollstore-variants.sh <dir containing Payload/> <output dir>
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
JIT=dynamic-codesigning
MEM1=com.apple.developer.kernel.increased-memory-limit
MEM2=com.apple.developer.kernel.extended-virtual-addressing

write_entitlements "$TMP/app1.plist" get-task-allow
write_entitlements "$TMP/ext1.plist" get-task-allow
write_entitlements "$TMP/app2.plist" get-task-allow $JIT
write_entitlements "$TMP/app3.plist" get-task-allow $JIT $MEM1 $MEM2
write_entitlements "$TMP/ext3.plist" get-task-allow $MEM1

build_variant ts1-basic  "$TMP/app1.plist" "$TMP/ext1.plist"
build_variant ts2-jit    "$TMP/app2.plist" "$TMP/ext1.plist"
build_variant ts3-memory "$TMP/app3.plist" "$TMP/ext3.plist"
# Everything, including the private memorystatus entitlement (the repo's TrollStore entitlement files).
build_variant ts4-full   "$ROOT/src/ios/TrollStore.entitlements" "$ROOT/src/ios/RamDonor/TrollStore.entitlements"

ls -l "$OUT"
