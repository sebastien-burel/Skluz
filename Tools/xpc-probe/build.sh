#!/bin/sh
#
# Builds the skluzd XPC probe in three flavors, to check the daemon's
# client requirement (PLAN_SKLUZD.md phase 4):
#   build/xpc-probe/unsigned   no signature at all            → must be refused
#   build/xpc-probe/adhoc-cli  ad hoc, -i net.haruni.skluz.cli → must be refused
#   build/xpc-probe/team-cli   team certificate, CLI identifier → accepted
#
# Usage: Tools/xpc-probe/build.sh

set -eu

cd "$(dirname "$0")/../.."
OUT=build/xpc-probe
mkdir -p "$OUT"

# SkluzCore sources are compiled in, so no module import is needed.
swiftc -O -swift-version 6 -o "$OUT/probe" \
  SkluzCore/Sources/SkluzCore/*.swift Tools/xpc-probe/main.swift

cp "$OUT/probe" "$OUT/unsigned"
codesign --remove-signature "$OUT/unsigned" 2>/dev/null || true

cp "$OUT/probe" "$OUT/adhoc-cli"
codesign --force --sign - --identifier net.haruni.skluz.cli "$OUT/adhoc-cli"

# Any team certificate works: Apple Development is enough for a local check.
IDENTITY=$(security find-identity -v -p codesigning | awk '/\(82FW35VV68\)|Apple Development/ {print $2; exit}')
cp "$OUT/probe" "$OUT/team-cli"
codesign --force --sign "$IDENTITY" --identifier net.haruni.skluz.cli "$OUT/team-cli"
codesign -dv "$OUT/team-cli" 2>&1 | grep -E 'Identifier|TeamIdentifier'

rm "$OUT/probe"
echo "Built in $OUT/"
