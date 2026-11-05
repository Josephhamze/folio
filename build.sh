#!/bin/sh
# Builds build/Folio.app. "./build.sh run" also restarts it.
# Signs with your Apple Development certificate, so macOS knows it as the same app across rebuilds; without one it signs
# ad-hoc.
# "./build.sh dmg" builds build/Folio.dmg to publish instead: signed with your Developer ID, notarised and stapled. It
# needs a notarytool keychain profile named "notary" (or $NOTARY), made once with `xcrun notarytool store-credentials`.
# Finder lays out the dmg's window, so macOS asks once to let your terminal control Finder.
# "./build.sh ios" builds the iPhone and iPad app instead, with XcodeGen (brew install xcodegen), and runs it in the
# simulator on an iPhone 17 Pro. "./build.sh ios-test" runs its tests on an iPhone 17 Pro and an iPad Pro 13-inch, or
# only the tests named after it, such as FolioTouchTests or FolioUITests/ScreenshotTests/testMarkUpByTouch, and
# "./build.sh screenshots" takes the App Store's screenshots, on an iPhone 17 Pro Max and an iPad Pro 13-inch, into
# build/app-store, and frames them with a headline each for the listing, into build/app-store/listing.
# "./build.sh ios-release" uploads a build to App Store Connect. Xcode signs it with the team's Apple Account, added in
# Xcode › Settings › Accounts; on GitHub, the TestFlight workflow runs it with an App Store Connect API key instead.
set -e
cd "$(dirname "$0")"

# Runs the iOS tests, or only the test $2, on the simulator named $1: on a fresh install, with the samples in Folio's
# Documents folder, and 9:41 in the status bar until the simulator restarts. The results are in .build/ios/$1.xcresult.
ios_test() {
	DEVICE=$(xcrun simctl list devices available | grep -m1 "$1 (" | grep -oE '[0-9A-F-]{36}')
	[ -n "$DEVICE" ] || { echo "No $1 simulator: add one in Xcode › Window › Devices and Simulators"; exit 1; }
	xcrun simctl bootstatus "$DEVICE" -b >/dev/null
	xcrun simctl status_bar "$DEVICE" override --time 9:41 --batteryState charged --batteryLevel 100
	# Photos for Create from Photos to choose, whatever the simulator came with.
	xcrun simctl addmedia "$DEVICE" icon/logo.png icon/dmg.png
	xcrun simctl uninstall "$DEVICE" com.alphapms.folio
	xcrun simctl install "$DEVICE" .build/ios/Build/Products/Debug-iphonesimulator/Folio.app
	DOCS=$(xcrun simctl get_app_container "$DEVICE" com.alphapms.folio data)/Documents
	mkdir -p "$DOCS" && cp Tests/FolioUITests/*.pdf "$DOCS"
	rm -rf ".build/ios/$1.xcresult"
	xcodebuild -quiet -project Folio.xcodeproj -scheme Folio -destination "id=$DEVICE" -derivedDataPath .build/ios \
		-resultBundlePath ".build/ios/$1.xcresult" test-without-building ${2:+"-only-testing:$2"}
}

if [ "$1" = ios-test ] || [ "$1" = screenshots ]; then
	xcodegen --quiet
	xcodebuild -quiet -project Folio.xcodeproj -scheme Folio -destination "generic/platform=iOS Simulator" -derivedDataPath .build/ios \
		build-for-testing
	if [ "$1" = ios-test ]; then
		# GitHub's workflow names one simulator in $SIMULATOR, to test each on a runner of its own.
		if [ -n "$SIMULATOR" ]; then
			ios_test "$SIMULATOR" "$2"
		else
			ios_test "iPhone 17 Pro" "$2"
			ios_test "iPad Pro 13-inch (M5)" "$2"
		fi
		echo "The iOS tests passed"
		exit
	fi
	rm -rf build/app-store
	mkdir -p build/app-store
	# GitHub's workflow names one simulator in $SIMULATOR, to take each on a runner of its own.
	if [ -n "$SIMULATOR" ]; then set -- "$SIMULATOR"; else set -- "iPhone 17 Pro Max" "iPad Pro 13-inch (M5)"; fi
	for NAME in "$@"; do
		ios_test "$NAME" FolioUITests/ScreenshotTests/testScreenshots
		OUT=$(mktemp -d)
		xcrun xcresulttool export attachments --path ".build/ios/$NAME.xcresult" --output-path "$OUT"
		# The test's own shots are named "<name>_0_<UUID>.png", among the ones XCTest takes by itself.
		jq -r '.[].attachments[] | select(.suggestedHumanReadableName | test("_0_")) | .exportedFileName + " " + (.suggestedHumanReadableName | sub("_0_.*"; ""))' \
			"$OUT/manifest.json" | while read -r FILE SHOT; do mv "$OUT/$FILE" "build/app-store/$NAME - $SHOT.png"; done
		rm -rf "$OUT"
	done
	swift icon/app-store.swift
	echo "Took the screenshots, into build/app-store, and framed them for the listing, into build/app-store/listing"
	exit
fi

if [ "$1" = ios-release ]; then
	# Each build is numbered by its commit, so it's built from one.
	[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first"; exit 1; }
	xcodegen --quiet
	rm -rf build/Folio.xcarchive
	if [ -z "$ASC_KEY_ID" ]; then
		xcodebuild -quiet -project Folio.xcodeproj -scheme Folio -destination generic/platform=iOS -archivePath build/Folio.xcarchive \
			-allowProvisioningUpdates archive CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)"
		xcodebuild -quiet -exportArchive -archivePath build/Folio.xcarchive -exportOptionsPlist ExportOptions.plist -exportPath build/ios \
			-allowProvisioningUpdates
	else
		# On GitHub (testflight.yml), where Xcode has no Apple Account: signed by hand with the certificate and profile the
		# workflow installed, since automatic signing would have Xcode make a new certificate on every run, and uploaded with
		# the App Store Connect API key.
		xcodebuild -quiet -project Folio.xcodeproj -scheme Folio -destination generic/platform=iOS -archivePath build/Folio.xcarchive \
			archive CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" \
			CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" PROVISIONING_PROFILE_SPECIFIER="Folio App Store"
		cp ExportOptions.plist build/ExportOptions.plist
		plutil -replace signingStyle -string manual build/ExportOptions.plist
		plutil -insert provisioningProfiles -json '{"com.alphapms.folio": "Folio App Store"}' build/ExportOptions.plist
		xcodebuild -quiet -exportArchive -archivePath build/Folio.xcarchive -exportOptionsPlist build/ExportOptions.plist \
			-exportPath build/ios -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" \
			-authenticationKeyIssuerID "$ASC_ISSUER_ID"
	fi
	echo "Uploaded build $(git rev-list --count HEAD) to App Store Connect"
	exit
fi

if [ "$1" = ios ]; then
	DEVICE=$(xcrun simctl list devices available | grep -m1 'iPhone 17 Pro (' | grep -oE '[0-9A-F-]{36}')
	[ -n "$DEVICE" ] || { echo "No iPhone 17 Pro simulator: add one in Xcode › Window › Devices and Simulators"; exit 1; }
	xcodegen --quiet
	xcodebuild -quiet -project Folio.xcodeproj -scheme Folio -destination "id=$DEVICE" -derivedDataPath .build/ios build
	xcrun simctl bootstatus "$DEVICE" -b >/dev/null
	open -a DeviceHub 2>/dev/null || open -a Simulator
	xcrun simctl install "$DEVICE" .build/ios/Build/Products/Debug-iphonesimulator/Folio.app
	xcrun simctl launch "$DEVICE" com.alphapms.folio
	exit
fi

swift build -c release
APP=build/Folio.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Folio "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp icon/Folio.icns "$APP/Contents/Resources/"
cp -R Localization/*.lproj "$APP/Contents/Resources/"

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
