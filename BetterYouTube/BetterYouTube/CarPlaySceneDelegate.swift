#if os(iOS)
import CarPlay
import Combine
import CoreMedia
import UIKit

/// CarPlay uses the same library and player as the phone, including on a cold launch.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
    CPSessionConfigurationDelegate, @preconcurrency CPNowPlayingTemplateObserver {
    private var interfaceController: CPInterfaceController?
    private var observations = Set<AnyCancellable>()
    private var pendingRefresh: Task<Void, Never>?
    private var libraryRefresh: Task<Void, Never>?
    private var lists: [CPListTemplate] = []
    private var queueTemplate: CPListTemplate?
    private var sessionConfiguration: CPSessionConfiguration?
    private var supportsVideo: Bool {
        if #available(iOS 27.0, *) { return sessionConfiguration?.supportsVideoPlayback == true }
        return false
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        sessionConfiguration = CPSessionConfiguration(delegate: self)
        PlayerManager.shared.setCarPlayConnected(true, supportsVideo: supportsVideo)
        lists = [
            makeList("Favorites", symbol: "heart.fill"),
            makeList("Watch Later", symbol: "clock.fill"),
            makeList("History", symbol: "clock.arrow.circlepath"),
            makeList("Downloads", symbol: "arrow.down.circle.fill")
        ]
        updateLists()
        interfaceController.setRootTemplate(CPTabBarTemplate(templates: lists), animated: false,
                                            completion: nil)
        CPNowPlayingTemplate.shared.add(self)
        observeLibrary()
        refreshLibrary()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        CPNowPlayingTemplate.shared.remove(self)
        observations.removeAll()
        pendingRefresh?.cancel()
        libraryRefresh?.cancel()
        self.interfaceController = nil
        lists = []
        queueTemplate = nil
        sessionConfiguration = nil
        // Keep the current native playback and its queue alive when the car disconnects.
        PlayerManager.shared.setCarPlayConnected(false)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        refreshLibrary()
    }

    private func refreshLibrary() {
        libraryRefresh?.cancel()
        libraryRefresh = Task {
            await ICloudSyncService.shared.syncNow()
            guard !Task.isCancelled else { return }
            await WatchLaterStore.shared.refresh()
        }
    }

    private func makeList(_ title: String, symbol: String) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.tabTitle = title
        template.tabImage = UIImage(systemName: symbol)
        template.emptyViewTitleVariants = ["No items"]
        template.emptyViewSubtitleVariants = ["Add items in Better YouTube on your iPhone."]
        template.trailingNavigationBarButtons = [CPBarButton(title: "Now Playing") { [weak self] _ in
            self?.showNowPlaying()
        }]
        return template
    }

    private func observeLibrary() {
        let player = PlayerManager.shared
        let stores = [LibraryStore.shared.objectWillChange.eraseToAnyPublisher(),
                      WatchLaterStore.shared.objectWillChange.eraseToAnyPublisher(),
                      DownloadStore.shared.objectWillChange.eraseToAnyPublisher(),
                      player.objectWillChange.eraseToAnyPublisher()]
        for changes in stores {
            changes.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observations)
        }
        player.progress.$currentTime.throttle(for: .seconds(5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observations)
        player.progress.$duration.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observations)
        player.$issue.compactMap { $0 }.sink { [weak self] issue in
            Task { @MainActor [weak self] in self?.showPlaybackIssue(issue) }
        }.store(in: &observations)
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            // @Published emits before the store has installed the new value.
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.updateLists()
        }
    }

    private func updateLists() {
        let library = LibraryStore.shared
        let watchLater = WatchLaterStore.shared
        let downloads = DownloadStore.shared
        let collections = [library.favorites, watchLater.videos, library.history,
                           downloads.records.filter { downloads.readyMediaURL(for: $0.video.id) != nil }.map(\.video)]
        for (template, videos) in zip(lists, collections) {
            template.updateSections(sections(for: videos))
            template.trailingNavigationBarButtons.first?.isEnabled = PlayerManager.shared.currentVideo != nil
        }
        if lists.count > 1 {
            lists[1].emptyViewTitleVariants = [watchLater.isLoading ? "Loading…" : "No items"]
            lists[1].emptyViewSubtitleVariants = [watchLater.errorMessage
                ?? "Add items in Better YouTube on your iPhone."]
        }
        queueTemplate?.updateSections(sections(for: PlayerManager.shared.upNext))
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled = !PlayerManager.shared.upNext.isEmpty
    }

    private func sections(for videos: [Video]) -> [CPListSection] {
        // CarPlay sets limits for the current vehicle. Queue only the visible collection.
        let visible = Array(videos.prefix(CPListTemplate.maximumItemCount))
        let presentsVideo = supportsVideo
        let items = visible.map { video in
            let item = CPListItem(text: video.title, detailText: video.channelTitle,
                                  image: UIImage(systemName: presentsVideo ? "play.rectangle.fill" : "music.note"))
            item.isPlaying = PlayerManager.shared.currentVideo?.id == video.id
            if #available(iOS 26.4, *) {
                let player = PlayerManager.shared
                let current = player.currentVideo?.id == video.id
                let saved = PlaybackPositionStore.shared.position(for: video.id)
                let elapsed = current ? player.progress.currentTime : (saved?.seconds ?? 0)
                let duration = current ? player.progress.duration : (saved?.duration ?? 0)
                item.playbackConfiguration = CPPlaybackConfiguration(
                    preferredPresentation: presentsVideo ? .video : .audio,
                    playbackAction: .play,
                    elapsedTime: CMTime(seconds: elapsed, preferredTimescale: 600),
                    duration: CMTime(seconds: duration, preferredTimescale: 600))
            }
            item.handler = { [weak self] _, completion in
                PlayerManager.shared.play(video, upNext: visible.after(video),
                                          audioOnly: !presentsVideo, carPlayVideo: presentsVideo)
                completion()
                // The playback configuration lets CarPlay present video and enforce park policy.
                if !presentsVideo { self?.showNowPlaying() }
            }
            return item
        }
        return items.isEmpty ? [] : [CPListSection(items: items)]
    }

    private func showNowPlaying() {
        guard PlayerManager.shared.currentVideo != nil, let interfaceController else { return }
        let template = CPNowPlayingTemplate.shared
        // Return to the existing template when a queue row is selected.
        if interfaceController.templates.contains(where: { $0 === template }) {
            interfaceController.pop(to: template, animated: true, completion: nil)
        } else {
            interfaceController.pushTemplate(template, animated: true, completion: nil)
        }
    }

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        let template = CPListTemplate(title: "Up Next", sections: sections(for: PlayerManager.shared.upNext))
        template.emptyViewTitleVariants = ["The queue is empty"]
        queueTemplate = template
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func showPlaybackIssue(_ issue: PlaybackIssue) {
        guard let interfaceController, interfaceController.presentedTemplate == nil else { return }
        let message: String
        switch issue {
        case .loadFailed(let reason): message = reason
        case .playerError: message = "This item cannot be played."
        case .noResponse: message = "The player did not respond."
        }
        let dismiss = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
        interfaceController.presentTemplate(CPAlertTemplate(titleVariants: [message], actions: [dismiss]),
                                            animated: true, completion: nil)
    }
}
#endif
