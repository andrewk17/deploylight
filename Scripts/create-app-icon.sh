#!/usr/bin/env bash
# Draws the app icon (a prompt whose cursor is a green light, on a light tile) and
# writes Resources/AppIcon.icns, app-icon.png for the README and the website's icon.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")"/.. && pwd)
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT
ICONSET_DIR="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

cat > "$WORK_DIR/draw_icon.swift" <<'SWIFT'
import AppKit

// Draws at exactly 1024 x 1024 pixels, whatever display the Mac has.
let side = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: Int, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// macOS icon grid: an 824pt tile centered on the 1024pt canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// A soft shadow keeps the light tile visible on a white window.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowBlurRadius = 32
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.set()
NSColor.white.setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(starting: .white, ending: color(0xe6e6eb))!.draw(in: tilePath, angle: -90)
let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 1, dy: 1), xRadius: 184, yRadius: 184)
edge.lineWidth = 2
NSColor.black.withAlphaComponent(0.12).setStroke()
edge.stroke()

// The prompt.
let prompt = NSBezierPath()
prompt.move(to: NSPoint(x: 292, y: 620))
prompt.line(to: NSPoint(x: 410, y: 512))
prompt.line(to: NSPoint(x: 292, y: 404))
prompt.lineWidth = 70
prompt.lineCapStyle = .round
prompt.lineJoinStyle = .round
color(0x1d1d1f).setStroke()
prompt.stroke()

// The light, where the cursor would be.
color(0x28c14c).setFill()
NSBezierPath(ovalIn: NSRect(x: 634 - 140, y: 512 - 140, width: 280, height: 280)).fill()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

swiftc -o "$WORK_DIR/draw_icon" "$WORK_DIR/draw_icon.swift" -framework AppKit
BASE="$WORK_DIR/icon_1024.png"
"$WORK_DIR/draw_icon" "$BASE"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$BASE" --out "$ICONSET_DIR/icon_${size}x${size}.png" > /dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$BASE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" > /dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$ROOT/Resources/AppIcon.icns"
sips -z 512 512 "$BASE" --out "$ROOT/app-icon.png" > /dev/null

# The website shows the tile with a little room for its shadow.
SITE_ICON="$ROOT/docs/img/deploylight-icon.png"
sips --cropOffset 76 76 -c 872 872 "$BASE" --out "$SITE_ICON" > /dev/null
sips -z 160 160 "$SITE_ICON" > /dev/null

echo "Wrote $ROOT/Resources/AppIcon.icns, $ROOT/app-icon.png and $SITE_ICON"
