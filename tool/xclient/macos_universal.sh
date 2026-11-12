#!/usr/bin/env bash
# Merges an arm64 and an x86_64 build of the same .app into one universal
# .app, re-signs it ad hoc, and packages the release dmg and the update zip.
#
# FlClash builds macOS for the host architecture only (Release.xcconfig and the
# setup hook skip the other slice), so CI builds each slice on its own runner
# and lipo-merges every Mach-O file here.
#
# usage: bash tool/xclient/macos_universal.sh <arm64.app> <x86_64.app> \
#          <out-dir> <brand> <version> <volume-name> <entitlements.plist>
set -euo pipefail

if [[ $# -ne 7 ]]; then
  sed -n '2,11p' "$0" >&2
  exit 64
fi

arm_app="$1"
x64_app="$2"
out_dir="$3"
brand="$4"
version="$5"
volume_name="$6"
entitlements="$7"

app_name="$(basename "$arm_app")"
if [[ "$app_name" != "$(basename "$x64_app")" ]]; then
  echo "error: $arm_app and $x64_app are not the same app" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
universal="$work/$app_name"
ditto "$arm_app" "$universal"

is_macho() {
  file -b "$1" | grep -q 'Mach-O'
}

merged=0
while IFS= read -r -d '' file; do
  is_macho "$file" || continue
  rel="${file#"$universal"/}"
  other="$x64_app/$rel"
  if [[ ! -f "$other" ]] || ! is_macho "$other"; then
    echo "error: $rel has no Mach-O counterpart in the x86_64 build" >&2
    exit 1
  fi
  have="$(lipo -archs "$file")"
  slices=()
  index=0
  for arch in $have; do
    lipo "$file" -thin "$arch" -output "$work/slice.$index" 2>/dev/null ||
      cp "$file" "$work/slice.$index"
    slices+=("$work/slice.$index")
    index=$((index + 1))
  done
  added=0
  for arch in $(lipo -archs "$other"); do
    case " $have " in
      *" $arch "*) continue ;;
    esac
    lipo "$other" -thin "$arch" -output "$work/slice.$index" 2>/dev/null ||
      cp "$other" "$work/slice.$index"
    slices+=("$work/slice.$index")
    index=$((index + 1))
    added=1
  done
  if [[ $added -eq 1 ]]; then
    lipo -create "${slices[@]}" -output "$work/merged"
    # Keep the original mode bits (the Core is executable).
    cat "$work/merged" > "$file"
    merged=$((merged + 1))
  fi
  rm -f "$work"/slice.* "$work/merged"
done < <(find "$universal" -type f -print0)

echo "merged $merged Mach-O file(s) into $app_name"

codesign --force --deep --sign - --entitlements "$entitlements" "$universal"
codesign --verify --deep --strict "$universal"

main_exe="$universal/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$universal/Contents/Info.plist")"
echo "main executable: $(lipo -archs "$main_exe")"
for arch in arm64 x86_64; do
  case " $(lipo -archs "$main_exe") " in
    *" $arch "*) ;;
    *)
      echo "error: $main_exe lacks $arch" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$out_dir"
dmg="$out_dir/$brand-macos-universal-v$version.dmg"
zip="$out_dir/$brand-macos-universal-v$version.zip"

stage="$work/dmg"
mkdir -p "$stage"
ditto "$universal" "$stage/$app_name"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "$volume_name" -srcfolder "$stage" -ov -format UDZO "$dmg"

# The in-app updater unpacks this with ditto (docs/DESIGN.md §7.2).
ditto -c -k --sequesterRsrc --keepParent "$universal" "$zip"

echo "$dmg"
echo "$zip"
