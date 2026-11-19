#!/bin/bash
# Renders the pictures for the README and the website into docs/img.
#
# The menu and the menu bar item are drawn by the app's own row code with example
# deployments (MarketingRenderTests), and the Accounts tab by OffscreenRenderTests.
# Chrome then composes the README picture and the link preview from those pieces
# (Scripts/site-art).
#
# Usage: ./Scripts/render-site-art.sh      (macOS, needs Google Chrome)

set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
ART="$PWD/build/site-art"
IMG="$PWD/docs/img"

rm -rf "$ART"
mkdir -p "$ART"

# Row glyphs are cached per process, so each appearance gets its own run.
for appearance in light dark; do
    DEPLOYLIGHT_MARKETING_DIR="$ART" DEPLOYLIGHT_MARKETING_APPEARANCE="$appearance" \
        swift test --filter MarketingRenderTests
    cp "$ART/menu-$appearance.png" "$IMG/deploylight-menu-$appearance.png"
    for state in building ready failed; do
        cp "$ART/status-$state-$appearance.png" "$IMG/"
    done
done

# The Accounts tab renders at 540x740 pt; keep the 1385 px that hold content.
DEPLOYLIGHT_SCREENSHOT_DIR="$ART" swift test --filter OffscreenRenderTests
for appearance in light dark; do
    sips --cropOffset 2 0 -c 1385 1080 "$ART/accounts-$appearance.png" \
        --out "$IMG/deploylight-accounts-$appearance.png" >/dev/null
done

# shoot <output.png> <page in Scripts/site-art> <width> <height> <scale>
# The pages draw their picture 20 px in from the top left. Headless Chrome fills the last
# rows of a capture with a copy of the top, and sips crops from the centre when the offset
# is 0 0, so this captures a larger window and crops the picture out of it.
shoot() {
    local raw="$ART/raw-$(basename "$1")"
    "$CHROME" --headless=new --hide-scrollbars --no-first-run --no-default-browser-check \
        --user-data-dir="$ART/chrome" --force-device-scale-factor="$5" \
        --window-size="$(( $3 + 200 )),$(( $4 + 300 ))" --default-background-color=00000000 \
        --screenshot="$raw" "file://$PWD/Scripts/site-art/$2" >/dev/null 2>&1
    sips --cropOffset "$(( 20 * $5 ))" "$(( 20 * $5 ))" -c "$(( $4 * $5 ))" "$(( $3 * $5 ))" \
        "$raw" --out "$1" >/dev/null
}

shoot "$IMG/deploylight-menu-bar-light.png" "tile.html?a=light" 560 500 2
shoot "$IMG/deploylight-menu-bar-dark.png" "tile.html?a=dark" 560 500 2
shoot "$IMG/deploylight-share.png" "share.html" 1200 630 1
# Uploaded by hand under the repository's Settings -> Social preview.
shoot "$ART/github-social-preview.png" "share.html?w=1280&h=640" 1280 640 1

echo "Wrote the pictures to docs/img, and build/site-art/github-social-preview.png."
