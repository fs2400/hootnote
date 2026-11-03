import AVFoundation
import SwiftUI

/// Plays a meeting: its levelled mix (playback.m4a), or for a meeting still waiting for one, the two
/// tracks (you + the call) mixed together.
@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isLoaded = false
    @Published var rate: Float = 1 {
        didSet { if isPlaying { player?.rate = rate } }
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadedID: UUID?
    private var loadedVersion = -1

    /// - Parameter version: bumped when the meeting's audio is rebuilt; a new version reloads.
    func load(_ meeting: Meeting, version: Int = 0) async {
        guard loadedID != meeting.id || loadedVersion != version else { return }
        let resume = loadedID == meeting.id ? currentTime : nil
        let resumePlaying = loadedID == meeting.id && isPlaying
        unload()
        loadedID = meeting.id
        loadedVersion = version
        let composition = AVMutableComposition()
        let mixed = FileManager.default.fileExists(atPath: meeting.playbackURL.path)
        let sources = mixed ? [meeting.playbackURL] : AudioTrack.allCases.compactMap { meeting.audioURL($0) }
        for url in sources {
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let length = try? await asset.load(.duration),
                  let destination = composition.addMutableTrack(withMediaType: .audio,
                                                                preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try? destination.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: .zero)
        }
        guard loadedID == meeting.id else { return }
        let item = AVPlayerItem(asset: composition)
        item.audioTimePitchAlgorithm = .timeDomain // natural-sounding speech at 1.5x / 2x
        let player = AVPlayer(playerItem: item)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.currentTime = time.seconds }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
        self.player = player
        duration = composition.duration.seconds.isFinite ? composition.duration.seconds : 0
        isLoaded = duration > 0
        if let resume { seek(to: resume) }
        if resumePlaying { play() }
    }

    func unload() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        loadedID = nil
        loadedVersion = -1
        isPlaying = false
        isLoaded = false
        currentTime = 0
        duration = 0
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        if currentTime >= duration - 0.25 { seek(to: 0) }
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let t = min(max(0, seconds), max(duration, 0))
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = t
    }

    func skip(_ delta: Double) { seek(to: currentTime + delta) }
}

struct PlayerBar: View {
    @ObservedObject var player: PlayerModel

    var body: some View {
        VStack(spacing: 0) {
            HairlineRule()
            HStack(spacing: 14) {
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    .help("Back 15 seconds")
                    .accessibilityLabel("Back 15 seconds")
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 20)
                }
                .help(player.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                    .help("Forward 15 seconds")
                    .accessibilityLabel("Forward 15 seconds")
                Text(player.currentTime.clockString)
                    .font(Theme.timeRow)
                    .foregroundStyle(player.isPlaying ? Theme.signal : Theme.ink)
                    .frame(width: 56, alignment: .trailing)
                Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                       in: 0...max(player.duration, 1))
                    .tint(player.isPlaying ? Theme.signal : Theme.ink)
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(player.currentTime.clockString) of \(player.duration.clockString)")
                Text(player.duration.clockString)
                    .font(Theme.timeRow)
                    .foregroundStyle(Theme.inkSecondary)
                    .frame(width: 56, alignment: .leading)
                Picker("Speed", selection: $player.rate) {
                    Text("1×").tag(Float(1))
                    Text("1.25×").tag(Float(1.25))
                    Text("1.5×").tag(Float(1.5))
                    Text("2×").tag(Float(2))
                }
                .labelsHidden()
                .frame(width: 72)
                .help("Playback speed")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.ink)
            .disabled(!player.isLoaded)
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 10)
        }
        .background(Theme.ground)
    }
}
