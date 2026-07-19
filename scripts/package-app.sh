#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

tag="${1:-${GITHUB_REF_NAME:-}}"
output_dir="${2:-dist}"
tag_pattern='^v([0-9]{4})\.([0-9]{2})\.([0-9]{2})-([1-9][0-9]*)$'

if [[ ! "$tag" =~ $tag_pattern ]]; then
    echo "错误：发布标签必须符合 vYYYY.MM.DD-N，当前值：${tag:-<空>}" >&2
    exit 1
fi

year="${BASH_REMATCH[1]}"
month="${BASH_REMATCH[2]}"
day="${BASH_REMATCH[3]}"
sequence="${BASH_REMATCH[4]}"
release_date="${year}.${month}.${day}"

parsed_date="$(date -j -f "%Y.%m.%d" "$release_date" "+%Y.%m.%d" 2>/dev/null || true)"
if [[ "$parsed_date" != "$release_date" ]]; then
    echo "错误：标签中的日期不是有效日历日期：$release_date" >&2
    exit 1
fi

if [[ "$output_dir" != /* ]]; then
    output_dir="$project_root/$output_dir"
fi

archive_name="Ink-${tag}.zip"
archive_path="$output_dir/$archive_name"
checksum_path="${archive_path}.sha256"
if [[ -e "$archive_path" || -e "$checksum_path" ]]; then
    echo "错误：输出文件已存在，请先移走：$archive_path" >&2
    exit 1
fi

build_root="$project_root/.build/ink-release"
for architecture in arm64 x86_64; do
    scratch_path="$build_root/$architecture"
    echo "构建 Ink：$architecture"
    swift build \
        -c release \
        --arch "$architecture" \
        --product ink \
        --scratch-path "$scratch_path"
done

arm64_bin_dir="$(swift build \
    -c release \
    --arch arm64 \
    --product ink \
    --scratch-path "$build_root/arm64" \
    --show-bin-path)"
x86_64_bin_dir="$(swift build \
    -c release \
    --arch x86_64 \
    --product ink \
    --scratch-path "$build_root/x86_64" \
    --show-bin-path)"

required_paths=(
    "$arm64_bin_dir/ink"
    "$x86_64_bin_dir/ink"
    "$project_root/Sources/ink/Resources/AppIcon.icns"
    "$project_root/Sources/InkTerminalView/Shaders.metal"
)
for path in "${required_paths[@]}"; do
    if [[ ! -e "$path" ]]; then
        echo "错误：打包资源不存在：$path" >&2
        exit 1
    fi
done

for architecture in arm64 x86_64; do
    binary_path="$arm64_bin_dir/ink"
    [[ "$architecture" == "x86_64" ]] && binary_path="$x86_64_bin_dir/ink"
    actual_architecture="$(lipo -archs "$binary_path")"
    if [[ "$actual_architecture" != "$architecture" ]]; then
        echo "错误：$binary_path 的架构应为 ${architecture}，实际为：$actual_architecture" >&2
        exit 1
    fi
done

staging_root="$(mktemp -d "${TMPDIR:-/tmp}/ink-package.XXXXXX")"
cleanup() {
    rm -rf "$staging_root"
}
trap cleanup EXIT

app_path="$staging_root/Ink.app"
contents_path="$app_path/Contents"
mkdir -p "$contents_path/MacOS" "$contents_path/Resources"

lipo -create \
    "$arm64_bin_dir/ink" \
    "$x86_64_bin_dir/ink" \
    -output "$contents_path/MacOS/ink"
chmod 755 "$contents_path/MacOS/ink"
install -m 644 "$project_root/Sources/ink/Resources/AppIcon.icns" \
    "$contents_path/Resources/AppIcon.icns"
install -m 644 "$project_root/Sources/InkTerminalView/Shaders.metal" \
    "$contents_path/Resources/Shaders.metal"

short_version="${year}.$((10#$month)).$((10#$day))"
bundle_version="${year}${month}${day}.${sequence}"
cat > "$contents_path/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>Ink</string>
    <key>CFBundleExecutable</key>
    <string>ink</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.cheneychou.ink</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Ink</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$short_version</string>
    <key>CFBundleVersion</key>
    <string>$bundle_version</string>
    <key>InkReleaseTag</key>
    <string>$tag</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

plutil -lint "$contents_path/Info.plist"

signing_identity="${CODE_SIGN_IDENTITY:--}"
signing_args=(--force --deep --sign "$signing_identity")
if [[ "$signing_identity" != "-" ]]; then
    signing_args+=(--options runtime --timestamp)
fi
codesign "${signing_args[@]}" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

mkdir -p "$output_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
(
    cd "$output_dir"
    shasum -a 256 "$archive_name" > "${archive_name}.sha256"
)

echo "已生成：$archive_path"
echo "校验值：$checksum_path"
