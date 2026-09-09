#!/bin/zsh
# Builds the Debug app and installs it beside the release one as "FlowPeek Debug.app".
#
# Why install it rather than run it out of the build directory: macOS keys the Accessibility grant
# to the bundle identifier, and the Debug configuration carries its own -- but System Settings can
# only show a row it can resolve to an app on disk, and a build product under DerivedData is
# somewhere Launch Services will not keep pointing at. Left there, the grant is either invisible in
# the list or thrown away the next time the path changes, which is the re-granting this split exists
# to end. Installed in ~/Applications it is an app like any other: granted once, and the release
# install keeps its own grant either way.
#
#   zsh Scripts/install_debug_app.sh
set -euo pipefail

root=${0:a:h:h}
destination_directory=${FLOWPEEK_DEBUG_DESTINATION:-$HOME/Applications}
derived=${FLOWPEEK_DEBUG_DERIVED_DATA:-$root/.build/xcode-debug}

cd "$root"
ruby Scripts/generate_xcodeproj.rb >/dev/null

xcodebuild \
  -project FlowPeek.xcodeproj \
  -scheme FlowPeek \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived" \
  build

# The name comes from the project rather than being written here twice.
app_name=$(
  xcodebuild -project FlowPeek.xcodeproj -scheme FlowPeek -configuration Debug \
    -showBuildSettings 2>/dev/null |
    awk -F' = ' '$1 ~ /^ *FLOWPEEK_APP_NAME$/ { print $2; exit }'
)
: "${app_name:?Could not read FLOWPEEK_APP_NAME from the project}"
built="$derived/Build/Products/Debug/$app_name.app"
[[ -d "$built" ]] || { print -u2 "Not built: $built"; exit 1; }

installed="$destination_directory/$app_name.app"
mkdir -p "$destination_directory"
# Replaced wholesale rather than merged, so a file dropped from the bundle does not linger.
rm -rf "$installed"
cp -R "$built" "$installed"

# So Launch Services -- and with it the Accessibility list -- can resolve the identifier to this app.
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
  -f "$installed"

identifier=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$installed/Contents/Info.plist")
print "Installed $installed ($identifier)"
print "Grant it Accessibility once: System Settings > Privacy & Security > Accessibility."
