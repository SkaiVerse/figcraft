import SwiftUI

extension Notification.Name {
    static let fcAddFonts = Notification.Name("FigCraftAddFonts")
    static let fcOpenURL = Notification.Name("FigCraftOpenURL")
}

@main
struct FigCraftApp: App {
    init() {
        // Before any window exists, so FigCraft finds the iPad's fonts when it starts.
        SystemFonts.prepare()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(red: 0.11, green: 0.11, blue: 0.12).ignoresSafeArea()
                FigCraftHost()
            }
            .statusBarHidden(true)
            .onOpenURL { url in
                // "Open in FigCraft" from the Files app.
                NotificationCenter.default.post(name: .fcOpenURL, object: url)
            }
        }
        .commands {
            CommandMenu("Fonts") {
                Button("Add Installed Fonts…") {
                    NotificationCenter.default.post(name: .fcAddFonts, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .option, .shift])
            }
        }
    }
}

struct FigCraftHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> FigCraftViewController { FigCraftViewController() }
    func updateUIViewController(_ vc: FigCraftViewController, context: Context) {}
}
