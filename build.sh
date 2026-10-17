#!/bin/sh
# Builds build/Folio.app. "./build.sh run" also restarts it.
# Signs with your Apple Development certificate, so macOS knows it as the same app across rebuilds; without one it signs
# ad-hoc.
set -e
cd "$(dirname "$0")"

swift build -c release
APP=build/Folio.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Folio "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp icon/Folio.icns "$APP/Contents/Resources/"

ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)
codesign --force --sign "${ID:--}" "$APP"
echo "Built $APP, signed with ${ID:-an ad-hoc signature}"

if [ "$1" = run ]; then
	pkill -x Folio || true
	open "$APP"
fi
