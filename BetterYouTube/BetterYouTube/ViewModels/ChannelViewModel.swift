import Foundation

@MainActor
final class ChannelViewModel: ObservableObject {
    @Published private(set) var channel: Channel?
    @Published private(set) var videos: [Video] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let channelId: String
    private let service: YouTubeAPIService

    init(channelId: String, service: YouTubeAPIService = .shared) {
        self.channelId = channelId
        self.service = service
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            async let channelResult = service.channel(id: channelId)
            async let videosResult = service.videos(byChannel: channelId)
            channel = try await channelResult
            videos = try await videosResult
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
