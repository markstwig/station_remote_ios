import AVFoundation
import MediaPlayer
import UIKit

/// Makes the speaker show up in Control Center / on the lock screen and routes those controls to it.
/// iOS only treats an app as "Now Playing" while it plays audio, so we loop silence.
///
/// If another app (or a call) takes over audio, iOS tells us via an interruption notification, and we
/// yield: we neither grab audio back nor forward any pause/play that iOS generates around it to the
/// speaker. A real pause from the lock screen / Control Center arrives with no interruption.
@MainActor
final class NowPlaying {
    private var player: AVAudioPlayer?
    private var wired = false
    private var artURL: URL?
    private var art: MPMediaItemArtwork?
    private weak var station: Station?
    private var yielded = false
    private var interruptedAt = Date.distantPast
    private var systemInitiated: Bool { yielded || Date().timeIntervalSince(interruptedAt) < 2 }

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let v = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor in self?.interruption(began: v == AVAudioSession.InterruptionType.began.rawValue) }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            let v = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                if v == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.interruptedAt = Date() }
            }
        }
    }

    private func interruption(began: Bool) {
        if began { yielded = true; interruptedAt = Date(); player = nil }
        else { yielded = false; if let s = station { update(s) } }
    }

    /// The user acted on purpose (opened the app, pressed a control): take audio focus again.
    func claim() { yielded = false }

    func update(_ s: Station) {
        station = s
        guard s.controlCenter, s.online, s.playing || !s.title.isEmpty else { stop(); return }
        if yielded { return }   // another app has audio focus; don't steal it back
        start(); wire(s)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: s.title,
            MPMediaItemPropertyArtist: s.subtitle,
            MPMediaItemPropertyAlbumTitle: s.current?.name ?? "Yandex Station",
            MPMediaItemPropertyPlaybackDuration: s.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: s.progress,
            MPNowPlayingInfoPropertyPlaybackRate: s.playing ? 1.0 : 0.0,
        ]
        if let a = art { info[MPMediaItemPropertyArtwork] = a }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = s.playing ? .playing : .paused
        loadArt(s.coverURL, s)
    }

    func stop() {
        yielded = false
        guard player != nil else { return }
        player?.stop(); player = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func start() {
        if player?.isPlaying == true { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: Self.silence(), fileTypeHint: AVFileType.wav.rawValue)
            p.numberOfLoops = -1; p.play(); player = p
        } catch { }
    }

    /// Runs a lock-screen / Control Center command, unless iOS caused it by an audio interruption.
    private func forward(_ s: Station?, _ action: @MainActor (Station) -> Void) async {
        try? await Task.sleep(for: .milliseconds(400))   // the interruption notice can arrive after the command
        guard let s, !systemInitiated else { return }
        action(s)
    }

    private func wire(_ s: Station) {
        guard !wired else { return }; wired = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self, weak s] _ in Task { @MainActor in await self?.forward(s) { $0.play() } }; return .success }
        c.pauseCommand.addTarget { [weak self, weak s] _ in Task { @MainActor in await self?.forward(s) { $0.pause() } }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self, weak s] _ in
            Task { @MainActor in await self?.forward(s) { if $0.playing { $0.pause() } else { $0.play() } } }; return .success }
        c.nextTrackCommand.addTarget { [weak self, weak s] _ in Task { @MainActor in await self?.forward(s) { $0.next() } }; return .success }
        c.previousTrackCommand.addTarget { [weak self, weak s] _ in Task { @MainActor in await self?.forward(s) { $0.prev() } }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self, weak s] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in await self?.forward(s) { $0.seek(t) } }; return .success }
    }

    private func loadArt(_ url: URL?, _ s: Station) {
        guard url != artURL else { return }
        artURL = url; art = nil
        guard let url else { return }
        Task {
            guard let (d, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: d), url == artURL else { return }
            art = Self.makeArt(img); update(s)
        }
    }

    // nonisolated: MediaPlayer calls the artwork handler on a background queue
    nonisolated static func makeArt(_ img: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }

    /// Two seconds of 8 kHz mono 16-bit silence as a WAV file.
    nonisolated static func silence() -> Data {
        let rate: UInt32 = 8000, n = rate * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(Data("RIFF".utf8)); u32(36 + n); d.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(n); d.append(Data(count: Int(n)))
        return d
    }
}
