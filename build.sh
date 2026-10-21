#!/bin/sh
# Builds build/Folio.app. "./build.sh run" also restarts it.
# Signs with your Apple Development certificate, so macOS knows it as the same app across rebuilds; without one it signs
# ad-hoc.
# "./build.sh dmg" builds build/Folio.dmg to publish instead: signed with your Developer ID, notarised and stapled. It
# needs a notarytool keychain profile named "notary" (or $NOTARY), made once with `xcrun notarytool store-credentials`.
# Finder lays out the dmg's window, so macOS asks once to let your terminal control Finder.
# "./build.sh ios" builds the iPhone and iPad app instead, with XcodeGen (brew install xcodegen), and runs it in the
# simulator on an iPhone 17 Pro.
set -e
cd "$(dirname "$0")"

if [ "$1" = ios ]; then
	DEVICE=$(xcrun simctl list devices available | grep -m1 'iPhone 17 Pro (' | grep -oE '[0-9A-F-]{36}')
	xcodegen --quiet
	xcodebuild -quiet -project Folio.xcodeproj -scheme Folio -destination "id=$DEVICE" -derivedDataPath .build/ios build
	xcrun simctl bootstatus "$DEVICE" -b >/dev/null
	open -a DeviceHub 2>/dev/null || open -a Simulator
	xcrun simctl install "$DEVICE" .build/ios/Build/Products/Debug-iphonesimulator/Folio.app
	xcrun simctl launch "$DEVICE" com.josephhamze.folio
	exit
fi

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
	mkdir "$STAGE/.background"
	cp icon/dmg.png "$STAGE/.background"
	cp icon/Folio.icns "$STAGE/.VolumeIcon.icns"
	rm -f build/Folio-rw.dmg build/Folio.dmg
	diskutil image create from "$STAGE" build/Folio-rw.dmg --format RAW --volumeName Folio
	MOUNT=$(diskutil image attach build/Folio-rw.dmg | grep -o '/Volumes/.*')
	SetFile -a C "$MOUNT"
	# Finder lays out the window, on icon/dmg.png's arrow, and saves it in the volume's .DS_Store when it ejects it.
	# The window's 432 points tall: a 32-point title bar over the background's top 400.
	osascript - "$(basename "$MOUNT")" <<-'EOF'
		on run {volumeName}
			tell application "Finder" to tell disk volumeName
				open
				tell container window
					set current view to icon view
					set toolbar visible to false
					set statusbar visible to false
					set pathbar visible to false
					set bounds to {400, 240, 1040, 672}
				end tell
				set opts to icon view options of container window
				set arrangement of opts to not arranged
				set icon size of opts to 128
				set background picture of opts to file ".background:dmg.png"
				set position of item "Folio.app" to {160, 160}
				set position of item "Applications" to {480, 160}
				set extension hidden of item "Folio.app" to true
				close
				eject
			end tell
		end run
	EOF
	diskutil image create from build/Folio-rw.dmg build/Folio.dmg
	rm -rf "$STAGE" build/Folio.zip build/Folio-rw.dmg
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
