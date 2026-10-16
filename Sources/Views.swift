import SwiftUI

struct LauncherView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            Divider()
            if model.accounts.isEmpty {
                EmptyAccountsView()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.accounts) { account in
                            AccountRow(account: account, session: model.session(for: account))
                        }
                    }
                    .padding(16)
                }
            }
            Divider()
            FooterView()
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 380, idealHeight: 460)
        .background(.background)
        .sheet(item: $model.loginRequest) { request in
            LoginView(request: request)
        }
        .onAppear {
            model.showLauncher = {
                NSApp.activate()
                openWindow(id: "main")
            }
        }
    }
}

private struct HeaderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Legend Remake")
                    .font(.title2.weight(.semibold))
                ServerBadge(state: model.server)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct ServerBadge: View {
    let state: ServerState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var color: Color {
        switch state {
        case .checking: .gray
        case .online: .green
        case .offline: .red
        }
    }

    private var text: String {
        switch state {
        case .checking: "Procurando o servidor…"
        case .online(let players): players == 1 ? "Servidor online · 1 jogador conectado" : "Servidor online · \(players.formatted()) jogadores conectados"
        case .offline: "Servidor indisponível ou sem internet"
        }
    }
}

private struct EmptyAccountsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Adicione sua conta para começar")
                .font(.headline)
            Button("Entrar ou criar conta") { model.requestLogin() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FooterView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack {
            Button {
                model.requestLogin()
            } label: {
                Label("Adicionar conta", systemImage: "plus")
            }
            Spacer()
            Toggle("60 FPS", isOn: $model.highFrameRate)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Por padrão o jogo roda a 25 FPS. Em 60 FPS as animações ficam mais suaves, com um pouco mais de consumo.")
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .help("Ajustes")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct AccountRow: View {
    @EnvironmentObject private var model: AppModel
    let account: Account
    @ObservedObject var session: GameSession

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: account.username, active: session.phase == .playing)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(account.characterName ?? account.username)
                        .font(.headline)
                    if account.characterName != nil {
                        Text(account.username)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if let details = account.characterDetails {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                StatusLine(account: account, session: session)
                if case .loading(let progress) = session.phase {
                    ProgressView(value: progress ?? 0)
                        .progressViewStyle(.linear)
                        .opacity(progress == nil ? 0.4 : 1)
                }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .contextMenu { menu }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch session.phase {
            case .idle, .failed:
                Button("Jogar") { session.play() }
                    .buttonStyle(.borderedProminent)
            case .checking, .loading:
                ProgressView().controlSize(.small)
                Button("Cancelar") { session.stop() }
            case .playing:
                Button("Ir para o jogo") { session.play() }
            case .reconnecting:
                Button("Reconectar agora") { session.play() }
            case .kicked:
                Button("Jogar aqui") { session.play() }
                    .buttonStyle(.borderedProminent)
            case .hung:
                Button("Esperar") { session.waitForEngine() }
                Button("Reiniciar") { session.restart() }
                    .buttonStyle(.borderedProminent)
            }
            Menu {
                menu
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(account.muted ? "Ativar som" : "Silenciar") { model.toggleMute(account) }
        if session.isRunning {
            Button("Reiniciar o jogo") { session.restart() }
            Button("Fechar o jogo") { session.stop() }
        }
        Divider()
        Button("Comprar diamantes") { NSWorkspace.shared.open(Server.recharge) }
        Divider()
        Button("Sair da conta") { model.signOut(account) }
        Button("Remover deste Mac", role: .destructive) { model.remove(account) }
    }
}

private struct StatusLine: View {
    let account: Account
    @ObservedObject var session: GameSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                if account.muted {
                    Image(systemName: "speaker.slash.fill")
                }
                Text(text(at: context.date))
            }
            .font(.callout)
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(2)
        }
    }

    private var color: Color {
        switch session.phase {
        case .failed, .kicked, .hung: .orange
        case .playing where session.online: .green
        default: .secondary
        }
    }

    private func text(at now: Date) -> String {
        switch session.phase {
        case .idle:
            guard let last = account.lastPlayedAt else { return "Pronta para jogar" }
            return "Último acesso \(Formatting.lastAccess(last, now: now))"
        case .checking:
            return "Verificando a sessão…"
        case .loading(let progress):
            guard let progress else { return "Abrindo o jogo…" }
            return "Carregando \(Int(progress * 100))%"
        case .playing:
            guard session.online else { return "Conectando ao jogo…" }
            var parts = [session.onlineSince.map { "No jogo há \(Formatting.elapsed(since: $0, now: now))" } ?? "No jogo"]
            if let fps = session.fps { parts.append("\(fps) FPS") }
            if let memory = session.memoryMB { parts.append("\(memory) MB") }
            return parts.joined(separator: " · ")
        case .reconnecting(let at, let reason):
            let seconds = max(0, Int(at.timeIntervalSince(now).rounded(.up)))
            return "\(reason) Nova tentativa em \(seconds) s…"
        case .kicked:
            return "Esta conta foi conectada em outro lugar."
        case .hung:
            return "O jogo não está respondendo. Aguarde ou reinicie."
        case .failed(let message):
            return message
        }
    }
}

private struct Avatar: View {
    let name: String
    let active: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 40, height: 40)
                .overlay(Text(name.prefix(1).uppercased()).font(.headline).foregroundStyle(.white))
            if active {
                Circle()
                    .fill(.green)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(.background, lineWidth: 2))
            }
        }
    }
}

@MainActor
final class LoginForm: ObservableObject {
    @Published var username = ""
    @Published var password = ""
    @Published var registering = false
    @Published var busy = false
    @Published var error: String?
}

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: LoginRequest
    @StateObject private var form = LoginForm()
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(form.registering ? "Criar conta" : "Entrar")
                .font(.title2.weight(.semibold))
            if let message = form.error ?? request.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(form.error == nil ? Color.secondary : Color.red)
            }
            Form {
                TextField("Usuário", text: $form.username)
                    .textContentType(.username)
                    .focused($focus, equals: .username)
                SecureField("Senha", text: $form.password)
                    .textContentType(form.registering ? .newPassword : .password)
                    .focused($focus, equals: .password)
            }
            .formStyle(.columns)
            .disabled(form.busy)
            .onSubmit(submit)
            HStack {
                Button(form.registering ? "Já tenho uma conta" : "Criar uma conta") {
                    form.registering.toggle()
                    form.error = nil
                }
                .buttonStyle(.link)
                Spacer()
                if form.busy { ProgressView().controlSize(.small) }
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(form.registering ? "Criar" : "Entrar", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.busy || form.username.trimmingCharacters(in: .whitespaces).isEmpty || form.password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            form.username = request.username
            focus = form.username.isEmpty ? .username : .password
        }
    }

    private func submit() {
        let user = form.username.trimmingCharacters(in: .whitespaces)
        let password = form.password
        guard !form.busy, !user.isEmpty, !password.isEmpty else { return }
        form.busy = true
        form.error = nil
        Task {
            defer { form.busy = false }
            do {
                let login = form.registering
                    ? try await model.api.register(username: user, password: password)
                    : try await model.api.login(username: user, password: password)
                form.password = ""
                dismiss()
                model.completeLogin(login)
            } catch {
                form.password = ""
                form.error = error.localizedDescription
                focus = .password
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Desempenho") {
                Toggle("Modo 60 FPS", isOn: $model.highFrameRate)
                Text("Janelas minimizadas ou ocultas passam para 10 FPS e voltam ao normal sozinhas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Cache") {
                Toggle("Salvar arquivos do jogo neste Mac", isOn: $model.cacheEnabled)
                Text("Os arquivos do jogo ficam salvos neste Mac e só são baixados de novo quando o servidor os atualiza. A mudança vale a partir do próximo jogo aberto.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Espaço usado") {
                    Text(ByteCountFormatter.string(fromByteCount: model.cacheUsage, countStyle: .file))
                        .monospacedDigit()
                }
                HStack {
                    Button("Limpar cache") { model.clearCache() }
                    Button("Mostrar logs") { NSWorkspace.shared.open(Paths.shared.logs) }
                }
            }
            Section {
                LabeledContent("Versão") {
                    Text(AppInfo.fullVersion)
                        .monospaced()
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshCacheUsage() }
    }
}
