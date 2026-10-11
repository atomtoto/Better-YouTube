import SwiftUI

/// Handoff: the video playing here, offered to your other devices.
///
/// Pause on the iPhone and the Mac's Dock shows the app at once, ready to carry on from the same
/// second; the positions iCloud syncs arrive later and only say where you stopped. A device
/// without the app gets the youtube.com page at that moment instead, in its browser.
enum Handoff {
    /// Declared under `NSUserActivityTypes` in both Info.plists.
    static let watchingActivity = "com.atomtoto.BetterYouTube.watching"

    private static let videoKey = "video"
    private static let timeKey = "time"

    /// Fills in what the other device needs. Called by SwiftUI whenever the activity is about to
    /// be handed over, so the time is the one on screen at that moment.
    @MainActor
    static func describe(_ activity: NSUserActivity, player: PlayerManager) {
        guard let video = player.currentVideo else { return }
        let time = player.progress.currentTime
        activity.title = video.title
        activity.isEligibleForHandoff = true
        activity.webpageURL = YouTubeLink.video(id: video.id, start: time >= 1 ? time : nil).webURL
        var info: [String: Any] = [timeKey: time]
        if let data = try? JSONEncoder().encode(video) { info[videoKey] = data }
        activity.userInfo = info
    }

    /// Plays what another device was playing, from where it was.
    @MainActor
    static func continueActivity(_ activity: NSUserActivity, player: PlayerManager) {
        let time = activity.userInfo?[timeKey] as? Double
        if let data = activity.userInfo?[videoKey] as? Data,
           let video = try? JSONDecoder().decode(Video.self, from: data) {
            player.play(video, startTime: time)
        } else if let url = activity.webpageURL, case .video(let id, let start) = YouTubeLink(url: url) {
            Task { await player.open(videoId: id, startTime: start) }
        }
    }
}

extension View {
    /// Offers the playing video to the account's other devices, and takes one offered by them.
    func handsOffPlayback(_ player: PlayerManager) -> some View {
        userActivity(Handoff.watchingActivity, isActive: player.currentVideo != nil) { activity in
            Handoff.describe(activity, player: player)
        }
        .onContinueUserActivity(Handoff.watchingActivity) { activity in
            Handoff.continueActivity(activity, player: player)
        }
    }
}
