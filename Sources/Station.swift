import Foundation
import Network
import Observation

struct StationError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct Account: Codable, Identifiable, Hashable { var id: String; var label: String }
struct Speaker: Codable, Identifiable, Hashable {
    var id: String          // Yandex device id
    var name: String
    var platform: String
    var host: String
    var account: String
    var raw: String = ""    // device record from Yandex, pretty-printed
}
struct Track: Identifiable { let id: String; let title: String; let artist: String; let cover: URL?; let duration: Double }
struct LogLine: Identifiable { let id = UUID(); let date = Date(); let out: Bool; let text: String }

enum Keychain {
    private static func base(_ k: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: "yandex-oauth-" + k]
    }
    static func get(_ k: String) -> String? {
        var q = base(k); q[kSecReturnData as String] = true
        var r: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data { return String(data: d, encoding: .utf8) }
        return UserDefaults.standard.string(forKey: "tok-" + k)
    }
    static func set(_ k: String, _ v: String?) {
        SecItemDelete(base(k) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "tok-" + k)
        guard let v else { return }
        var q = base(k); q[kSecValueData as String] = Data(v.utf8)
        if SecItemAdd(q as CFDictionary, nil) != errSecSuccess { UserDefaults.standard.set(v, forKey: "tok-" + k) }
    }
}

/// Accepts the speaker's self-signed certificate. Only the WebSocket session uses this.
final class TrustAll: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let t = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: t))
        }
        return (.performDefaultHandling, nil)
    }
}

final class Once {
    private let l = NSLock(); private var done = false
    func run(_ f: () -> Void) { l.lock(); defer { l.unlock() }; if !done { done = true; f() } }
}

/// True if something accepts a TCP connection on the speaker's local-API port.
func probe(_ host: String) async -> Bool {
    await withCheckedContinuation { cont in
        let once = Once()
        let c = NWConnection(host: NWEndpoint.Host(host), port: 1961, using: .tcp)
        c.stateUpdateHandler = { st in
            switch st {
            case .ready: once.run { cont.resume(returning: true) }; c.cancel()
            case .failed, .waiting: once.run { cont.resume(returning: false) }; c.cancel()
            default: break
            }
        }
        c.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { once.run { cont.resume(returning: false) }; c.cancel() }
    }
}

func pretty(_ o: Any) -> String {
    guard JSONSerialization.isValidJSONObject(o),
          let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return "\(o)" }
    return String(decoding: d, as: UTF8.self)
}

@MainActor @Observable
final class Station {
    var accounts: [Account] = []
    var speakers: [Speaker] = []
    var selectedID = ""
    var reachable: [String: Bool] = [:]
    var controlCenter = true

    var status = "Starting…"
    var lastError = ""
    var online = false
    var playing = false
    var volume = 0.0
    var alice = "IDLE"
    var title = ""
    var subtitle = ""
    var duration = 0.0
    var progress = 0.0
    var stamp = Date()
    var coverURL: URL?
    var stateJSON = ""
    var versionJSON = ""

    var log: [LogLine] = []
    var logPaused = false
    var results: [Track] = []
    var searching = false

    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var convToken = ""
    @ObservationIgnored private var versionReq = ""
    @ObservationIgnored private var gen = 0
    @ObservationIgnored private var lastVol = Date.distantPast
    let nowPlaying = NowPlaying()

    init() { load() }

    // MARK: persistence
    private func load() {
        let d = UserDefaults.standard
        if let x = d.data(forKey: "accounts"), let v = try? JSONDecoder().decode([Account].self, from: x) { accounts = v }
        if let x = d.data(forKey: "speakers"), let v = try? JSONDecoder().decode([Speaker].self, from: x) { speakers = v }
        selectedID = d.string(forKey: "sel") ?? ""
        controlCenter = d.object(forKey: "cc") as? Bool ?? true
    }
    func persist() {
        let d = UserDefaults.standard
        d.set(try? JSONEncoder().encode(accounts), forKey: "accounts")
        d.set(try? JSONEncoder().encode(speakers), forKey: "speakers")
        d.set(selectedID, forKey: "sel"); d.set(controlCenter, forKey: "cc")
    }
    var current: Speaker? { speakers.first { $0.id == selectedID } ?? speakers.first }
    private func token(_ sp: Speaker) -> String? { Keychain.get(sp.account) }
    func available(_ sp: Speaker) -> Bool { sp.id == current?.id ? online : (reachable[sp.id] ?? false) }
    func refreshNowPlaying() { if controlCenter { nowPlaying.update(self) } else { nowPlaying.stop() } }

    // MARK: accounts & speakers
    func addAccount(token: String) async {
        let acc = Account(id: UUID().uuidString, label: "Account \(accounts.count + 1)")
        Keychain.set(acc.id, token); accounts.append(acc); persist()
        await refreshDevices(acc)
    }
    func replaceToken(_ acc: Account, _ t: String) { Keychain.set(acc.id, t); connect() }
    func removeAccount(_ acc: Account) {
        Keychain.set(acc.id, nil)
        accounts.removeAll { $0.id == acc.id }; speakers.removeAll { $0.account == acc.id }
        persist(); if current == nil { gen += 1; task?.cancel(); online = false; resetState() }; connect()
    }
    func refreshDevices(_ acc: Account) async {
        do {
            for d in try await listDevices(acc) {
                if let i = speakers.firstIndex(where: { $0.id == d.id }) {
                    speakers[i].name = d.name; speakers[i].platform = d.platform; speakers[i].raw = d.raw; speakers[i].account = acc.id
                    if !d.host.isEmpty { speakers[i].host = d.host }
                } else { speakers.append(d) }
            }
            persist(); lastError = ""
            if selectedID.isEmpty, let f = speakers.first { select(f) } else if !online { connect() }
        } catch { lastError = error.localizedDescription }
    }
    private func listDevices(_ acc: Account) async throws -> [Speaker] {
        guard let t = Keychain.get(acc.id) else { throw StationError("Sign in first.") }
        var r = URLRequest(url: URL(string: "https://quasar.yandex.net/glagol/device_list")!)
        r.setValue("Oauth \(t)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw StationError("Speaker list failed (HTTP \(code)).") }
        let list = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["devices"] as? [[String: Any]] ?? []
        return list.compactMap { d in
            guard let id = d["id"] as? String, let p = d["platform"] as? String else { return nil }
            let ips = (d["networkInfo"] as? [String: Any])?["ip_addresses"] as? [String] ?? []
            let ip = ips.first { $0.split(separator: ".").count == 4 } ?? ""
            return Speaker(id: id, name: d["name"] as? String ?? id, platform: p, host: ip, account: acc.id, raw: pretty(d))
        }
    }
    func select(_ sp: Speaker) {
        guard sp.id != current?.id || task == nil else { return }
        selectedID = sp.id; persist(); resetState(); nowPlaying.stop(); connect()
    }
    private func resetState() {
        playing = false; title = ""; subtitle = ""; duration = 0; progress = 0; coverURL = nil
        stateJSON = ""; versionJSON = ""; alice = "IDLE"
    }

    // MARK: availability (TCP-probes the saved IPs)
    func refreshReachability() async {
        let list = speakers.filter { !$0.host.isEmpty }
        let res: [String: Bool] = await withTaskGroup(of: (String, Bool).self) { g in
            for sp in list { g.addTask { (sp.id, await probe(sp.host)) } }
            var r: [String: Bool] = [:]
            for await (id, ok) in g { r[id] = ok }
            return r
        }
        reachable = res
    }
    func monitor() async {
        while !Task.isCancelled { await refreshReachability(); try? await Task.sleep(for: .seconds(15)) }
    }

    // MARK: connection
    func connect() {
        gen += 1; let my = gen
        task?.cancel(with: .goingAway, reason: nil)
        online = false
        guard let sp = current else { status = "Add a Yandex account in Settings"; return }
        guard let tok = token(sp) else { status = "Sign in again in Settings"; return }
        guard !sp.host.isEmpty else { status = "Set the speaker's IP in Settings"; return }
        status = "Connecting…"
        Task {
            do {
                var c = URLComponents(string: "https://quasar.yandex.net/glagol/token")!
                c.queryItems = [.init(name: "device_id", value: sp.id), .init(name: "platform", value: sp.platform)]
                var req = URLRequest(url: c.url!)
                req.setValue("Oauth \(tok)", forHTTPHeaderField: "Authorization")
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 || code == 403 { status = "Token rejected. Sign in again."; return }
                guard code == 200, let conv = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["token"] as? String
                else { throw StationError("Token request failed (HTTP \(code))") }
                guard my == gen else { return }
                convToken = conv
                let s = URLSession(configuration: .default, delegate: TrustAll(), delegateQueue: nil)
                guard let url = URL(string: "wss://\(sp.host):1961") else { throw StationError("Bad speaker address") }
                let t = s.webSocketTask(with: url)
                session = s; task = t; t.resume()
                try await send(["command": "ping"])
                guard my == gen else { return }
                online = true; status = "Online"; lastError = ""
                versionReq = try await send(["command": "softwareVersion"])
                Task { while my == gen { try? await Task.sleep(for: .seconds(10)); if my == gen { cmd(["command": "ping"]) } } }
                while my == gen { handle(try await t.receive()) }
            } catch {
                guard my == gen else { return }
                online = false; status = "Offline"; lastError = error.localizedDescription
                try? await Task.sleep(for: .seconds(5))
                if my == gen { connect() }
            }
        }
    }

    @discardableResult
    private func send(_ payload: [String: Any]) async throws -> String {
        guard let t = task else { throw StationError("Not connected") }
        let id = UUID().uuidString
        let msg: [String: Any] = ["conversationToken": convToken, "id": id, "payload": payload,
                                  "sentTime": Int(Date().timeIntervalSince1970 * 1000)]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: msg), as: UTF8.self)
        addLog(true, json)
        try await t.send(.string(json))
        return id
    }
    private func cmd(_ payload: [String: Any]) {
        Task { do { try await send(payload) } catch { lastError = error.localizedDescription } }
    }

    private func addLog(_ out: Bool, _ s: String) {
        guard !logPaused else { return }
        var t = convToken.isEmpty ? s : s.replacingOccurrences(of: convToken, with: "•••")
        if t.count > 2000 { t = String(t.prefix(2000)) + "…" }
        log.append(LogLine(out: out, text: t))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    private func handle(_ m: URLSessionWebSocketTask.Message) {
        guard case .string(let s) = m else { return }
        addLog(false, s)
        guard let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return }
        if let id = o["id"] as? String, id == versionReq { versionJSON = pretty(o) }
        guard let st = o["state"] as? [String: Any] else { return }
        stateJSON = pretty(st)
        playing = st["playing"] as? Bool ?? false
        if let v = st["volume"] as? Double { volume = v }
        alice = st["aliceState"] as? String ?? "IDLE"
        let p = st["playerState"] as? [String: Any] ?? [:]
        title = p["title"] as? String ?? ""
        subtitle = p["subtitle"] as? String ?? ""
        duration = p["duration"] as? Double ?? 0
        progress = p["progress"] as? Double ?? 0
        stamp = Date()
        var cover: URL?
        if let e = p["extra"] as? [String: Any], let u = e["coverURI"] as? String {
            cover = URL(string: "https://" + u.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "%%", with: "600x600"))
        }
        coverURL = cover
        refreshNowPlaying()
    }

    // MARK: commands
    func play() { nowPlaying.claim(); cmd(["command": "play"]) }
    func pause() { nowPlaying.claim(); cmd(["command": "stop"]) }   // the speaker's "stop" is pause
    func next() { nowPlaying.claim(); cmd(["command": "next"]) }
    func prev() { nowPlaying.claim(); cmd(["command": "prev"]) }
    func seek(_ s: Double) { progress = s; stamp = Date(); cmd(["command": "rewind", "position": s]) }
    func say(_ t: String) { cmd(["command": "sendText", "text": String(t.prefix(300))]) }
    func speak(_ t: String) { say("Повтори за мной " + t) }
    func setVolume(_ v: Double, force: Bool = false) {
        volume = v
        guard force || Date().timeIntervalSince(lastVol) > 0.1 else { return }
        lastVol = Date(); cmd(["command": "setVolume", "volume": v])
    }
    func playTrack(_ t: Track) { nowPlaying.claim(); cmd(["command": "playMusic", "id": t.id, "type": "track"]) }
    func playViaAlice(_ t: Track) { say("Включи \(t.artist) — \(t.title)") }

    func search(_ q: String) async {
        guard let sp = current, let tok = token(sp) else { lastError = "Sign in first."; return }
        searching = true; defer { searching = false }
        var c = URLComponents(string: "https://api.music.yandex.net/search")!
        c.queryItems = [.init(name: "text", value: q), .init(name: "type", value: "track"), .init(name: "page", value: "0")]
        var r = URLRequest(url: c.url!)
        r.setValue("OAuth \(tok)", forHTTPHeaderField: "Authorization")
        r.setValue("YandexMusicAndroid/24023231", forHTTPHeaderField: "X-Yandex-Music-Client")
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw StationError("Search failed (HTTP \(code))") }
            let tracks = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any])?["tracks"] as? [String: Any]
            results = (tracks?["results"] as? [[String: Any]] ?? []).compactMap { t in
                guard let id = (t["id"] as? String) ?? (t["id"] as? Int).map(String.init) else { return nil }
                let artists = (t["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ") ?? ""
                let cover = (t["coverUri"] as? String).flatMap { URL(string: "https://" + $0.replacingOccurrences(of: "%%", with: "200x200")) }
                return Track(id: id, title: t["title"] as? String ?? "", artist: artists, cover: cover,
                             duration: (t["durationMs"] as? Double ?? 0) / 1000)
            }
            lastError = ""
        } catch { lastError = error.localizedDescription }
    }
}
