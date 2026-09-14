#!/bin/bash
# Generates the import fixtures from the app icon (sips cannot write RAW files,
# so src.nef is a JPEG payload carrying a .NEF name — enough to assert that
# Photos keeps the RAW extension the source device reported).
set -euo pipefail
cd "$(dirname "$0")"
ICON=../../CamSync/Assets.xcassets/AppIcon.appiconset/CamSync-AppIcon-1024.png
mkdir -p VerifyTests/Fixtures
sips -s format jpeg "$ICON" --out VerifyTests/Fixtures/src.jpg  >/dev/null
sips -s format heic "$ICON" --out VerifyTests/Fixtures/src.heic >/dev/null
sips -s format png  "$ICON" --out VerifyTests/Fixtures/src.png  >/dev/null
cp VerifyTests/Fixtures/src.jpg VerifyTests/Fixtures/src.nef
echo "fixtures ready:"; ls -l VerifyTests/Fixtures
