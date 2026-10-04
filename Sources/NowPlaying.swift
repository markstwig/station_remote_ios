import AVFoundation
import MediaPlayer
import UIKit

/// Makes the speaker show up in Control Center / on the lock screen and routes those controls to it.
/// iOS only treats an app as "Now Playing" while it plays audio, so we loop silence.
@MainActor
final class NowPlaying {
    private var player: AVAudioPlayer?
    private var wired = false
    private var artURL: URL?
    private var art: MPMediaItemArtwork?

    func update(_ s: Station) {
        guard s.controlCenter, s.online, s.playing || !s.title.isEmpty else { stop(); return }
        start(); wire(s)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: s.title,
            MPMediaItemPropertyArtist: s.subtitle,
            MPMediaItemPropertyAlbumTitle: "Yandex Station",
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

    private func wire(_ s: Station) {
        guard !wired else { return }; wired = true
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak s] _ in Task { @MainActor in s?.play() }; return .success }
        c.pauseCommand.addTarget { [weak s] _ in Task { @MainActor in s?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak s] _ in
            Task { @MainActor in if let s { s.playing ? s.pause() : s.play() } }; return .success }
        c.nextTrackCommand.addTarget { [weak s] _ in Task { @MainActor in s?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak s] _ in Task { @MainActor in s?.prev() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak s] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in s?.seek(t) }; return .success }
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

    /// One second of 8 kHz mono 16-bit silence as a WAV file.
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
