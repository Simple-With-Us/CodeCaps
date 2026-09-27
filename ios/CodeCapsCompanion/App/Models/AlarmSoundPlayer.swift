import AVFoundation
import Foundation
import UserNotifications

/// Plays the bundled reset-alarm tone and reports whether it could.
///
/// The iOS settings sheet had no preview control at all, and the picker it did
/// have could not have worked: the `ResetAlarmSound` raw values are macOS
/// system sound names, and `UNNotificationSound(named:)` on iOS resolves only
/// the app's own bundled audio or the default chime.  Every named tone was
/// therefore unresolvable, which meant a real reset alert on the iPhone was
/// silent too.  `scripts/generate-alarm-sounds.py` writes the bundled renditions
/// this type plays.
@MainActor
public final class AlarmSoundPlayer: NSObject, ObservableObject {
    /// Whether the last preview actually produced sound.  Drives the status
    /// line so "nothing happened" is distinguishable from "the tone is silent
    /// by choice".
    @Published public private(set) var lastPreview: PreviewResult?

    public enum PreviewResult: Equatable, Sendable {
        /// A bundled tone played.
        case played(String)
        /// `systemDefault`: there is no bundled file, and the platform chime is
        /// what a real alert plays.  Previewed through the same notification
        /// path so the owner hears what they will actually get.
        case delegatedToSystemDefault
        /// `silent`: the owner asked for no sound.
        case silentByChoice
        /// The bundled file is missing from the app bundle.
        case missingAsset(String)
        /// The audio session could not start the player.
        case failed(String)

        public var isFailure: Bool {
            switch self {
            case .played, .delegatedToSystemDefault, .silentByChoice: return false
            case .missingAsset, .failed: return true
            }
        }

        public var message: String {
            switch self {
            case .played(let name):
                return "Played \(name)."
            case .delegatedToSystemDefault:
                return "Default chime selected." + sentenceGap
                    + "It plays with a real alert."
            case .silentByChoice:
                return "Silent selected." + sentenceGap + "No sound plays."
            case .missingAsset(let name):
                return "Missing bundled tone \(name)." + sentenceGap
                    + "Rebuild the app so the audio is included."
            case .failed(let reason):
                return "Could not play the tone." + sentenceGap + reason
            }
        }
    }

    private var player: AVAudioPlayer?

    public override init() {
        super.init()
    }

    /// Plays `sound` locally, without going through the notification centre.
    ///
    /// The audio session is `.playback` on purpose: a preview is a deliberate
    /// tap, so it stays audible even with the ring switch off.  A real alert
    /// still respects the ringer, because that is the notification system's job
    /// rather than the app's.
    public func preview(_ sound: ResetAlarmSound) {
        lastPreview = play(sound)
    }

    /// The URL of a sound's bundled audio, or `nil` when the sound has none.
    public static func assetURL(for sound: ResetAlarmSound) -> URL? {
        guard let name = sound.bundledAssetName else { return nil }
        return Bundle.main.url(forResource: name,
                               withExtension: ResetAlarmSound.bundledAssetExtension)
    }

    /// The `UNNotificationSound` a real iOS alert should carry for `sound`.
    ///
    /// This is the fix for the silent-alert bug: a bundled file on iOS, the
    /// platform chime for `systemDefault`, and no sound for `silent`.
    public static func notificationSound(for sound: ResetAlarmSound) -> UNNotificationSound? {
        switch sound {
        case .silent:
            return nil
        case .systemDefault:
            return .default
        default:
            guard let name = sound.bundledAssetName else { return nil }
            return UNNotificationSound(named: UNNotificationSoundName(
                "\(name).\(ResetAlarmSound.bundledAssetExtension)"))
        }
    }

    private func play(_ sound: ResetAlarmSound) -> PreviewResult {
        switch sound {
        case .silent:
            return .silentByChoice
        case .systemDefault:
            // No bundled file by design.  The platform chime is what a real
            // alert makes, so the test notification is the honest preview.
            return .delegatedToSystemDefault
        default:
            break
        }

        guard let name = sound.bundledAssetName else { return .silentByChoice }
        guard let url = Self.assetURL(for: sound) else { return .missingAsset(name) }

        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            #endif

            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.prepareToPlay()
            newPlayer.play()
            player = newPlayer
            return .played(name)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
