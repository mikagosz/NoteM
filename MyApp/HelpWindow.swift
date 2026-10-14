import AppKit
import Combine
import SwiftUI

// The Help window: a big title, then sections with a picture of the app on one side and the steps on the
// other, sides taking turns. Numbered points on a picture match the numbered steps.
//
// The pictures are drawn by NoteM itself, on sample data: the main window, the quick-capture panel and the
// Settings panes are rendered off screen from the very same SwiftUI views, fed with a sample store of made-up
// notes in a temporary folder and a separate settings store. ContentView in its sample mode starts none of the
// app's services. Nothing of the user's notes, folders, vault or settings gets in, and nothing real is written.

@MainActor
final class HelpWindow {
    static let shared = HelpWindow()
    /// Left out of the app's invisible scroll bars (`applyThinScrollers`).
    static let identifier = NSUserInterfaceItemIdentifier("NoteMHelp")
    /// `--show-help` has opened the window once already.
    static var shownAtLaunch = false
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = HelpContent.windowTitle.current
            w.identifier = Self.identifier
            w.isReleasedWhenClosed = false
            // The window first, the pictures after it is on screen: drawing them takes a couple of
            // seconds, and with the window still closed the click on Help looked like a hang.
            w.contentView = NSHostingView(rootView: HelpRoot())
            // A fixed height: an `idealHeight` alone gave the window 432 pt (measured in DeskMount 0.1.50).
            w.setContentSize(NSSize(width: HelpPage.width, height: HelpPage.height))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Sample data

/// A sample world for the pictures: its own settings store and a temporary notes folder, both removed
/// once the pictures are made.
@MainActor
enum HelpSample {
    static let suite = "com.mikagosz.NoteM.help-sample"
    static let vaultPath = "/Users/demo/Documents/Obsidian/Inbox NoteM"

    private static func t(_ pl: String, _ en: String) -> String { Loc.t(pl, en) }

    /// The sample settings, notes and settings store, alive until `end()` removes the store and folder.
    /// A class rather than a closure: the pictures are drawn one by one, with the run loop free in between.
    @MainActor
    final class Session {
        let settings: AppSettings
        let model: NotesModel
        let defaults: UserDefaults
        let root: URL

        init() {
            defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            root = FileManager.default.temporaryDirectory.appendingPathComponent("NoteM-help-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let settings = AppSettings(defaults: defaults)
            settings.rules = [
                CategoryRule(keyword: t("faktura", "invoice"), targetFolderPattern: t("Finanse", "Finance"), priority: 0),
                CategoryRule(keyword: t("spotkanie", "meeting"), targetFolderPattern: t("Praca", "Work"), priority: 1),
                CategoryRule(keyword: t("przepis", "recipe"), targetFolderPattern: t("Dom", "Home"), priority: 2),
            ]
            settings.smartFolders = [SmartFolder(id: UUID(), name: t("Pomysły", "Ideas"), icon: "lightbulb",
                                                 conditions: [.tagContains(t("pomysł", "idea"))], conjunctive: true)]
            settings.quickCaptureEnabled = true
            settings.obsidianConnected = true
            // Copies are never sent from the sample: no vault is written to, real or made up.
            settings.obsidianAutoExport = false
            settings.obsidianFolderPath = vaultPath
            self.settings = settings

            model = NotesModel(store: NoteStore(rootURL: root), loadNow: false)
            model.rulesProvider = { settings.rules }
            fill(model)
        }

        func end() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// The sample notes, oldest first, so the list reads newest on top.
    private static func fill(_ model: NotesModel) {
        let notes: [(String, [String], Bool, Bool)] = [
            (t("Przepis na chleb na zakwasie\n\n500 g mąki, 350 ml wody, 100 g zakwasu, sól. Wyrastanie przez noc.",
               "Sourdough bread recipe\n\n500 g flour, 350 ml water, 100 g starter, salt. Rise overnight."), [t("kuchnia", "kitchen")], false, false),
            (t("Faktura za prąd — maj\n\nTermin płatności: 25 maja. Kwota jak w zeszłym miesiącu.",
               "Electricity invoice — May\n\nDue on 25 May. Same amount as last month."), [], false, false),
            (t("Pomysł na wakacje\n\nRowerem wzdłuż wybrzeża, noclegi w małych pensjonatach.",
               "Holiday idea\n\nCycling along the coast, staying in small guesthouses."), [t("pomysł", "idea")], true, false),
            (t("Zakupy na weekend\n\n- [x] mleko\n- [ ] chleb\n- [ ] kawa\n- [ ] owoce",
               "Weekend shopping\n\n- [x] milk\n- [ ] bread\n- [ ] coffee\n- [ ] fruit"), [], false, true),
            (t("Prezenty na urodziny\n\n- [ ] książka dla Ani\n- [ ] kwiaty", "Birthday presents\n\n- [ ] a book for Anna\n- [ ] flowers"),
             [], false, true),
            (t("Spotkanie zespołu — plan\n\n# Plan na czwartek\n\n- przegląd tygodnia\n- **nowy projekt** strony\n- pytania\n\nNotatki ze spotkania trafiają do folderu Praca.",
               "Team meeting — plan\n\n# Plan for Thursday\n\n- review of the week\n- the **new** website project\n- questions\n\nMeeting notes go to the Work folder."),
             [t("praca", "work"), t("zespół", "team")], false, false),
        ]
        for (content, tags, pinned, task) in notes {
            let note = model.createNote(content: content, isTaskList: task)
            if !tags.isEmpty { model.setTags(tags, for: note) }
            if pinned, let n = model.notes.first(where: { $0.id == note.id }) { model.togglePin(n) }
        }
        for (folder, color) in [(t("Praca", "Work"), "blue"), (t("Finanse", "Finance"), "green"), (t("Dom", "Home"), "orange")] {
            model.setCategoryColor(color, forCategory: folder)
        }
    }

    static func meetingNote(in model: NotesModel) -> UUID? {
        model.notes.first { $0.tags.contains(t("zespół", "team")) }?.id
    }

    /// A quick-capture draft with a line of text, in the sample folder.
    static func draft(in root: URL) -> QuickCaptureDraft {
        let draft = QuickCaptureDraft.new(in: root.appendingPathComponent("drafts", isDirectory: true))
        let text = NSAttributedString(string: t("Zadzwonić do serwisu w sprawie roweru — najlepiej rano.",
                                                "Call the bike shop — best in the morning."),
                                      attributes: MarkdownStyler.defaultTypingAttributes)
        do { let data = NoteRichArchive.data(from: text)
            try? FileManager.default.createDirectory(at: draft.folder, withIntermediateDirectories: true)
            try? draft.write(richData: data, meta: QuickCaptureDraft.Meta())
        }
        return draft
    }
}

/// Bitmaps of the app's own windows on sample data, one per kind of picture.
@MainActor
struct HelpPictures {
    var images: [HelpContent.Picture: NSImage] = [:]
    subscript(_ p: HelpContent.Picture) -> NSImage? { images[p] }

    static let windowSize = NSSize(width: 1080, height: 680)
    static let settingsSize = NSSize(width: 700, height: 540)
    static let quickSize = NSSize(width: 360, height: 400)

    /// All of them at once — for the export, which has no window to keep responsive.
    static func make() -> HelpPictures {
        let session = HelpSample.Session()
        defer { session.end() }
        var p = HelpPictures()
        for kind in HelpContent.Picture.allCases { p.images[kind] = draw(kind, in: session) }
        return p
    }

    static func draw(_ kind: HelpContent.Picture, in s: HelpSample.Session) -> NSImage {
        func window(_ selection: SidebarSelection?, palette: Bool = false, title: String = "NoteM") -> NSImage {
            Render.window(ContentView(settings: s.settings, model: s.model, sample: true, selection: selection, palette: palette)
                            .defaultAppStorage(s.defaults),
                          size: windowSize, titled: true, title: title, settle: 0.4)
        }
        func pane(_ pane: SettingsPane) -> NSImage {
            Render.window(SettingsView(settings: s.settings, model: s.model, pane: pane).defaultAppStorage(s.defaults),
                          size: settingsSize, titled: true, title: pane.title(s.settings), settle: 0.15)
        }
        switch kind {
        case .main: return window(.home)
        case .note:
            let meeting = HelpSample.meetingNote(in: s.model)
            return window(meeting.map { SidebarSelection.note($0) },
                          title: s.model.notes.first { $0.id == meeting }?.title ?? "NoteM")
        case .palette: return window(.home, palette: true)
        case .tasks: return window(.tasks)
        case .quick:
            let quick = QuickCaptureView(draft: HelpSample.draft(in: s.root), onSave: { _, _, _, _ in }, onClose: {},
                                         obsidianConnected: true)
            return Render.window(quick.defaultAppStorage(s.defaults), size: quickSize, titled: true, fullSize: false, settle: 0.2)
        case .filing: return pane(.categorization)
        case .smartFolders: return pane(.smartFolders)
        case .sync: return pane(.sync)
        case .obsidian: return pane(.obsidian)
        }
    }
}

/// The pictures for the Help window: taken from the cache at once, the missing ones drawn one by one with the
/// run loop free in between, so the page is there to read straight away and the pictures fill in.
/// Kept for the app's lifetime and on disk, per version, language and light or dark: drawn once, not at every open.
@MainActor
final class HelpPictureStore: ObservableObject {
    static let shared = HelpPictureStore()
    @Published private(set) var pictures = HelpPictures()
    private var key = ""
    private var drawing = false

    func load() {
        let key = Self.cacheKey
        if key != self.key { self.key = key; pictures = HelpPictures() }
        guard !drawing else { return }
        let folder = Self.cacheFolder(key)
        for kind in HelpContent.Picture.allCases where pictures[kind] == nil {
            if let image = Self.read(folder.appendingPathComponent("\(kind).png")) { pictures.images[kind] = image }
        }
        let missing = HelpContent.Picture.allCases.filter { pictures[$0] == nil }
        guard !missing.isEmpty else { return }
        drawing = true
        Task { @MainActor in
            let session = HelpSample.Session()
            for kind in missing {
                // A moment for the window to draw and take a click before the next picture holds the run loop.
                try? await Task.sleep(for: .milliseconds(30))
                let image = HelpPictures.draw(kind, in: session)
                pictures.images[kind] = image
                Self.write(image, folder.appendingPathComponent("\(kind).png"))
            }
            session.end()
            drawing = false
        }
    }

    private static var cacheKey: String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "")-\(info?["CFBundleVersion"] ?? "")"
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return "\(version)-\(Loc.language.rawValue)-\(dark ? "dark" : "light")"
    }

    /// `~/Library/Caches/<bundle ID>/HelpPictures/<key>`; folders of other keys are removed.
    private static func cacheFolder(_ key: String) -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "NoteM", isDirectory: true)
            .appendingPathComponent("HelpPictures", isDirectory: true)
        for old in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent != key {
            try? fm.removeItem(at: old)
        }
        let folder = base.appendingPathComponent(key, isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Saved at twice the size; read back at the size in points.
    private static func read(_ url: URL) -> NSImage? {
        guard let rep = NSImageRep(contentsOf: url) else { return nil }
        rep.size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private static func write(_ image: NSImage, _ url: URL) {
        guard let rep = image.representations.first as? NSBitmapImageRep,
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }
}

@MainActor
enum Render {
    /// A view drawn into a bitmap at twice its size, so it stays sharp on a Retina screen.
    static func bitmap(_ v: NSView) -> NSImage {
        let b = v.bounds
        guard b.width >= 1, b.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage() }
        rep.size = b.size
        v.cacheDisplay(in: b, to: rep)
        let image = NSImage(size: b.size)
        image.addRepresentation(rep)
        return image
    }

    /// A window's content rendered off screen and invisible: the same controls and texts the user sees.
    /// `titled`: a real titled window, so a window's toolbar is drawn too — the whole frame is the bitmap.
    /// `settle`: how long the run loop turns first, for `.task` loads and lists that fill their rows late.
    /// `fullSize`: the content runs under the title bar, as in the main window; off, it starts below it, so a
    /// cut-out can drop the title bar and keep a whole panel (bordered buttons are not drawn in a borderless window).
    static func window<V: View>(_ view: V, size: NSSize, titled: Bool, fullSize: Bool = true, title: String = "",
                                settle: TimeInterval) -> NSImage {
        // Drawn as the window in front: an invisible window is never key, and prominent buttons
        // (Save, Close in quick capture) were left out of the bitmap altogether.
        let controller = NSHostingController(rootView: view.environment(\.controlActiveState, .key))
        controller.sizingOptions = []
        let w = NSWindow(contentViewController: controller)
        w.styleMask = titled ? (fullSize ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                                         : [.titled, .closable, .miniaturizable, .resizable]) : [.borderless]
        w.isReleasedWhenClosed = false
        w.title = title
        w.appearance = NSApp.effectiveAppearance
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.setContentSize(size)
        w.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        w.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        let frame = (titled ? w.contentView?.superview : w.contentView) ?? NSView()
        frame.layoutSubtreeIfNeeded()
        frame.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        var image = NSImage()
        w.effectiveAppearance.performAsCurrentDrawingAppearance { image = bitmap(frame) }
        w.orderOut(nil)
        w.contentViewController = nil
        return image
    }
}

extension NSImage {
    /// A piece of the picture, in points from its top-left corner — like a cut-out screenshot.
    func cutOut(_ r: CGRect) -> NSImage {
        if r == CGRect(origin: .zero, size: size) { return self }
        return NSImage(size: r.size, flipped: false) { _ in
            self.draw(in: NSRect(x: -r.minX, y: r.maxY - self.size.height, width: self.size.width, height: self.size.height),
                      from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}

// MARK: - The page

/// The window's content: the page at once, its pictures filling in as they are ready.
private struct HelpRoot: View {
    @ObservedObject private var store = HelpPictureStore.shared

    var body: some View {
        HelpPage(pictures: store.pictures)
            .onAppear { store.load() }
    }
}

struct HelpPage: View {
    static let width: CGFloat = 960
    static var height: CGFloat { min(900, (NSScreen.main?.visibleFrame.height ?? 900) - 80) }

    let pictures: HelpPictures
    /// For the bitmap of the whole page (`--export-help`): no scrolling, every section unfolded.
    var wholePage = false

    var body: some View {
        if wholePage {
            content.frame(width: Self.width).background(Color(nsColor: .windowBackgroundColor))
        } else {
            // Opens at the title: without the anchor the window came up scrolled a little way down.
            ScrollView { content }
                .defaultScrollAnchor(.top)
                .frame(width: Self.width, height: Self.height)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            ForEach(Array(HelpContent.sections.enumerated()), id: \.offset) { i, s in
                Divider().padding(.horizontal, 60)
                HelpSectionView(section: s, pictureLeft: i % 2 == 0, pictures: pictures, expanded: wholePage)
            }
            Divider().padding(.horizontal, 60)
            goodToKnow
            FractalSignature()
        }
        .padding(.bottom, 40)
    }

    private var header: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 96, height: 96)
            Text(verbatim: HelpContent.title.current).font(.system(size: 40, weight: .semibold))
            Text(verbatim: HelpContent.intro.current)
                .font(.system(size: 17)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(4)
                .frame(maxWidth: 640)
                .fixedSize(horizontal: false, vertical: true)
            WindowPicture(image: pictures[.main], crop: Crop(rect: CGRect(origin: .zero, size: HelpPictures.windowSize), points: []),
                          maxWidth: 840)
                .padding(.top, 8)
        }
        .padding(.top, 44).padding(.bottom, 48).padding(.horizontal, 60)
    }

    private var goodToKnow: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(verbatim: HelpContent.goodToKnow.current).font(.system(size: 30, weight: .semibold))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 20, alignment: .top), GridItem(.flexible(), spacing: 20, alignment: .top)],
                      spacing: 20) {
                ForEach(HelpContent.cards, id: \.symbol) { c in
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: c.symbol).font(.system(size: 22)).foregroundStyle(Color.accentColor)
                        Text(verbatim: c.title.current).font(.headline)
                        Text(verbatim: c.text.current).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
                }
            }
        }
        .padding(.top, 40).padding(.horizontal, 60)
    }
}

private struct HelpSectionView: View {
    let section: HelpContent.Section
    let pictureLeft: Bool
    let pictures: HelpPictures
    @State var expanded: Bool

    /// The main window is wide: its pictures stand under the text, across the page.
    private var wide: Bool { [.main, .note, .tasks].contains(section.picture) }

    var body: some View {
        Group {
            if wide {
                VStack(alignment: .leading, spacing: 28) {
                    text
                    picture.frame(maxWidth: .infinity)
                }
            } else {
                HStack(alignment: .center, spacing: 44) {
                    if pictureLeft { picture }
                    text
                    if !pictureLeft { picture }
                }
            }
        }
        .padding(.vertical, 44).padding(.horizontal, 60)
    }

    private var picture: some View {
        Group {
            switch section.picture {
            case .main: WindowPicture(image: pictures[.main], crop: HelpCrops.main, maxWidth: 840)
            case .note: WindowPicture(image: pictures[.note], crop: HelpCrops.note, maxWidth: 840)
            case .palette: WindowPicture(image: pictures[.palette], crop: HelpCrops.palette)
            case .quick: WindowPicture(image: pictures[.quick], crop: HelpCrops.quick)
            case .tasks: WindowPicture(image: pictures[.tasks], crop: HelpCrops.tasks, maxWidth: 840)
            case .filing: WindowPicture(image: pictures[.filing], crop: HelpCrops.filing)
            case .smartFolders: WindowPicture(image: pictures[.smartFolders], crop: HelpCrops.smartFolders)
            case .sync: WindowPicture(image: pictures[.sync], crop: HelpCrops.sync)
            case .obsidian: WindowPicture(image: pictures[.obsidian], crop: HelpCrops.obsidian)
            }
        }
        .frame(width: wide ? nil : 440)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: section.title.current).font(.system(size: 30, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: section.lead.current).font(.system(size: 15)).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(section.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Marker(number: i + 1, small: true)
                        Text(verbatim: step.current).font(.system(size: 14)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let more = section.more {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                } label: {
                    Label(expanded ? HelpContent.less.current : HelpContent.more.current,
                          systemImage: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.link)
                if expanded {
                    Text(verbatim: more.current).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Cut-outs and points

/// Where to cut a window and where its numbered points stand, in points of the window.
/// x < 0: the point stands in the margin on the left, level with the row — it covers no text.
struct Crop {
    let rect: CGRect
    let points: [CGPoint?]

    static func m(_ y: CGFloat) -> CGPoint { CGPoint(x: -1, y: y) }
}

/// Measured on `--export-help`.
enum HelpCrops {
    private static func m(_ y: CGFloat) -> CGPoint { Crop.m(y) }
    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    private static let window = CGRect(origin: .zero, size: HelpPictures.windowSize)
    /// A Settings pane below its title bar and tab strip (not drawn in a bitmap — a blank band).
    private static let pane = CGRect(x: 0, y: 40, width: HelpPictures.settingsSize.width, height: 320)

    static let main = Crop(rect: window, points: [p(155, 12), m(146), m(520), p(600, 90)])
    static let note = Crop(rect: window, points: [p(375, 632), p(395, 67), p(880, 60)])
    static let palette = Crop(rect: CGRect(x: 250, y: 150, width: 580, height: 390), points: [m(36), m(111), m(293)])
    /// The panel under a title bar drawn only for the bitmap: cut off by `titleBar`.
    private static let titleBar: CGFloat = 32
    static let quick = Crop(rect: CGRect(origin: CGPoint(x: 0, y: titleBar), size: HelpPictures.quickSize),
                            points: [p(330, 15), p(330, 100), p(270, 379)])
    static let tasks = Crop(rect: CGRect(origin: .zero, size: CGSize(width: HelpPictures.windowSize.width, height: 200)),
                            points: [p(150, 81), p(345, 81), p(1030, 81)])
    static let filing = Crop(rect: pane, points: [p(300, 115), p(640, 115), p(22, 155)])
    static let smartFolders = Crop(rect: pane, points: [p(250, 142), p(250, 239)])
    /// Ends above the path of the store: in the sample it is a temporary folder.
    static let sync = Crop(rect: CGRect(x: 0, y: 40, width: HelpPictures.settingsSize.width, height: 170), points: [p(240, 100), p(255, 144)])
    static let obsidian = Crop(rect: pane, points: [p(240, 105), p(330, 161), p(150, 207)])
}

/// A window picture in a section: the cut-out, its frame and the numbered points.
/// Never enlarged beyond 1:1 — bigger than the window it would look like a screenshot under a magnifier.
struct WindowPicture: View {
    /// Nil while the picture is still being drawn: a blank frame of the same size with a spinner.
    let image: NSImage?
    let crop: Crop
    var maxWidth: CGFloat = 440
    private let margin: CGFloat = 36

    var body: some View {
        let r = crop.rect
        let left: CGFloat = crop.points.contains { ($0?.x ?? 0) < 0 } ? margin : 0
        let w = min(maxWidth - left, r.width)
        let scale = w / r.width
        let h = r.height * scale
        Frame {
            HStack(spacing: 0) {
                Color.clear.frame(width: left, height: h)
                if let image {
                    Image(nsImage: image.cutOut(r)).resizable().interpolation(.high).frame(width: w, height: h)
                } else {
                    ProgressView().controlSize(.small).frame(width: w, height: h)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(crop.points.enumerated()), id: \.offset) { i, p in
                        if let p {
                            Marker(number: i + 1).position(x: p.x < 0 ? margin / 2 + 2 : left + p.x * scale, y: p.y * scale)
                        }
                    }
                }
                .frame(width: left + w, height: h, alignment: .topLeading)
            }
        }
    }
}

/// The numbered point on a picture, and the same number in front of a step.
struct Marker: View {
    let number: Int
    var small = false

    var body: some View {
        Text(verbatim: "\(number)")
            .font(.system(size: small ? 11 : 13, weight: .bold)).monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: small ? 20 : 26, height: small ? 20 : 26)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().stroke(.white, lineWidth: small ? 0 : 2))
            .shadow(color: .black.opacity(small ? 0 : 0.35), radius: 3, y: 1)
    }
}

/// Rounded card with a soft shadow — the frame every picture sits in.
struct Frame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

/// The Fractal 8 Dev signature at the end of Help, set like the hero of fractal8.eu: the logo large behind,
/// under the same veil as the site's video (darker at the edges and towards the bottom), and the text over
/// its lower part — "ENDLESS RECURSION" spaced 0.42 em in the accent (#7ee8f2 dark, #0a8796 light), then
/// "Fractal 8 Dev" in SF Pro Bold drawn together by −0.045 em with the site's gradient, then the site's line.
private struct FractalSignature: View {
    @Environment(\.colorScheme) private var scheme
    private static let logo: NSImage? = Bundle.main.url(forResource: "studio-logo", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    var body: some View {
        let dark = scheme == .dark
        let back = Color(nsColor: .windowBackgroundColor)
        let accent = dark ? Color(red: 126 / 255, green: 232 / 255, blue: 242 / 255) : Color(red: 10 / 255, green: 135 / 255, blue: 150 / 255)
        let gradient = LinearGradient(stops: [
            .init(color: dark ? .white : Color(red: 29 / 255, green: 29 / 255, blue: 31 / 255), location: 0.4),
            .init(color: dark ? Color(red: 159 / 255, green: 163 / 255, blue: 171 / 255) : Color(red: 91 / 255, green: 95 / 255, blue: 102 / 255), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        ZStack(alignment: .bottom) {
            if let logo = Self.logo {
                Image(nsImage: logo).resizable().interpolation(.high).frame(width: 560, height: 560)
                    .opacity(dark ? 0.75 : 0.55)
                    .frame(height: 440, alignment: .top)
                    .clipped()
                    // The site's veil (styles.css, .hero-sticky::after): edges and the bottom sink into the background.
                    .overlay(RadialGradient(stops: [.init(color: .clear, location: 0.35), .init(color: back.opacity(0.75), location: 1)],
                                            center: .center, startRadius: 0, endRadius: 300))
                    .overlay(LinearGradient(stops: [.init(color: back.opacity(0.35), location: 0), .init(color: .clear, location: 0.3),
                                                    .init(color: back.opacity(0.55), location: 0.62), .init(color: back, location: 0.92)],
                                            startPoint: .top, endPoint: .bottom))
            }
            VStack(spacing: 0) {
                Text(verbatim: "ENDLESS RECURSION")
                    .font(.system(size: 12)).tracking(12 * 0.42).foregroundStyle(accent)
                    .padding(.bottom, 16)
                Text(verbatim: "Fractal 8 Dev")
                    .font(.system(size: 76, weight: .bold)).tracking(-76 * 0.045)
                    .foregroundStyle(gradient)
                Text(verbatim: HelpContent.signatureLine.current)
                    .font(.system(size: 17)).foregroundStyle(.secondary)
                    .padding(.top, 18)
            }
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 440)
        .padding(.top, 40)
    }
}

// MARK: - Bitmap of the Help page, for checking it without opening a window

/// `NoteM --export-help <folder> -appLanguage pl|en -NoteMStoreRoot <empty folder>`: draws the Help page and the
/// window pictures into PNG files and quits, from `MyApp.init` — before any window opens. The store root keeps the
/// app's own (unused) model away from the real notes too.
enum HelpExport {
    static func runIfRequested() {
        let a = CommandLine.arguments
        // `--export-help-window <folder>`: the Help window as the app shows it (pictures made the way `show()`
        // makes them, the page in a scroll view), to check what the user sees, not only the export.
        if let i = a.firstIndex(of: "--export-help-window"), i + 1 < a.count {
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.prohibited)
                let folder = URL(fileURLWithPath: a[i + 1], isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let size = NSSize(width: HelpPage.width, height: 900)
                let host = NSHostingView(rootView: HelpPage(pictures: HelpPictures.make()))
                let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                host.frame = NSRect(origin: .zero, size: size)
                w.contentView = host
                w.orderFrontRegardless()
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                save(Render.bitmap(host), folder.appendingPathComponent("help-window-\(Loc.language.rawValue).png"))
            }
            exit(0)
        }
        guard let i = a.firstIndex(of: "--export-help"), i + 1 < a.count else { return }
        MainActor.assumeIsolated {
            let folder = URL(fileURLWithPath: a[i + 1], isDirectory: true)
            NSApplication.shared.setActivationPolicy(.prohibited)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let lang = Loc.language.rawValue
            let p = HelpPictures.make()
            for kind in HelpContent.Picture.allCases {
                if let image = p[kind] { save(image, folder.appendingPathComponent("window-\(kind)-\(lang).png")) }
            }
            let page = HelpPage(pictures: p, wholePage: true)
            // The height measured at the fixed width — `fittingSize` measures without it and cuts the top and bottom off.
            let h = NSHostingController(rootView: page)
                .sizeThatFits(in: CGSize(width: HelpPage.width, height: CGFloat.greatestFiniteMagnitude)).height
            save(Render.window(page, size: NSSize(width: HelpPage.width, height: ceil(h)), titled: false, settle: 0.3),
                 folder.appendingPathComponent("help-\(lang).png"))
        }
        exit(0)
    }

    private static func save(_ image: NSImage, _ url: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        FileHandle.standardOutput.write(Data("\(url.path) \(Int(image.size.width))×\(Int(image.size.height))\n".utf8))
    }
}
