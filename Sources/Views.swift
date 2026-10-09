import SwiftUI
import UIKit
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

private func dot(_ on: Bool) -> some View {
    Circle().fill(on ? Color.green : Color.gray.opacity(0.6)).frame(width: 8, height: 8)
}

// MARK: Home (Now Playing)
struct HomeView: View {
    @Environment(Station.self) private var s
    @State private var scrub: Double?
    @State private var volDrag: Double?
    @State private var pickerOpen = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        GeometryReader { g in
            let art = max(110, min(g.size.width - 64, g.size.height * 0.40))
            VStack(spacing: 0) {
                Spacer(minLength: 56)              // room for the speaker picker
                artwork(art)
                Spacer(minLength: 14)
                titleRow
                progressBar.padding(.top, 14)
                Spacer(minLength: 6)
                transport
                Spacer(minLength: 6)
                volume
                Spacer(minLength: 10)
            }
            .padding(.horizontal, 28).frame(width: g.size.width, height: g.size.height)
        }
        .background { Backdrop(url: s.coverURL) }
        .overlay(alignment: .top) { SpeakerPicker(open: $pickerOpen).padding(.horizontal, 24).padding(.top, 6) }
        .alert("Yandex Music", isPresented: Binding(get: { s.notice != nil }, set: { if !$0 { s.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(s.notice ?? "") }
    }

    private func artwork(_ side: CGFloat) -> some View {
        Group {
            if let u = s.coverURL {
                AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.25) }
            } else {
                Image(systemName: "hifispeaker.fill").font(.system(size: side * 0.3)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.ultraThinMaterial)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 30, y: 16)
        .scaleEffect(s.playing ? 1 : 0.88)
        .animation(.spring(duration: 0.5, bounce: 0.3), value: s.playing)
    }

    private var titleRow: some View {
        HStack(spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title.isEmpty ? "Nothing playing" : s.title).font(.title3.weight(.semibold)).lineLimit(1)
                Text(s.subtitle.isEmpty ? (s.online && s.alice != "IDLE" ? s.alice.capitalized : s.status) : s.subtitle)
                    .font(.title3).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { Task { await s.toggleLike() } } label: {
                Image(systemName: s.liked.contains(s.trackID) ? "heart.fill" : "heart").font(.title3).frame(width: 36, height: 40)
            }
            .disabled(s.trackID.isEmpty)
            .accessibilityLabel("Like on Yandex Music")
            Button { s.toggleSave() } label: {
                Image(systemName: s.isSaved ? "bookmark.fill" : "bookmark").font(.title3).frame(width: 36, height: 40)
            }
            .accessibilityLabel(s.isSaved ? "Remove from saved" : "Save for later")
            Button { let t = s.title, a = s.subtitle; Task { openURL(await s.appleMusicURL(t, a)) } } label: {
                Image(systemName: "arrow.up.forward.app").font(.title3).frame(width: 36, height: 40)
            }
            .accessibilityLabel("Open in Apple Music")
        }
        .buttonStyle(.plain).disabled(s.title.isEmpty)
    }

    private var progressBar: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let pos = min(max(s.duration, 1), s.progress + (s.playing ? ctx.date.timeIntervalSince(s.stamp) : 0))
            VStack(spacing: 0) {
                Slider(value: Binding(get: { scrub ?? pos }, set: { scrub = $0 }), in: 0...max(s.duration, 1),
                       onEditingChanged: { editing in if !editing, let v = scrub { s.seek(v); scrub = nil } })
                HStack { Text(fmt(scrub ?? pos)); Spacer(); Text("-" + fmt(s.duration - (scrub ?? pos))) }
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var transport: some View {
        HStack {
            Spacer(); icon("backward.fill", 30) { s.prev() }
            Spacer(); icon(s.playing ? "pause.fill" : "play.fill", 46) { if s.playing { s.pause() } else { s.play() } }
                .contentTransition(.symbolEffect(.replace))
            Spacer(); icon("forward.fill", 30) { s.next() }
            Spacer()
        }
    }

    private func icon(_ name: String, _ size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: size)).foregroundStyle(.primary)
                .frame(width: 64, height: 64).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var volume: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").font(.footnote)
            Slider(value: Binding(get: { volDrag ?? s.volume }, set: { volDrag = $0; s.setVolume($0) }), in: 0...1,
                   onEditingChanged: { editing in
                       guard !editing else { return }
                       if let v = volDrag { s.setVolume(v, force: true) }
                       Task { try? await Task.sleep(for: .seconds(0.7)); volDrag = nil }
                   })
            Image(systemName: "speaker.wave.3.fill").font(.footnote)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: Collapsible speaker picker, AirPlay-style
struct SpeakerPicker: View {
    @Environment(Station.self) private var s
    @Binding var open: Bool

    var body: some View {
        VStack(spacing: 6) {
            Button {
                withAnimation(.spring(duration: 0.35)) { open.toggle() }
                if open { Task { await s.refreshReachability() } }
            } label: {
                HStack(spacing: 8) {
                    dot(s.current.map { s.available($0) } ?? false)
                    Text(s.current?.name ?? "No speaker").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold)).rotationEffect(.degrees(open ? 180 : 0))
                }
                .frame(maxWidth: open ? .infinity : nil).padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { list }
        }
        .padding(.horizontal, 16).padding(.vertical, open ? 8 : 2)
        .glass(RoundedRectangle(cornerRadius: open ? 26 : 22, style: .continuous))
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(s.accounts) { a in
                let sps = s.speakers.filter { $0.account == a.id }
                if !sps.isEmpty {
                    Text(a.label).font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                    ForEach(sps) { sp in
                        Button {
                            withAnimation(.spring(duration: 0.35)) { open = false }
                            s.select(sp)
                        } label: {
                            HStack {
                                dot(s.available(sp)); Text(sp.name); Spacer()
                                if sp.id == s.current?.id { Image(systemName: "checkmark") }
                            }
                            .padding(.vertical, 9).opacity(s.available(sp) ? 1 : 0.5).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if s.speakers.isEmpty {
                Text("Add a Yandex account in Settings").font(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
            }
        }
        .transition(.opacity)
    }
}

// MARK: Commands
struct CommandsView: View {
    @Environment(Station.self) private var s
    @State private var text = ""
    @State private var ask = true
    @State private var query = ""
    @State private var waveAcc = ""
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section("Alice") {
                    Picker("", selection: $ask) { Text("Ask Alice").tag(true); Text("Speak aloud").tag(false) }
                        .pickerStyle(.segmented)
                    HStack {
                        TextField(ask ? "Turn on the kitchen lights" : "Dinner is ready", text: $text)
                            .submitLabel(.send).onSubmit(send)
                        Button("Send", action: send).buttonStyle(.borderless)
                            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    HStack(spacing: 8) {
                        Button { s.say("Включи мою волну") } label: { Label("My Wave", systemImage: "waveform").frame(maxWidth: .infinity) }
                        Button { s.say("Включи моё любимое") } label: { Label("Favorites", systemImage: "heart").frame(maxWidth: .infinity) }
                        Button { s.say("Включи музыку") } label: { Label("Any", systemImage: "music.note").frame(maxWidth: .infinity) }
                    }
                    .buttonStyle(.bordered).font(.footnote)
                    if s.accounts.count > 0 {
                        Picker("Recommendations of", selection: $waveAcc) { ForEach(s.accounts) { Text($0.label).tag($0.id) } }
                        Button("Show this account's My Wave tracks") {
                            if let a = s.accounts.first(where: { $0.id == waveAcc }) ?? s.accounts.first { Task { await s.loadWave(a) } }
                        }
                    }
                } header: { Text("Recommended") } footer: {
                    Text("The buttons ask Alice, who uses the Station's own profile. The Station tells voice profiles apart by listening, so a text command can't pick one. The track list uses the chosen account's own recommendations instead; tap a track to play it.")
                }
                Section("Play music") {
                    HStack {
                        TextField("Search Yandex Music", text: $query).submitLabel(.search).onSubmit(search)
                        if s.searching { ProgressView() }
                        else { Button { search() } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless) }
                    }
                    ForEach(s.results) { t in
                        Button { s.playTrack(t) } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: t.cover) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.25) }
                                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading) {
                                    Text(t.title).lineLimit(1)
                                    Text(t.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(fmt(t.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                        .contextMenu { Button("Play via Alice", systemImage: "waveform") { s.playViaAlice(t) } }
                    }
                }
                if !s.saved.isEmpty {
                    Section("Saved for later") {
                        ForEach(s.saved) { song in
                            Button { s.playSaved(song) } label: {
                                HStack(spacing: 12) {
                                    AsyncImage(url: song.cover.flatMap { URL(string: $0) }) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.25) }
                                        .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading) {
                                        Text(song.title).lineLimit(1)
                                        Text(song.artist).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }
                            .foregroundStyle(.primary)
                            .contextMenu {
                                Button("Play via Alice", systemImage: "waveform") { s.say("Включи \(song.artist) — \(song.title)") }
                                Button("Open in Apple Music", systemImage: "arrow.up.forward.app") {
                                    Task { openURL(await s.appleMusicURL(song.title, song.artist)) }
                                }
                            }
                        }
                        .onDelete { s.saved.remove(atOffsets: $0); s.persist() }
                    }
                }
                if !s.lastError.isEmpty { Section { Text(s.lastError).font(.footnote).foregroundStyle(.red) } }
            }
            .navigationTitle("Commands")
            .onAppear { if waveAcc.isEmpty { waveAcc = s.current?.account ?? s.accounts.first?.id ?? "" } }
        }
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if ask { s.say(t) } else { s.speak(t) }
        text = ""
    }
    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        Task { await s.search(q) }
    }
}

// MARK: Live log
struct LogView: View {
    @Environment(Station.self) private var s
    @State private var hideState = false
    @State private var hidePings = false
    @State private var compact = true
    @State private var expandAll = false
    @State private var filter = ""

    private var shown: [LogLine] {
        s.log.filter { l in
            (!hideState || !l.text.contains("\"state\"")) &&
            (!hidePings || !l.text.contains("\"command\":\"ping\"")) &&
            (filter.isEmpty || l.text.localizedCaseInsensitiveContains(filter))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(shown) { l in LogRow(line: l, compact: compact, expandAll: expandAll) }
                    .listStyle(.plain)
                    .onChange(of: s.log.count) { if let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .overlay { if shown.isEmpty { Text(s.log.isEmpty ? "No messages yet" : "Nothing matches").foregroundStyle(.secondary) } }
            .searchable(text: $filter, prompt: "Filter messages")
            .navigationTitle("Live log")
            .toolbar {
                Menu {
                    Toggle("Expand all", isOn: $expandAll)
                    Toggle("Compact (hide ids & timestamps)", isOn: $compact)
                    Toggle("Hide state updates", isOn: $hideState)
                    Toggle("Hide pings", isOn: $hidePings)
                    Button(s.logPaused ? "Resume" : "Pause", systemImage: s.logPaused ? "play" : "pause") { s.logPaused.toggle() }
                    ShareLink(item: s.log.map { ($0.out ? "> " : "< ") + $0.text }.joined(separator: "\n")) {
                        Label("Export everything", systemImage: "square.and.arrow.up")
                    }
                    Button("Clear", systemImage: "trash", role: .destructive) { s.log.removeAll() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }
}

/// One log entry: a one-line summary that expands to the complete, pretty-printed message.
private struct LogRow: View {
    let line: LogLine
    let compact: Bool
    let expandAll: Bool
    @State private var open = false
    private var isOpen: Bool { open || expandAll }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
                Text(line.out ? "→" : "←")
                Text(line.date, format: .dateTime.hour().minute().second())
                Text(summary).lineLimit(1).foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .font(.caption.monospacedDigit()).foregroundStyle(line.out ? Color.blue : Color.green)
            .contentShape(Rectangle()).onTapGesture { withAnimation(.snappy) { open.toggle() } }
            if isOpen {
                Text(detail).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            }
        }
        .contextMenu { Button("Copy raw message", systemImage: "doc.on.doc") { UIPasteboard.general.string = line.text } }
    }

    private var json: Any? { try? JSONSerialization.jsonObject(with: Data(line.text.utf8)) }

    private var summary: String {
        guard let o = json as? [String: Any] else { return String(line.text.prefix(80)) }
        if let p = o["payload"] as? [String: Any] {
            let c = p["command"] as? String ?? "?"
            let extra = (p["text"] as? String) ?? p["volume"].map { "\($0)" } ?? p["position"].map { "\($0)" } ?? (p["id"] as? String)
            return extra.map { "\(c): \($0)" } ?? c
        }
        if let st = o["state"] as? [String: Any] {
            let title = (st["playerState"] as? [String: Any])?["title"] as? String ?? ""
            return "state · " + ((st["playing"] as? Bool) == true ? "playing" : "idle/paused") + (title.isEmpty ? "" : " · " + title)
        }
        return "reply · " + ((o["status"] as? String) ?? o.keys.sorted().prefix(4).joined(separator: ", "))
    }

    private var detail: String {
        guard var o = json else { return line.text }
        if compact, var d = o as? [String: Any] { for k in ["conversationToken", "sentTime", "id"] { d[k] = nil }; o = d }
        return pretty(o)
    }
}

// MARK: Settings
struct SignInTarget: Identifiable { let id = UUID(); let account: Account? }

struct SettingsView: View {
    @Environment(Station.self) private var station
    @State private var target: SignInTarget?

    var body: some View {
        @Bindable var s = station
        NavigationStack {
            Form {
                Section {
                    DisclosureGroup("Station info") {
                        if let sp = station.current {
                            row("Name", sp.name); row("Device ID", sp.id); row("Platform", sp.platform)
                            row("Address", "\(sp.host):1961")
                            row("Account", station.accounts.first { $0.id == sp.account }?.label ?? "—")
                            row("Connection", station.status)
                            row("Alice", station.alice); row("Volume", "\(Int(station.volume * 100))%")
                            raw("Yandex device record", sp.raw)
                            raw("Software info", station.versionJSON)
                            raw("Live state", station.stateJSON)
                        } else { Text("No speaker selected").foregroundStyle(.secondary) }
                    }
                }
                Section("Yandex accounts") {
                    ForEach($s.accounts) { $a in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Label", text: $a.label)
                            Text("\(station.speakers.filter { $0.account == a.id }.count) speaker(s)")
                                .font(.footnote).foregroundStyle(.secondary)
                            HStack(spacing: 16) {
                                Button("Refresh") { Task { await station.refreshDevices(a) } }
                                Button("Sign in again") { target = SignInTarget(account: a) }
                                Button("Remove", role: .destructive) { station.removeAccount(a) }
                            }
                            .buttonStyle(.borderless).font(.footnote)
                        }
                    }
                    Button("Add Yandex account") { target = SignInTarget(account: nil) }
                }
                Section {
                    ForEach($s.speakers) { $sp in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(sp.name); Spacer(); Circle().fill(station.available(sp) ? Color.green : Color.gray.opacity(0.6)).frame(width: 8, height: 8) }
                            TextField("IP address", text: $sp.host).keyboardType(.decimalPad).font(.footnote)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                    Button("Reconnect") { station.persist(); station.connect() }
                } header: { Text("Speakers") } footer: {
                    Text("Availability is checked by probing the saved IP addresses. Use Refresh on an account to re-read IPs from Yandex.")
                }
                Section {
                    Toggle("Control from Control Center", isOn: $s.controlCenter)
                } header: { Text("Background") } footer: {
                    Text("Shows the speaker in Control Center and on the lock screen. The app plays silent audio to stay active; if another app takes over audio, it steps aside without pausing the speaker.")
                }
                if !station.lastError.isEmpty { Section("Last error") { Text(station.lastError).font(.footnote) } }
            }
            .navigationTitle("Settings")
            .sheet(item: $target) { t in
                SignInSheet(title: t.account?.label ?? "New account") { tok in
                    if let a = t.account { station.replaceToken(a, tok) } else { Task { await station.addAccount(token: tok) } }
                    target = nil
                }
            }
            .onChange(of: s.accounts) { station.persist() }
            .onChange(of: s.speakers) { station.persist() }
            .onChange(of: s.controlCenter) { station.persist(); station.refreshNowPlaying() }
        }
    }

    private func row(_ k: String, _ v: String) -> some View { LabeledContent(k) { Text(v).textSelection(.enabled) } }
    private func raw(_ title: String, _ text: String) -> some View {
        DisclosureGroup(title) { Text(text.isEmpty ? "—" : text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
    }
}

// MARK: Yandex sign-in (captures the token from the redirect, no copy-paste)
struct SignInSheet: View {
    let title: String
    let onToken: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            SignInWeb(onToken: onToken).ignoresSafeArea(edges: .bottom)
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct SignInWeb: UIViewRepresentable {
    let onToken: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onToken) }
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()   // fresh login every time, so a second account can be added
        let w = WKWebView(frame: .zero, configuration: cfg)
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
