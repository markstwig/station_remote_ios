import SwiftUI
import WebKit

// MARK: Liquid Glass with a material fallback for older iOS / older Xcode
extension View {
    @ViewBuilder func glass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            self.glassEffect(interactive ? Glass.regular.interactive() : Glass.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
        #endif
    }
}

func fmt(_ t: Double) -> String { let s = Int(max(0, t)); return "\(s / 60):" + String(format: "%02d", s % 60) }

struct Backdrop: View {
    let url: URL?
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.indigo.opacity(0.55), .black], startPoint: .top, endPoint: .bottom)
            if let url {
                AsyncImage(url: url) { $0.resizable().scaledToFill().blur(radius: 70).opacity(0.85) } placeholder: { Color.clear }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped().ignoresSafeArea()
    }
}

// MARK: Controls tab
struct ControlsView: View {
    @Environment(Station.self) private var s
    @State private var text = ""
    @State private var ask = true
    @State private var scrub: Double?
    @State private var volDrag: Double?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                statusPill
                cover
                VStack(spacing: 4) {
                    Text(s.title.isEmpty ? "Nothing playing" : s.title).font(.title2.bold()).multilineTextAlignment(.center)
                    Text(s.subtitle).foregroundStyle(.secondary)
                }
                progressBar
                transport
                volume
                command
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background { Backdrop(url: s.coverURL) }
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle().fill(s.online ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(s.online && s.alice != "IDLE" ? s.alice.capitalized : s.status).font(.footnote)
        }
        .padding(.horizontal, 14).padding(.vertical, 8).glass(Capsule())
    }

    private var cover: some View {
        Group {
            if let u = s.coverURL {
                AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.2) }
            } else {
                Image(systemName: "hifispeaker.fill").font(.system(size: 64)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).glass(Rectangle())
            }
        }
        .aspectRatio(1, contentMode: .fit).frame(maxWidth: 340)
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous)).shadow(radius: 24, y: 10)
    }

    private var progressBar: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let pos = min(max(s.duration, 1), s.progress + (s.playing ? ctx.date.timeIntervalSince(s.stamp) : 0))
            VStack(spacing: 2) {
                Slider(value: Binding(get: { scrub ?? pos }, set: { scrub = $0 }), in: 0...max(s.duration, 1),
                       onEditingChanged: { editing in if !editing, let v = scrub { s.seek(v); scrub = nil } })
                HStack { Text(fmt(scrub ?? pos)); Spacer(); Text(fmt(s.duration)) }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 28) {
            roundButton("backward.fill", 56) { s.prev() }
            roundButton(s.playing ? "pause.fill" : "play.fill", 80) { if s.playing { s.pause() } else { s.play() } }
            roundButton("forward.fill", 56) { s.next() }
        }
    }

    private func roundButton(_ icon: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.38)).frame(width: size, height: size).contentShape(Circle())
        }
        .buttonStyle(.plain).glass(Circle(), interactive: true)
    }

    private var volume: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
            Slider(value: Binding(get: { volDrag ?? s.volume }, set: { volDrag = $0; s.setVolume($0) }), in: 0...1,
                   onEditingChanged: { editing in
                       guard !editing else { return }
                       if let v = volDrag { s.setVolume(v, force: true) }
                       Task { try? await Task.sleep(for: .seconds(0.7)); volDrag = nil }
                   })
            Image(systemName: "speaker.wave.3.fill")
        }
        .padding(.horizontal, 18).padding(.vertical, 14).glass(Capsule())
    }

    private var command: some View {
        VStack(spacing: 12) {
            Picker("", selection: $ask) { Text("Ask Alice").tag(true); Text("Speak aloud").tag(false) }.pickerStyle(.segmented)
            HStack {
                TextField(ask ? "Turn on the kitchen lights" : "Dinner is ready", text: $text)
                    .submitLabel(.send).onSubmit(send)
                Button("Send", action: send).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !s.lastError.isEmpty { Text(s.lastError).font(.footnote).foregroundStyle(.red) }
        }
        .padding(16).glass(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if ask { s.say(t) } else { s.speak(t) }
        text = ""
    }
}

// MARK: Settings tab
struct SettingsView: View {
    @Environment(Station.self) private var station
    @State private var showSignIn = false
    @State private var devices: [Device] = []
    @State private var msg = ""

    var body: some View {
        @Bindable var s = station
        NavigationStack {
            Form {
                Section("Yandex account") {
                    Label(s.hasToken ? "Signed in" : "Not signed in",
                          systemImage: s.hasToken ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                    Button(s.hasToken ? "Sign in again" : "Sign in to Yandex") { showSignIn = true }
                    if s.hasToken { Button("Sign out", role: .destructive) { s.setToken(nil) } }
                }
                Section("Speaker") {
                    Button("Find my speakers") { Task { await find() } }.disabled(!s.hasToken)
                    ForEach(devices) { d in
                        Button("\(d.name) (\(d.platform))") { s.deviceId = d.id; s.platform = d.platform; if let ip = d.ip { s.host = ip } }
                    }
                    TextField("IP address", text: $s.host).keyboardType(.decimalPad)
                    TextField("Device ID", text: $s.deviceId)
                    TextField("Platform", text: $s.platform)
                    Button("Connect") { s.saveSettings(); s.connect() }
                    if !msg.isEmpty { Text(msg).font(.footnote).foregroundStyle(.red) }
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                Section {
                    Toggle("Control from Control Center", isOn: $s.controlCenter)
                } header: { Text("Background") } footer: {
                    Text("Shows the speaker in Control Center and on the lock screen. The app plays silent audio to stay active, so it interrupts other audio on this phone while the speaker is playing.")
                }
                Section("Status") {
                    Text(s.status)
                    if !s.lastError.isEmpty { Text(s.lastError).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showSignIn) { SignInSheet { tok in station.setToken(tok); showSignIn = false } }
            .onChange(of: s.controlCenter) { s.saveSettings(); s.refreshNowPlaying() }
        }
    }

    private func find() async {
        do { devices = try await station.listDevices(); msg = devices.isEmpty ? "No speakers returned." : "" }
        catch { msg = error.localizedDescription }
    }
}

// MARK: Yandex sign-in (captures the token from the redirect, no copy-paste)
struct SignInSheet: View {
    let onToken: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            SignInWeb(onToken: onToken).ignoresSafeArea(edges: .bottom)
                .navigationTitle("Yandex").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct SignInWeb: UIViewRepresentable {
    let onToken: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onToken) }
    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.navigationDelegate = context.coordinator
        w.load(URLRequest(url: URL(string: "https://oauth.yandex.ru/authorize?response_type=token&client_id=23cabbbdc6cd418abb4b39c32c41195d")!))
        return w
    }
    func updateUIView(_ v: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let cb: (String) -> Void
        init(_ cb: @escaping (String) -> Void) { self.cb = cb }
        func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let u = a.request.url?.absoluteString, let r = u.range(of: "access_token=") {
                decisionHandler(.cancel)
                cb(String(u[r.upperBound...].prefix { $0 != "&" }))
            } else { decisionHandler(.allow) }
        }
    }
}
