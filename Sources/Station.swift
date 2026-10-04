import Foundation
import Observation

struct StationError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct Device: Identifiable { let id: String; let platform: String; let name: String; let ip: String? }

enum Keychain {
    private static var base: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: "yandex-oauth"] }
    static func get() -> String? {
        var q = base; q[kSecReturnData as String] = true
        var r: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data { return String(data: d, encoding: .utf8) }
        return UserDefaults.standard.string(forKey: "tok-fallback")
    }
    static func set(_ v: String?) {
        SecItemDelete(base as CFDictionary)
        UserDefaults.standard.removeObject(forKey: "tok-fallback")
        guard let v else { return }
        var q = base; q[kSecValueData as String] = Data(v.utf8)
        if SecItemAdd(q as CFDictionary, nil) != errSecSuccess { UserDefaults.standard.set(v, forKey: "tok-fallback") }
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

@MainActor @Observable
final class Station {
    var host: String, deviceId: String, platform: String, controlCenter: Bool, hasToken: Bool
    var status = "Starting…", lastError = ""
    var online = false, playing = false, volume = 0.0, alice = "IDLE"
    var title = "", subtitle = "", duration = 0.0, progress = 0.0, stamp = Date(), coverURL: URL?

    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var convToken = ""
    @ObservationIgnored private var gen = 0
    @ObservationIgnored private var lastVol = Date.distantPast
    @ObservationIgnored let nowPlaying = NowPlaying()

    init() {
        let d = UserDefaults.standard
        host = d.string(forKey: "host") ?? ""
        deviceId = d.string(forKey: "id") ?? ""
        platform = d.string(forKey: "plat") ?? "yandexmidi"
        controlCenter = d.object(forKey: "cc") as? Bool ?? true
        hasToken = Keychain.get() != nil
    }

    private var token: String? { Keychain.get() }
    func setToken(_ t: String?) { Keychain.set(t); hasToken = t != nil; connect() }
    func saveSettings() {
        let d = UserDefaults.standard
        d.set(host, forKey: "host"); d.set(deviceId, forKey: "id"); d.set(platform, forKey: "plat"); d.set(controlCenter, forKey: "cc")
    }
    func refreshNowPlaying() { if controlCenter { nowPlaying.update(self) } else { nowPlaying.stop() } }

    // MARK: connection
    func connect() {
        gen += 1; let my = gen
        task?.cancel(with: .goingAway, reason: nil)
        online = false
        guard let tok = token else { status = "Sign in to Yandex in Settings"; return }
        guard !host.isEmpty, !deviceId.isEmpty else { status = "Choose a speaker in Settings"; return }
        status = "Connecting…"
        Task {
            do {
                var c = URLComponents(string: "https://quasar.yandex.net/glagol/token")!
                c.queryItems = [.init(name: "device_id", value: deviceId), .init(name: "platform", value: platform)]
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
                guard let url = URL(string: "wss://\(host):1961") else { throw StationError("Bad speaker address") }
                let t = s.webSocketTask(with: url)
                session = s; task = t; t.resume()
                try await send(["command": "ping"])
                guard my == gen else { return }
                online = true; status = "Online"; lastError = ""
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

    private func send(_ payload: [String: Any]) async throws {
        guard let t = task else { throw StationError("Not connected") }
        let msg: [String: Any] = ["conversationToken": convToken, "id": UUID().uuidString, "payload": payload,
                                  "sentTime": Int(Date().timeIntervalSince1970 * 1000)]
        let json = try JSONSerialization.data(withJSONObject: msg)
        try await t.send(.string(String(decoding: json, as: UTF8.self)))
    }
    private func cmd(_ payload: [String: Any]) {
        Task { do { try await send(payload) } catch { lastError = error.localizedDescription } }
    }

    private func handle(_ m: URLSessionWebSocketTask.Message) {
        guard case .string(let s) = m,
              let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
              let st = o["state"] as? [String: Any] else { return }
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
    func play() { cmd(["command": "play"]) }
    func pause() { cmd(["command": "stop"]) }   // the speaker's "stop" is pause
    func next() { cmd(["command": "next"]) }
    func prev() { cmd(["command": "prev"]) }
    func seek(_ s: Double) { progress = s; stamp = Date(); cmd(["command": "rewind", "position": s]) }
    func say(_ t: String) { cmd(["command": "sendText", "text": String(t.prefix(300))]) }
    func speak(_ t: String) { say("Повтори за мной " + t) }
    func setVolume(_ v: Double, force: Bool = false) {
        volume = v
        guard force || Date().timeIntervalSince(lastVol) > 0.1 else { return }
        lastVol = Date(); cmd(["command": "setVolume", "volume": v])
    }

    func listDevices() async throws -> [Device] {
        guard let t = token else { throw StationError("Sign in first.") }
        var r = URLRequest(url: URL(string: "https://quasar.yandex.net/glagol/device_list")!)
        r.setValue("Oauth \(t)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw StationError("Speaker list failed (HTTP \(code)). Enter the details by hand.") }
        let list = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["devices"] as? [[String: Any]] ?? []
        return list.compactMap { d in
            guard let id = d["id"] as? String, let p = d["platform"] as? String else { return nil }
            let ips = (d["networkInfo"] as? [String: Any])?["ip_addresses"] as? [String] ?? []
            return Device(id: id, platform: p, name: d["name"] as? String ?? id, ip: ips.first { $0.split(separator: ".").count == 4 })
        }
    }
}
