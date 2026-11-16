import UIKit
import UniformTypeIdentifiers

/// Writes a line to FigCraft-log.txt (visible in Files: On My iPad > FigCraft).
func fcLog(_ message: String) {
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    let url = docs.appendingPathComponent("FigCraft-log.txt")
    let line = "[swift] \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Owns the drawing view and everything that needs Apple's own screens: Files, alerts,
/// the font picker.
///
/// Saving: Save As (and a design's first save) always shows Apple's Save to Files sheet. After
/// that, the app's Save and AutoSave write a working copy in Documents/Working, and this class
/// copies that file to the file the person chose, silently, about a second later.
final class FigCraftViewController: UIViewController, UIDocumentPickerDelegate, UIFontPickerViewControllerDelegate {

    private let metal = MetalView()
    private enum Mode { case open, save }
    private var mode: Mode = .open
    private var savingName: String?

    /// File name -> the file the person chose in the Save to Files sheet.
    private var targets: [String: URL] = [:]
    /// File name -> when its working copy was last copied to the chosen file.
    private var lastCopied: [String: Date] = [:]
    private var mirrorTimer: Timer?

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    private var workingFolder: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("Working", isDirectory: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)

        metal.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(metal)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            metal.topAnchor.constraint(equalTo: guide.topAnchor),
            metal.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            metal.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            metal.trailingAnchor.constraint(equalTo: guide.trailingAnchor)
        ])

        metal.onOpenFiles = { [weak self] in self?.pickToOpen() }
        metal.onSave = { [weak self] name, data in self?.handleSave(name: name, data: data) }
        metal.onOpenURL = { url in
            guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else { return }
            UIApplication.shared.open(u)
        }
        metal.onCopyText = { UIPasteboard.general.string = $0 }
        metal.onPasteText = { UIPasteboard.general.hasStrings ? UIPasteboard.general.string : nil }
        metal.onPasteHTML = {
            guard UIPasteboard.general.contains(pasteboardTypes: ["public.html"]) else { return nil }
            if let s = UIPasteboard.general.value(forPasteboardType: "public.html") as? String { return s }
            if let d = UIPasteboard.general.data(forPasteboardType: "public.html") { return String(data: d, encoding: .utf8) }
            return nil
        }
        metal.onCopyImage = { w, h, rgba in
            guard let provider = CGDataProvider(data: rgba as CFData),
                  let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
            UIPasteboard.general.image = UIImage(cgImage: cg)
        }
        metal.onPasteImage = {
            guard UIPasteboard.general.hasImages, let image = UIPasteboard.general.image else { return nil }
            return image.pngData()
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.mirrorWorkingCopies()
            self?.metal.saveState()
            self?.metal.setFocused(false)
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.metal.setFocused(true)
        }
        nc.addObserver(forName: .fcAddFonts, object: nil, queue: .main) { [weak self] _ in
            self?.showFontPicker()
        }
        nc.addObserver(forName: .fcOpenURL, object: nil, queue: .main) { [weak self] note in
            guard let self = self, self.view.window?.isKeyWindow ?? true, let url = note.object as? URL else { return }
            self.read(url) { name, data in self.metal.deliverOpened(name: name, data: data) }
        }

        mirrorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.mirrorWorkingCopies()
        }
    }

    // MARK: Fonts

    /// Apple's own font picker: the only way an app can use fonts installed on the iPad.
    private func showFontPicker() {
        guard presentedViewController == nil, view.window?.isKeyWindow ?? true else { return }
        var configuration = UIFontPickerViewController.Configuration()
        configuration.includeFaces = false
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.delegate = self
        metal.suspendFocus = true
        present(picker, animated: true)
    }

    func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
        metal.suspendFocus = false
        guard let descriptor = viewController.selectedFontDescriptor else { return }
        let stored = SystemFonts.addPicked(descriptor)
        if presentedViewController != nil { dismiss(animated: true) }
        let family = (descriptor.object(forKey: .family) as? String) ?? "the font"
        if stored.isEmpty {
            message("Couldn’t add the font", "iPadOS did not let FigCraft copy “\(family)”. Some protected fonts can’t be used.")
        } else {
            message("Font added", "Added \(stored.count) style(s) of “\(family)”. Restart FigCraft once to use \(stored.count == 1 ? "it" : "them").")
        }
    }

    func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) {
        metal.suspendFocus = false
    }

    // MARK: Opening files

    private func pickToOpen() {
        fcLog("open requested; already presenting: \(presentedViewController != nil)")
        guard presentedViewController == nil else { metal.cancelOpen(); return }
        mode = .open
        // A copy of the one chosen file: tapping the file returns it straight away.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        metal.suspendFocus = true
        present(picker, animated: true) { fcLog("picker is on screen") }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        fcLog("picker returned \(urls.count) item(s) in mode \(mode)")
        metal.suspendFocus = false
        switch mode {
        case .open:
            guard let url = urls.first else { metal.cancelOpen(); return }
            read(url) { name, data in self.metal.deliverOpened(name: name, data: data) }
        case .save:
            if let u = urls.first {
                register(target: u)
                metal.saveResult(ok: true, name: u.lastPathComponent)
            } else {
                metal.saveResult(ok: false)
            }
            savingName = nil
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        fcLog("picker cancelled in mode \(mode)")
        metal.suspendFocus = false
        switch mode {
        case .open:
            metal.cancelOpen()
        case .save:
            metal.saveResult(ok: false)
            if let name = savingName, name.lowercased().hasSuffix(".figcraft") {
                message("Not saved yet",
                        "You cancelled the save, but FigCraft already shows “\(name)” as saved. A copy is kept in Files › On My iPad › FigCraft › Working. Save again to choose where it goes.")
            }
            savingName = nil
        }
    }

    private func read(_ url: URL, deliver: (String, Data) -> Void) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            fcLog("read \(data.count) bytes from \(url.lastPathComponent)")
            deliver(url.lastPathComponent, data)
        } catch {
            fcLog("read failed: \(error.localizedDescription)")
            metal.cancelOpen(error: "Couldn’t read \(url.lastPathComponent).")
            message("Couldn’t open the file", error.localizedDescription)
        }
    }

    // MARK: Saving

    /// Always Apple's own Save to Files sheet (Save As, a first save, or an export).
    private func handleSave(name: String, data: Data) {
        fcLog("save sheet requested: \(name), \(data.count) bytes")
        guard presentedViewController == nil else { metal.saveResult(ok: false); return }
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(safe)
            try data.write(to: file)
            mode = .save
            savingName = safe
            let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
            picker.delegate = self
            metal.suspendFocus = true
            present(picker, animated: true)
        } catch {
            metal.suspendFocus = false
            metal.saveResult(ok: false)
            message("Couldn’t prepare the file", error.localizedDescription)
        }
    }

    /// Remembers the file the person chose, so later saves can update it without asking.
    private func register(target url: URL) {
        let name = url.lastPathComponent
        guard name.lowercased().hasSuffix(".figcraft") else { return }
        _ = url.startAccessingSecurityScopedResource()   // kept open so later saves can write
        targets[name] = url
        lastCopied[name] = Date()
        fcLog("silent saves will update \(name)")
    }

    /// Copies each working copy that changed since the last copy to the file the person chose.
    private func mirrorWorkingCopies() {
        guard let folder = workingFolder else { return }
        for (name, url) in targets {
            let work = folder.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: work.path),
                  let modified = attrs[.modificationDate] as? Date else { continue }
            if modified <= (lastCopied[name] ?? .distantPast) { continue }
            guard let data = try? Data(contentsOf: work) else { continue }

            var coordError: NSError?
            var writeError: Error?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
                do { try data.write(to: writeURL) } catch { writeError = error }
            }
            if let e = (coordError as Error?) ?? writeError {
                fcLog("could not update \(name): \(e.localizedDescription)")
                targets[name] = nil
                message("Couldn’t update “\(name)”",
                        "Your changes are kept in Files › On My iPad › FigCraft › Working. Use Save As to save a copy where you want it.\n\n\(e.localizedDescription)")
            } else {
                lastCopied[name] = modified
                fcLog("updated \(name) (\(data.count) bytes)")
            }
        }
    }

    // MARK: Messages

    /// Shown a moment later, so it still appears while a picker is closing.
    private func message(_ title: String, _ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, self.presentedViewController == nil else { return }
            let a = UIAlertController(title: title, message: text, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            self.present(a, animated: true)
        }
    }
}
