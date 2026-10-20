#!/bin/sh
# Builds build/Folio.app. "./build.sh run" also restarts it.
# Signs with your Apple Development certificate, so macOS knows it as the same app across rebuilds; without one it signs
# ad-hoc.
# "./build.sh dmg" builds build/Folio.dmg to publish instead: signed with your Developer ID, notarised and stapled. It
# needs a notarytool keychain profile named "notary" (or $NOTARY), made once with `xcrun notarytool store-credentials`.
set -e
cd "$(dirname "$0")"

swift build -c release
APP=build/Folio.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Folio "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp icon/Folio.icns "$APP/Contents/Resources/"

if [ "$1" = dmg ]; then
	ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)
	[ -n "$ID" ] || { echo "A dmg needs a Developer ID Application certificate"; exit 1; }
	codesign --force --options runtime --timestamp --sign "$ID" "$APP"
	# The app is notarised and stapled on its own too, so it opens offline once it's copied out of the dmg.
	ditto -c -k --keepParent "$APP" build/Folio.zip
	xcrun notarytool submit build/Folio.zip --keychain-profile "${NOTARY:-notary}" --wait
	xcrun stapler staple "$APP"
	STAGE=$(mktemp -d)
	cp -R "$APP" "$STAGE"
	ln -s /Applications "$STAGE/Applications"
	hdiutil create -volname Folio -srcfolder "$STAGE" -format UDZO -ov build/Folio.dmg
	rm -rf "$STAGE" build/Folio.zip
	codesign --sign "$ID" --timestamp build/Folio.dmg
	xcrun notarytool submit build/Folio.dmg --keychain-profile "${NOTARY:-notary}" --wait
	xcrun stapler staple build/Folio.dmg
	echo "Built build/Folio.dmg, signed with $ID and notarised"
	exit
fi

ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)
codesign --force --sign "${ID:--}" "$APP"
echo "Built $APP, signed with ${ID:-an ad-hoc signature}"

if [ "$1" = run ]; then
	pkill -x Folio || true
	open "$APP"
fi
