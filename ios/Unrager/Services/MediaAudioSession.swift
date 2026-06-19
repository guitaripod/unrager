import AVFoundation

/// Routes full-screen video through the `.playback` audio session so it's
/// audible even with the ring/silent switch on — matching X/YouTube. The inline
/// autoplay player stays muted on its own; this only affects user-initiated
/// full-screen playback.
enum MediaAudioSession {
    static func activatePlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}
