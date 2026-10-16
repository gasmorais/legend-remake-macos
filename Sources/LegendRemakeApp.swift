import SwiftUI

@main
struct LegendRemakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Legend Remake", id: "main") {
            LauncherView()
                .environmentObject(delegate.model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 460)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Sobre o Legend Remake") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: AppInfo.version,
                        .version: AppInfo.commit,
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Adicionar conta…") { delegate.model.requestLogin() }
                    .keyboardShortcut("n")
            }
            CommandGroup(replacing: .help) {
                Button("Site do Legend Remake") { NSWorkspace.shared.open(Server.site) }
                Button("Mostrar logs") { NSWorkspace.shared.open(Paths.shared.logs) }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var quitting = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        model.runningSessions.isEmpty
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = model.runningSessions
        guard !running.isEmpty, !quitting else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = running.count == 1 ? "Fechar o jogo de \(running[0].username)?" : "Fechar o jogo de \(running.count) contas?"
        alert.informativeText = "Suas contas continuam salvas e entram novamente com um clique."
        alert.addButton(withTitle: "Fechar e sair")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        quitting = true
        Task {
            await model.quitAllGames()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("[launcher] exit")
    }
}
