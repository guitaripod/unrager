import AVFoundation

/// The app never interrupts other apps' audio. Inline clips autoplay muted under
/// a mixable `.ambient` session; unmuting a clip switches to a `.playback`
/// session (audible with the ring/silent switch on, like X/YouTube) that *also*
/// mixes — so the user's music or podcast keeps playing instead of being paused.
enum MediaAudioSession {
    /// The default, passive session: mixable so muted inline autoplay never
    /// captures the output or pauses whatever the user is already listening to.
    /// Set once at launch.
    static func configureMixable() {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
    }

    /// Switches to playback (audible even on silent) for user-initiated sound,
    /// keeping `.mixWithOthers` so other apps are never interrupted.
    static func activatePlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? session.setActive(true)
    }
}
