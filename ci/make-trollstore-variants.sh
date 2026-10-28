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
# dynamic-codesigning is deliberately left out: with it TrollStore installs the app but iOS 16.3.1 refuses
# to launch it ("Failed to Open"). JIT is enabled by the attached enabler instead.
MEM1=com.apple.developer.kernel.increased-memory-limit
MEM2=com.apple.developer.kernel.extended-virtual-addressing
STATUS=com.apple.private.memorystatus

write_entitlements "$TMP/app1.plist" get-task-allow
write_entitlements "$TMP/ext1.plist" get-task-allow
write_entitlements "$TMP/app2.plist" get-task-allow $MEM1
write_entitlements "$TMP/ext2.plist" get-task-allow $MEM1
write_entitlements "$TMP/app3.plist" get-task-allow $MEM1 $MEM2
write_entitlements "$TMP/app4.plist" get-task-allow $MEM1 $MEM2 $STATUS
write_entitlements "$TMP/ext4.plist" get-task-allow $MEM1 $STATUS

build_variant ts1-basic       "$TMP/app1.plist" "$TMP/ext1.plist"   # known to launch
build_variant ts2-memlimit    "$TMP/app2.plist" "$TMP/ext2.plist"   # + increased-memory-limit
build_variant ts3-memvirtual  "$TMP/app3.plist" "$TMP/ext2.plist"   # + extended-virtual-addressing
build_variant ts4-memstatus   "$TMP/app4.plist" "$TMP/ext4.plist"   # + com.apple.private.memorystatus

ls -l "$OUT"
