// LinkLoop: menu bar image slideshow widget. Build: ./build.sh  (or: swiftc -O LinkLoop.swift -o LinkLoop)
import AppKit
import UniformTypeIdentifiers
import ServiceManagement

// MARK: - Model / Store

struct Item: Codable {
    var link: String
    var file: String
    var index: Int?   // position inside a multi-photo X post (1-based)
    var total: Int?
    var small: Bool?  // true once the cached file has been through Resolver.compress
}

final class Store {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LinkLoop", isDirectory: true)
    var cache: URL { dir.appendingPathComponent("cache", isDirectory: true) }
    var json: URL { dir.appendingPathComponent("links.json") }
    private(set) var items: [Item] = []

    init() {
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: json), let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
        pruneMissing()
    }

    /// A cache file deleted by hand means the user removed that image: drop its entry too.
    @discardableResult
    func pruneMissing() -> Bool {
        let kept = items.filter { FileManager.default.fileExists(atPath: fileURL($0).path) }
        guard kept.count != items.count else { return false }
        items = kept
        save()
        return true
    }

    func contains(_ link: String) -> Bool { items.contains { $0.link == link } }
    func fileURL(_ item: Item) -> URL { cache.appendingPathComponent(item.file) }

    func add(link: String, data: Data, ext: String, index: Int? = nil, total: Int? = nil) throws {
        let item = Item(link: link, file: UUID().uuidString + "." + ext, index: index, total: total, small: true)
        try data.write(to: fileURL(item), options: .atomic)
        items.append(item)
        save()
    }

    func remove(at i: Int) {
        guard items.indices.contains(i) else { return }
        try? FileManager.default.removeItem(at: fileURL(items[i]))
        items.remove(at: i)
        save()
    }

    /// Swap an old cached file for its compressed version (nil = keep it, just mark it done).
    func replace(file: String, with data: Data?) {
        guard let i = items.firstIndex(where: { $0.file == file }) else { return }  // removed meanwhile
        if let data {
            let name = UUID().uuidString + ".jpg"
            guard (try? data.write(to: cache.appendingPathComponent(name), options: .atomic)) != nil else { return }
            try? FileManager.default.removeItem(at: fileURL(items[i]))
            items[i].file = name
        }
        items[i].small = true
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? enc.encode(items).write(to: json, options: .atomic)
    }
}

// MARK: - Resolver (link -> image URLs -> bytes). Patch here when sites change.

enum LinkError: LocalizedError {
    case badURL, network(String), http(Int), noImage, notImage, instagram

    var errorDescription: String? {
        switch self {
        case .badURL: return "That doesn't look like a web link. Copy a link that starts with http:// or https://."
        case .network(let m): return "Couldn't reach the site: \(m)"
        case .http(let c): return "The site refused the request (HTTP \(c)). The post may be private or deleted."
        case .noImage: return "No image found at that link. It may be a text-only or video post."
        case .notImage: return "The link pointed to something that isn't a picture LinkLoop can read."
        case .instagram: return "Instagram blocked this one, try saving the image and using Add image file instead."
        }
    }
}

/// One image to download. `link` is what gets stored (and de-duplicated on).
struct Candidate {
    var link: String
    var image: URL
    var fallback: URL? = nil
    var ua: String = Resolver.safariUA
    var index: Int? = nil
    var total: Int? = nil
}

enum Resolver {
    static let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    static let discordUA = "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)"
    static let facebookUA = "facebookexternalhit/1.1"

    static func parse(_ s: String) -> URL? {
        guard let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func resolve(_ url: URL) async throws -> [Candidate] {
        let host = url.host?.lowercased() ?? ""
        let link = url.absoluteString
        if ["jpg", "jpeg", "png", "webp"].contains(url.pathExtension.lowercased())
            || host.contains("pinimg.com") || host == "pbs.twimg.com" {
            return [Candidate(link: link, image: url)]
        }
        if host == "x.com" || host.hasSuffix(".x.com") || host.hasSuffix("twitter.com") {
            return try await resolveX(url)
        }
        if host == "pin.it" || host.contains("pinterest.") {
            let og = try await ogImage(url, ua: safariUA)
            return [Candidate(link: link, image: pinterestOriginal(og) ?? og, fallback: og)]
        }
        if host.hasSuffix("instagram.com") {
            do { return [Candidate(link: link, image: try await ogImage(url, ua: facebookUA), ua: facebookUA)] }
            catch { throw LinkError.instagram }
        }
        return [Candidate(link: link, image: try await ogImage(url, ua: safariUA))]
    }

    /// /736x/ab/cd/x.jpg -> /originals/ab/cd/x.jpg
    static func pinterestOriginal(_ u: URL) -> URL? {
        guard var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return nil }
        var parts = c.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1, parts[1].range(of: #"^\d+x\d*$"#, options: .regularExpression) != nil else { return nil }
        parts[1] = "originals"
        c.path = parts.joined(separator: "/")
        return c.url
    }

    /// X: every photo via fxtwitter's JSON API, each stored as .../status/ID/photo/N.
    static func resolveX(_ url: URL) async throws -> [Candidate] {
        let p = url.pathComponents  // ["/", user, "status", id, "photo", "2"]
        guard let s = p.firstIndex(of: "status"), s + 1 < p.count, Int(p[s + 1]) != nil else { throw LinkError.noImage }
        let id = p[s + 1]
        let user = s >= 2 && p[s - 1] != "web" ? p[s - 1] : "i"
        let wanted = s + 3 < p.count && p[s + 2] == "photo" ? Int(p[s + 3]) : nil

        var photos: [URL]
        do {
            let (data, _) = try await fetch(URL(string: "https://api.fxtwitter.com/\(user)/status/\(id)")!, ua: discordUA)
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let list = ((root?["tweet"] as? [String: Any])?["media"] as? [String: Any])?["photos"] as? [[String: Any]] ?? []
            photos = list.compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
        } catch {
            // API down: fall back to the fxtwitter embed page (first photo only).
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            c.host = "fxtwitter.com"
            let og = try await ogImage(c.url!, ua: discordUA)
            return [Candidate(link: url.absoluteString, image: og, ua: discordUA)]
        }
        guard !photos.isEmpty else { throw LinkError.noImage }
        let total = photos.count
        let numbered = photos.enumerated().map { (n: $0.offset + 1, url: $0.element) }
        let chosen = wanted.map { w in numbered.filter { $0.n == w } } ?? numbered
        guard !chosen.isEmpty else { throw LinkError.noImage }
        return chosen.map {
            Candidate(link: "https://x.com/\(user)/status/\(id)/photo/\($0.n)", image: $0.url,
                      index: total > 1 ? $0.n : nil, total: total > 1 ? total : nil)
        }
    }

    static func fetch(_ url: URL, ua: String) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw LinkError.network(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw LinkError.network("no response") }
        guard http.statusCode == 200 else { throw LinkError.http(http.statusCode) }
        return (data, http)
    }

    static func ogImage(_ url: URL, ua: String) async throws -> URL {
        let (data, resp) = try await fetch(url, ua: ua)
        let html = String(decoding: data, as: UTF8.self)
        guard let found = findOGImage(html, base: resp.url ?? url) else { throw LinkError.noImage }
        return found
    }

    static func findOGImage(_ html: String, base: URL) -> URL? {
        for key in ["og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src"] {
            let k = NSRegularExpression.escapedPattern(for: key)
            let a = #"\s*=\s*["']"#
            let patterns = [
                #"<meta\b[^>]*?\b(?:property|name)"# + a + k + #"["'][^>]*?\bcontent"# + a + #"([^"']+)["']"#,
                #"<meta\b[^>]*?\bcontent"# + a + #"([^"']+)["'][^>]*?\b(?:property|name)"# + a + k + #"["']"#,
            ]
            for pat in patterns {
                guard let re = try? NSRegularExpression(pattern: pat, options: .caseInsensitive),
                      let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                      let r = Range(m.range(at: 1), in: html) else { continue }
                let raw = html[r].replacingOccurrences(of: "&amp;", with: "&")
                if let u = URL(string: raw, relativeTo: base)?.absoluteURL { return u }
            }
        }
        return nil
    }

    static func download(_ c: Candidate) async throws -> (Data, String) {
        do { return try await downloadImage(c.image, ua: c.ua) }
        catch { if let f = c.fallback, f != c.image { return try await downloadImage(f, ua: c.ua) }; throw error }
    }

    static func downloadImage(_ url: URL, ua: String) async throws -> (Data, String) {
        let (data, resp) = try await fetch(url, ua: ua)
        guard NSImage(data: data) != nil else { throw LinkError.notImage }
        if let small = compress(data) { return (small, "jpg") }
        return (data, imageExtension(data, mime: resp.mimeType))
    }

    /// Longest side capped at 1400px (widget tops out at 1080px on Retina), JPEG quality 0.7.
    /// Returns nil if that wouldn't make the file smaller.
    /// shortcut: JPEG drops transparency; the widget's dark background hides that.
    static func compress(_ data: Data, maxSide: Int = 1400, quality: Double = 0.7) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // respect EXIF rotation
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dst), out.length < data.count else { return nil }
        return out as Data
    }

    static func imageExtension(_ d: Data, mime: String?) -> String {
        let b = [UInt8](d.prefix(12))
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.count >= 12, b.starts(with: Array("RIFF".utf8)), Array(b[8..<12]) == Array("WEBP".utf8) { return "webp" }
        if b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8) { return "heic" }
        if let m = mime, let t = UTType(mimeType: m), let e = t.preferredFilenameExtension { return e }
        return "img"
    }
}

// MARK: - Widget

final class WidgetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

final class WidgetView: NSView {
    weak var app: AppDelegate?
    let photo = NSView()  // plain layer: NSImageView can't aspect-fill
    let placeholder = NSTextField(wrappingLabelWithString: "Copy a link, then use the menu bar icon → Add link from clipboard")
    let badge = NSTextField(labelWithString: "")
    private var downPoint: NSPoint?
    private var dragged = false
    private var resizing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        photo.wantsLayer = true
        photo.frame = bounds
        photo.autoresizingMask = [.width, .height]
        addSubview(photo)

        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)

        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.drawsBackground = true
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = true
        addSubview(badge)

        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.widthAnchor.constraint(equalTo: widthAnchor, constant: -40),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ image: NSImage?, badgeText: String?, fill: Bool, animated: Bool) {
        guard let layer = photo.layer else { return }
        if animated {
            let t = CATransition()
            t.type = .fade
            t.duration = 0.6
            layer.add(t, forKey: "fade")
        }
        layer.contentsGravity = fill ? .resizeAspectFill : .resizeAspect
        layer.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        badge.stringValue = badgeText.map { " \($0) " } ?? ""
        badge.isHidden = badgeText == nil
    }

    // Swallow clicks from subviews so the whole widget drags, clicks and resizes as one.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        downPoint = e.locationInWindow
        dragged = false
        resizing = p.x > bounds.width - 16 && p.y < 16  // bottom-right corner grip
    }

    override func mouseDragged(with e: NSEvent) {
        guard let w = window, let start = downPoint else { return }
        if resizing {
            var f = w.frame
            let top = f.maxY
            f.size.width = max(w.minSize.width, f.width + e.deltaX)
            f.size.height = max(w.minSize.height, f.height + e.deltaY)
            f.origin.y = top - f.height
            w.setFrame(f, display: true)
            return
        }
        if !dragged, hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) > 3 {
            dragged = true
            w.performDrag(with: e)
        }
    }

    override func mouseUp(with e: NSEvent) {
        if !dragged && !resizing && e.clickCount == 1 { app?.openCurrentLink() }
        downPoint = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? { app?.contextMenu() }

    // Drag-and-drop: image files or links.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            app?.addFiles(files)
            return true
        }
        if let url = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first {
            app?.addLink(url.absoluteString)
            return true
        }
        if let s = pb.string(forType: .string) {
            app?.addLink(s)
            return true
        }
        return false
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let showItem = NSMenuItem(title: "Show widget", action: #selector(toggleWidget), keyEquivalent: "")
    let shuffleItem = NSMenuItem(title: "Shuffle", action: #selector(toggleShuffle), keyEquivalent: "")
    let intervalMenu = NSMenu()
    var panel: WidgetPanel!
    var widget: WidgetView!
    var current = 0
    var timer: Timer?
    var busy = 0
    var note: String?
    let intervals = [60, 180, 300, 600]  // seconds
    let loginItem = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")

    var interval: Double {
        get {
            let saved = UserDefaults.standard.object(forKey: "interval") as? Double ?? 60
            return intervals.contains(Int(saved)) ? saved : 60  // older builds saved 3–60s values
        }
        set { UserDefaults.standard.set(newValue, forKey: "interval") }
    }
    var shuffle: Bool {
        get { UserDefaults.standard.bool(forKey: "shuffle") }
        set { UserDefaults.standard.set(newValue, forKey: "shuffle") }
    }
    var fill: Bool {
        get { UserDefaults.standard.object(forKey: "fill") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "fill") }
    }
    var onDesktop: Bool {
        get { UserDefaults.standard.bool(forKey: "onDesktop") }
        set { UserDefaults.standard.set(newValue, forKey: "onDesktop") }
    }
    // Apple-widget-like presets; the corner grip still allows any size.
    let sizes: [(name: String, size: NSSize)] = [
        ("Small", NSSize(width: 170, height: 170)),
        ("Medium", NSSize(width: 260, height: 260)),
        ("Large", NSSize(width: 360, height: 360)),
        ("Extra large", NSSize(width: 540, height: 540)),
    ]

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        buildWidget()
        display(animated: false)
        restartTimer()
        compressOldImages()
        // Turn launch-at-login on once by default; after that the menu toggle decides.
        if !UserDefaults.standard.bool(forKey: "loginDefaultApplied"), Bundle.main.bundlePath.hasSuffix(".app") {
            UserDefaults.standard.set(true, forKey: "loginDefaultApplied")
            try? SMAppService.mainApp.register()
        }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at login"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can also add LinkLoop in System Settings → General → Login Items."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// One-time background pass over images saved before compression existed.
    func compressOldImages() {
        let todo = store.items.filter { $0.small != true }.map { (file: $0.file, url: store.fileURL($0)) }
        guard !todo.isEmpty else { return }
        Task.detached(priority: .background) {
            for t in todo {
                let small = (try? Data(contentsOf: t.url)).flatMap { Resolver.compress($0) }
                await MainActor.run { self.store.replace(file: t.file, with: small) }
            }
        }
    }

    // MARK: Menu

    func buildMenu() {
        if let img = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "LinkLoop") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "🖼"
        }
        statusLine.isEnabled = false
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let paste = item("Add link from clipboard", #selector(addFromClipboard), "v")
        paste.keyEquivalentModifierMask = []
        menu.addItem(paste)
        menu.addItem(item("Add link…", #selector(addLinkPrompt)))
        menu.addItem(item("Add image file…", #selector(addFilePrompt)))
        menu.addItem(.separator())
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(widgetMenuItem)
        menu.addItem(item("Next image", #selector(nextImage)))
        menu.addItem(item("Remove current image", #selector(removeCurrent)))
        shuffleItem.target = self
        menu.addItem(shuffleItem)
        for s in intervals {
            let i = item("\(s / 60) min", #selector(setInterval(_:)))
            i.tag = s
            intervalMenu.addItem(i)
        }
        let intervalItem = NSMenuItem(title: "Interval", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)
        menu.addItem(.separator())
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(item("Open data folder", #selector(openFolder)))
        menu.addItem(item("Quit LinkLoop", #selector(quit), "q"))
        statusItem.menu = menu
        updateStatus()
    }

    func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    func contextMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("Next image", #selector(nextImage)))
        m.addItem(item("Remove current image", #selector(removeCurrent)))
        m.addItem(item("Hide widget", #selector(toggleWidget)))
        let w = NSMenuItem(title: "Widget", action: nil, keyEquivalent: "")
        w.submenu = widgetMenu()
        m.addItem(w)
        return m
    }

    let widgetMenuItem = NSMenuItem(title: "Widget", action: nil, keyEquivalent: "")

    /// Built fresh each time so check marks are current.
    func widgetMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let f = item("Zoom to fill", #selector(toggleFill))
        f.state = fill ? .on : .off
        m.addItem(f)
        m.addItem(.separator())
        for (i, s) in sizes.enumerated() {
            let it = item("\(s.name)  \(Int(s.size.width))×\(Int(s.size.height))", #selector(setSize(_:)))
            it.tag = i
            it.state = panel.frame.size == s.size ? .on : .off
            m.addItem(it)
        }
        m.addItem(.separator())
        let float = item("Float above windows", #selector(setPlacement(_:)))
        float.state = onDesktop ? .off : .on
        let desk = item("Keep on desktop", #selector(setPlacement(_:)))
        desk.tag = 1
        desk.state = onDesktop ? .on : .off
        m.addItem(float)
        m.addItem(desk)
        return m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        widgetMenuItem.submenu = widgetMenu()
        showItem.state = panel.isVisible ? .on : .off
        shuffleItem.state = shuffle ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for i in intervalMenu.items { i.state = Double(i.tag) == interval ? .on : .off }
        updateStatus()
    }

    func updateStatus() {
        let n = store.items.count
        statusLine.title = busy > 0 ? "Adding…" : note ?? "\(n) image\(n == 1 ? "" : "s")"
        statusItem.button?.toolTip = "LinkLoop: " + statusLine.title
    }

    // MARK: Widget

    func buildWidget() {
        panel = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 320),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable],
                            backing: .buffered, defer: false)
        applyPlacement()
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = NSSize(width: 120, height: 120)
        widget = WidgetView(frame: panel.contentLayoutRect)
        widget.app = self
        panel.contentView = widget
        if !panel.setFrameUsingName("LinkLoopWidget"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 340, y: screen.maxY - 340))
        }
        panel.setFrameAutosaveName("LinkLoopWidget")
        panel.orderFrontRegardless()
    }

    func display(animated: Bool = true) {
        if store.pruneMissing() { updateStatus() }
        let items = store.items
        widget.placeholder.isHidden = !items.isEmpty
        guard !items.isEmpty else { widget.show(nil, badgeText: nil, fill: fill, animated: false); return }
        current = min(max(current, 0), items.count - 1)
        let it = items[current]
        let badge = it.total.flatMap { t in it.index.map { "\($0)/\(t)" } }
        widget.show(NSImage(contentsOf: store.fileURL(it)), badgeText: badge, fill: fill, animated: animated)
    }

    /// Desktop mode sits just above the desktop icons, behind every app window, like Apple's desktop widgets.
    func applyPlacement() {
        if onDesktop {
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        } else {
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        if panel.isVisible { panel.orderFrontRegardless() }
    }

    @objc func setPlacement(_ sender: NSMenuItem) {
        onDesktop = sender.tag == 1
        applyPlacement()
    }

    @objc func toggleFill() {
        fill.toggle()
        display(animated: false)
    }

    @objc func setSize(_ sender: NSMenuItem) {
        var f = panel.frame
        let top = f.maxY  // keep the top-left corner where it is
        f.size = sizes[sender.tag].size
        f.origin.y = top - f.height
        panel.setFrame(f, display: true, animate: true)
    }

    func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        RunLoop.main.add(t, forMode: .common)  // keep looping while a menu is open
        timer = t
    }

    func advance() {
        let n = store.items.count
        guard n > 1 else { return }
        if shuffle {
            var next = current
            while next == current { next = Int.random(in: 0..<n) }
            current = next
        } else {
            current = (current + 1) % n
        }
        display()
    }

    func openCurrentLink() {
        guard store.items.indices.contains(current),
              let url = URL(string: store.items[current].link), url.scheme?.hasPrefix("http") == true else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Actions

    @objc func addFromClipboard() {
        addLink(NSPasteboard.general.string(forType: .string) ?? "")
    }

    @objc func addLinkPrompt() {
        let alert = NSAlert()
        alert.messageText = "Add link"
        alert.informativeText = "Paste a Pinterest, X, Instagram or image link."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        if let s = NSPasteboard.general.string(forType: .string), Resolver.parse(s) != nil { field.stringValue = s }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { addLink(field.stringValue) }
    }

    @objc func addFilePrompt() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.image]
        open.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        if open.runModal() == .OK { addFiles(open.urls) }
    }

    func addLink(_ text: String) {
        guard let url = Resolver.parse(text) else { return showError(LinkError.badURL) }
        if store.contains(url.absoluteString) { return setNote("Already added") }
        busy += 1
        note = nil
        updateStatus()
        Task {
            defer { busy -= 1; updateStatus() }
            do {
                let found = try await Resolver.resolve(url)
                let fresh = found.filter { !store.contains($0.link) }
                guard !fresh.isEmpty else { return setNote("Already added") }
                // Download everything first so a failure adds nothing.
                var got: [(Candidate, Data, String)] = []
                for c in fresh {
                    let (data, ext) = try await Resolver.download(c)
                    got.append((c, data, ext))
                }
                for (c, data, ext) in got where !store.contains(c.link) {
                    try store.add(link: c.link, data: data, ext: ext, index: c.index, total: c.total)
                }
                if fresh.count < found.count { setNote("Added \(fresh.count), \(found.count - fresh.count) already saved") }
                showNewest(got.count)
            } catch {
                showError(error)
            }
        }
    }

    func addFiles(_ urls: [URL]) {
        var added = 0
        for url in urls {
            let link = url.absoluteString
            if store.contains(link) { setNote("Already added"); continue }
            guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else {
                showError(LinkError.notImage)
                continue
            }
            do {
                if let small = Resolver.compress(data) {
                    try store.add(link: link, data: small, ext: "jpg")
                } else {
                    try store.add(link: link, data: data, ext: Resolver.imageExtension(data, mime: nil))
                }
                added += 1
            } catch { showError(error) }
        }
        showNewest(added)
    }

    func showNewest(_ added: Int) {
        guard added > 0 else { return }
        current = store.items.count - added
        display()
        restartTimer()
        updateStatus()
    }

    func setNote(_ s: String) {
        note = s
        updateStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.note == s else { return }
                self.note = nil
                self.updateStatus()
            }
        }
    }

    func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't add that link"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func toggleWidget() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc func nextImage() {
        advance()
        restartTimer()
    }

    @objc func removeCurrent() {
        guard store.items.indices.contains(current) else { return }
        store.remove(at: current)
        display()
        updateStatus()
    }

    @objc func toggleShuffle() { shuffle.toggle() }

    @objc func setInterval(_ sender: NSMenuItem) {
        interval = Double(sender.tag)
        restartTimer()
    }

    @objc func openFolder() { NSWorkspace.shared.open(store.dir) }
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - Entry point

// `LinkLoop --selftest <url>...` resolves and downloads each link without touching saved data.
if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
    let base = URL(string: "https://example.com/a/")!
    let html1 = #"<META content="/img/x.jpg?a=1&amp;b=2" property="og:image">"#
    let html2 = #"<meta name='twitter:image' content='https://cdn.test/y.png'><meta property="og:image:width" content="5">"#
    precondition(Resolver.findOGImage(html1, base: base)?.absoluteString == "https://example.com/img/x.jpg?a=1&b=2")
    precondition(Resolver.findOGImage(html2, base: base)?.absoluteString == "https://cdn.test/y.png")
    precondition(Resolver.findOGImage("<p>nothing</p>", base: base) == nil)
    precondition(Resolver.pinterestOriginal(URL(string: "https://i.pinimg.com/736x/bf/36/x.jpg")!)?.absoluteString
           == "https://i.pinimg.com/originals/bf/36/x.jpg")
    precondition(Resolver.parse("not a link") == nil && Resolver.parse("ftp://a.b/c") == nil)
    print("parser checks passed")

    let args = Array(CommandLine.arguments[(i + 1)...])
    Task {
        for a in args {
            print("==> \(a)")
            do {
                guard let url = Resolver.parse(a) else { throw LinkError.badURL }
                for c in try await Resolver.resolve(url) {
                    let (data, ext) = try await Resolver.download(c)
                    let badge = c.total.map { " [\(c.index!)/\($0)]" } ?? ""
                    print("   OK\(badge) \(c.link)\n      \(c.image) -> \(data.count) bytes .\(ext)")
                }
            } catch {
                print("   ERROR: \(error.localizedDescription)")
            }
        }
        exit(0)
    }
    dispatchMain()
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
}
