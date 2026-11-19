import AppKit
import XCTest
@testable import Deploylight

/// Draws the menu and the menu bar item with example deployments, as transparent PNGs
/// for the README and the site. Rows, icons and badges come from the app's own code;
/// only the menu's frame is laid out here.
///
/// `Scripts/render-site-art.sh` runs this once per appearance, since the row glyphs are cached per process:
/// `DEPLOYLIGHT_MARKETING_DIR=out DEPLOYLIGHT_MARKETING_APPEARANCE=dark swift test --filter MarketingRenderTests`
final class MarketingRenderTests: XCTestCase {
    @MainActor
    func testRenderMenuArt() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["DEPLOYLIGHT_MARKETING_DIR"], !path.isEmpty else {
            throw XCTSkip("Set DEPLOYLIGHT_MARKETING_DIR to render the menu art.")
        }
        let dark = environment["DEPLOYLIGHT_MARKETING_APPEARANCE"] == "dark"
        let suffix = dark ? "dark" : "light"
        let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)

        let now = try XCTUnwrap(Calendar.current.date(bySettingHour: 11, minute: 5, second: 12, of: Date()))
        func example(_ id: Int, _ provider: Deployment.Provider, _ project: String, _ branch: String,
                     _ target: Deployment.Target, _ state: Deployment.State, ago: TimeInterval, took: TimeInterval?) -> Deployment {
            let start = now.addingTimeInterval(-ago)
            return Deployment(id: String(id), provider: provider, projectName: project, state: state, target: target,
                              branch: branch, commitMessage: nil, createdAt: start, buildStartedAt: start,
                              finishedAt: took.map { start.addingTimeInterval($0) }, link: nil)
        }
        let deployments = [
            example(1, .vercel, "web", "checkout-v2", .preview, .building, ago: 42, took: nil),
            example(2, .github, "places-api", "main", .production, .ready, ago: 247, took: 96),
            example(3, .cloudflare, "edge-cache", "fix-cors", .preview, .error, ago: 792, took: 48),
            example(4, .vercel, "web", "main", .production, .ready, ago: 1692, took: 128),
            example(5, .cloudflare, "edge-cache", "main", .production, .ready, ago: 3072, took: 72),
        ]

        let rowFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
        let formatter = MenuRowFormatter(preferences: .default, showsProvider: true, font: rowFont, now: now)

        var items: [MenuArt.Item] = [.header("Recent")]
        items += deployments.map {
            .row(StatusIcon.image(for: $0.state), formatter.title(for: $0, includeProject: true).attributed, submenu: false)
        }
        items += [.separator, .header("Projects")]
        items += ProjectSummary.summaries(from: deployments).map {
            .row(StatusIcon.image(for: $0.headline.state), formatter.title(for: $0).attributed, submenu: true)
        }
        items += [.separator, .disabled("Last updated: \(Formatting.time(now))"), .separator, .action("Refresh Now", key: "R")]
        items += Deployment.Provider.allCases.map { .action("Open \($0.rawValue) Dashboard", key: nil) }
        items += [.action("Preferences…", key: ","), .separator, .action("Quit Deploylight", key: "Q")]

        try capture(MenuArt.menu(items), appearance: appearance, at: directory.appendingPathComponent("menu-\(suffix).png"))

        let preferences = Preferences.default
        for (name, state, deployment) in [("building", Deployment.State.building, deployments[0]),
                                           ("ready", .ready, deployments[1]),
                                           ("failed", .error, deployments[2])] {
            let title = StatusTitle.text(projectName: deployment.projectName, state: state, elapsed: deployment.elapsed(now: now),
                                         style: preferences.menuBarStyle, timeFormat: preferences.timeFormat)
            try capture(MenuArt.statusItem(state: state, title: title), appearance: appearance,
                        at: directory.appendingPathComponent("status-\(name)-\(suffix).png"))
        }

        let day = DateFormatter()
        day.dateFormat = "EEE MMM d"
        let clock = MenuArt.label("\(day.string(from: now))  \(Formatting.time(now))",
                                  font: .monospacedDigitSystemFont(ofSize: 13, weight: .medium), color: .labelColor)
        try capture(clock, appearance: appearance, at: directory.appendingPathComponent("clock-\(suffix).png"))
    }

    @MainActor
    private func capture(_ view: NSView, appearance: NSAppearance.Name, at url: URL) throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: view.frame.size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        if let data = bitmap.bitmapData {
            memset(data, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        print("rendered \(url.lastPathComponent) \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) px, \(Int(view.bounds.width))x\(Int(view.bounds.height)) pt")
    }
}

@MainActor
private enum MenuArt {
    enum Item {
        case header(String)
        case row(NSImage?, NSAttributedString, submenu: Bool)
        case separator
        case disabled(String)
        case action(String, key: String?)
    }

    // Measured from a capture of the real menu: 22 pt rows, 11 pt separators, text 14 pt in.
    static let rowHeight: CGFloat = 22
    static let separatorHeight: CGFloat = 11
    static let inset: CGFloat = 14
    static let padding: CGFloat = 5
    static let iconBox: CGFloat = 16
    static let iconGap: CGFloat = 6
    static let trailingGap: CGFloat = 28

    private final class Canvas: NSView {
        override var isFlipped: Bool { true }
    }

    private final class Rule: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            NSBezierPath(rect: bounds).fill()
        }
    }

    private struct Line {
        var icon: NSImage?
        var label: NSTextField?
        var trailing: NSView?
        var height: CGFloat
    }

    static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.sizeToFit()
        return field
    }

    static func menu(_ items: [Item]) -> NSView {
        let font = NSFont.menuFont(ofSize: 0)
        let lines: [Line] = items.map { item in
            switch item {
            case let .header(title):
                return Line(label: label(title, font: .systemFont(ofSize: 11, weight: .semibold), color: .secondaryLabelColor),
                            height: rowHeight)
            case let .row(icon, title, submenu):
                let colored = NSMutableAttributedString(attributedString: title)
                colored.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: colored.length))
                let field = NSTextField(labelWithAttributedString: colored)
                field.sizeToFit()
                return Line(icon: icon, label: field, trailing: submenu ? chevron() : nil, height: rowHeight)
            case .separator:
                return Line(height: separatorHeight)
            case let .disabled(title):
                return Line(label: label(title, font: font, color: .disabledControlTextColor), height: rowHeight)
            case let .action(title, key):
                return Line(label: label(title, font: font, color: .labelColor), trailing: key.map { shortcut($0, font: font) },
                            height: rowHeight)
            }
        }

        let widest = lines.map { line -> CGFloat in
            var width = inset * 2
            if line.icon != nil { width += iconBox + iconGap }
            width += line.label?.frame.width ?? 0
            if let trailing = line.trailing { width += trailingGap + trailing.frame.width }
            return width
        }.max() ?? 0
        let width = ceil(widest)

        let canvas = Canvas()
        var y = padding
        for line in lines {
            var x = inset
            if let icon = line.icon {
                let view = NSImageView(frame: CGRect(x: x, y: y, width: iconBox, height: line.height))
                view.image = icon
                view.imageScaling = .scaleNone
                canvas.addSubview(view)
                x += iconBox + iconGap
            }
            if let label = line.label {
                label.frame.origin = CGPoint(x: x, y: y + ((line.height - label.frame.height) / 2).rounded())
                canvas.addSubview(label)
            } else {
                canvas.addSubview(Rule(frame: CGRect(x: inset, y: y + ((line.height - 1) / 2).rounded(), width: width - inset * 2, height: 1)))
            }
            if let trailing = line.trailing {
                trailing.frame.origin = CGPoint(x: width - inset - trailing.frame.width,
                                                y: y + ((line.height - trailing.frame.height) / 2).rounded())
                canvas.addSubview(trailing)
            }
            y += line.height
        }
        canvas.frame = CGRect(x: 0, y: 0, width: width, height: y + padding)
        return canvas
    }

    static func statusItem(state: Deployment.State, title: String) -> NSView {
        let height: CGFloat = 22
        let canvas = Canvas()
        let image = StatusIcon.image(for: state) ?? NSImage()
        let icon = NSImageView(frame: CGRect(x: 0, y: 0, width: ceil(image.size.width), height: height))
        icon.image = image
        icon.imageScaling = .scaleNone
        canvas.addSubview(icon)
        var width = icon.frame.maxX
        if !title.isEmpty {
            let text = label(title, font: .monospacedDigitSystemFont(ofSize: 13, weight: .medium), color: .labelColor)
            text.frame.origin = CGPoint(x: width + 4, y: ((height - text.frame.height) / 2).rounded())
            canvas.addSubview(text)
            width = text.frame.maxX
        }
        canvas.frame = CGRect(x: 0, y: 0, width: ceil(width), height: height)
        return canvas
    }

    private static func chevron() -> NSView {
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        let view = NSImageView(frame: CGRect(origin: .zero, size: CGSize(width: ceil(image.size.width), height: ceil(image.size.height))))
        view.image = image
        view.imageScaling = .scaleNone
        view.contentTintColor = .secondaryLabelColor
        return view
    }

    private static func shortcut(_ key: String, font: NSFont) -> NSView {
        let text = NSMutableAttributedString(string: "⌘\(key)", attributes: [.font: font, .foregroundColor: NSColor.disabledControlTextColor])
        text.addAttribute(.kern, value: 3, range: NSRange(location: 0, length: 1))
        let field = NSTextField(labelWithAttributedString: text)
        field.sizeToFit()
        return field
    }
}
