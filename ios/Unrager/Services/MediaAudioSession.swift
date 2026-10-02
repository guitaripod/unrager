import AVFoundation

/// Inline clips never interrupt other apps' audio: they autoplay muted under a
/// mixable `.ambient` session, and unmuting one switches to a `.playback`
/// session (audible with the ring/silent switch on, like X/YouTube) that still
/// mixes, so the user's music or podcast keeps playing. A video opened full
/// screen is something the user chose to watch, so it ducks other audio for as
/// long as it is up; closing it, or muting inline sound again, hands the audio
/// back to the other app and returns to the passive session.
enum MediaAudioSession {
    /// The default, passive session: mixable so muted inline autoplay never
    /// captures the output or pauses whatever the user is already listening to.
    /// Set at launch and restored by `deactivate()`.
    static func configureMixable() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
    }

    /// Switches to playback (audible even on silent) for inline sound the user
    /// turned on, keeping `.mixWithOthers` so other apps are never interrupted.
    static func activatePlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    /// Playback for the full-screen player: other apps' audio is ducked under
    /// the clip's soundtrack instead of playing over it at full volume.
    static func activateFullScreen() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.duckOthers])
        try? session.setActive(true)
    }

    /// Ends app sound: tells other apps they may resume at full volume and
    /// returns to the passive mixable session.
    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        configureMixable()
    }
}
