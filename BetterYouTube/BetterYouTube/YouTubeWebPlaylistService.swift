import Foundation
import WebKit

/// Uses the signed-in YouTube website for playlists the public Data API does not expose, such as
/// saved playlists, system playlists and the account's real Watch Later list.
/// Authentication is computed inside the page; cookie values never cross into Swift or logs.
@MainActor
final class YouTubeWebPlaylistService {
    static let shared = YouTubeWebPlaylistService()
    private let reader = YouTubeFeedReader.playlists
    private var busy = false

    func entries() async throws -> [PlaylistEntry] {
        try await perform(action: "list", videoID: "", playlistID: "WL")
    }

    func videos(inPlaylist playlistID: String) async throws -> [Video] {
        try await perform(action: "list", videoID: "", playlistID: playlistID).map(\.video)
    }

    /// YouTube's playlist aggregation contains owned, saved and system playlists. The public API's
    /// `mine=true` response only contains the first group.
    func playlists() async throws -> [Playlist] {
        try await serialized { session, generation in
            try await self.reader.withPlaylistPage(
                URL(string: "https://www.youtube.com/feed/playlists?hl=en")!
            ) { webView in
                try self.validate(session, generation)
                let result = try await self.call(Self.playlistsScript, arguments: [:], in: webView,
                                                 session: session, generation: generation)
                guard let string = result as? String, let data = string.data(using: .utf8) else {
                    throw YouTubeFeedIssue.loadFailed("YouTube returned an unreadable playlist library.")
                }
                return try JSONDecoder().decode([Playlist].self, from: data)
            }
        }
    }

    /// Read first, so repeated additions are idempotent and removals use YouTube's setVideoId.
    func setSaved(_ saved: Bool, videoID: String) async throws -> [PlaylistEntry] {
        try await perform(action: saved ? "add" : "remove", videoID: videoID, playlistID: "WL")
    }

    private func perform(action: String, videoID: String, playlistID: String) async throws -> [PlaylistEntry] {
        try await serialized { session, generation in
            try await self.reader.withPlaylistPage { webView in
                try self.validate(session, generation)
                let result = try await self.call(
                    Self.script,
                    arguments: ["operation": action, "videoID": videoID, "playlistID": playlistID],
                    in: webView,
                    session: session,
                    generation: generation
                )
                guard let string = result as? String, let data = string.data(using: .utf8) else {
                    throw YouTubeFeedIssue.loadFailed("YouTube returned an unreadable playlist.")
                }
                return try JSONDecoder().decode([PlaylistEntry].self, from: data)
            }
        }
    }

    private func serialized<T>(
        _ operation: (YouTubeWebSession, UUID) async throws -> T
    ) async throws -> T {
        let session = YouTubeWebSession.shared
        let generation = session.feedGeneration
        while busy { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        guard session.isSignedIn, generation == session.feedGeneration else { throw CancellationError() }
        busy = true
        defer { busy = false }
        return try await operation(session, generation)
    }

    private func validate(_ session: YouTubeWebSession, _ generation: UUID) throws {
        guard session.isSignedIn, session.feedGeneration == generation else { throw CancellationError() }
    }

    private func call(
        _ script: String,
        arguments: [String: Any],
        in webView: WKWebView,
        session: YouTubeWebSession,
        generation: UUID
    ) async throws -> Any? {
        do {
            let result = try await webView.callAsyncJavaScript(
                script, arguments: arguments, in: nil, contentWorld: .page
            )
            try validate(session, generation)
            return result
        } catch {
            try validate(session, generation)
            if let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String {
                throw YouTubeFeedIssue.loadFailed(message)
            }
            throw error
        }
    }

    // Arguments are passed by WebKit, never interpolated into executable JavaScript.
    static let authenticationScript = #"""
    if (location.origin !== 'https://www.youtube.com' || !window.ytcfg?.get('LOGGED_IN'))
        throw new Error('Sign in to youtube.com from Settings to access your playlists.');
    const context = ytcfg.get('INNERTUBE_CONTEXT');
    if (!context?.client) throw new Error('YouTube session is not ready. Please retry.');
    const cookie = document.cookie.split(';').map(s => s.trim())
        .find(s => s.startsWith('SAPISID='))?.slice(8);
    if (!cookie) throw new Error('Reconnect to youtube.com from Settings to access your playlists.');
    const stamp = Math.floor(Date.now() / 1000);
    const digest = await crypto.subtle.digest('SHA-1',
        new TextEncoder().encode(stamp + ' ' + cookie + ' ' + location.origin));
    const hash = Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('');
    const headers = {
        'Content-Type': 'application/json',
        'Authorization': 'SAPISIDHASH ' + stamp + '_' + hash,
        'X-Goog-AuthUser': String(ytcfg.get('SESSION_INDEX') || 0),
        'X-Youtube-Client-Name': String(ytcfg.get('INNERTUBE_CONTEXT_CLIENT_NAME') || 1),
        'X-Youtube-Client-Version': context.client.clientVersion
    };
    const pageID = ytcfg.get('DELEGATED_SESSION_ID');
    if (pageID) headers['X-Goog-PageId'] = pageID;
    async function request(endpoint, body) {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 20000);
        try {
            const response = await fetch('/youtubei/v1/' + endpoint + '?prettyPrint=false', {
                method: 'POST', credentials: 'include', headers,
                body: JSON.stringify({context, ...body}), signal: controller.signal
            });
            if (!response.ok) throw new Error('YouTube refused the playlist request (' + response.status + ').');
            const json = await response.json();
            if (json.error || json.alerts?.some(a => a.alertRenderer?.type === 'ERROR'))
                throw new Error('YouTube could not access this playlist. Check your youtube.com account.');
            return json;
        } finally { clearTimeout(timer); }
    }
    """#

    static let script = authenticationScript + operationsScript

    static let operationsScript = #"""
    function find(value, key) {
        if (!value || typeof value !== 'object') return [];
        if (value[key]) return [value[key]];
        return Object.values(value).flatMap(v => find(v, key));
    }
    const text = value => value?.simpleText || value?.content || value?.runs?.map(r => r.text).join('') || '';
    const normalizedID = String(playlistID || 'WL').replace(/^VL/, '');
    async function read() {
        const first = await request('browse', {browseId: 'VL' + normalizedID});
        const lists = find(first.contents, 'playlistVideoListRenderer');
        if (lists.length !== 1)
            throw new Error('YouTube changed its playlist page, or this account cannot access Watch Later.');
        let contents = lists[0].contents || [];
        const entries = [], seen = new Set(), tokens = new Set();
        for (let page = 0; page < 100; page++) {
            for (const item of contents) {
                const v = item.playlistVideoRenderer;
                if (!v?.videoId) continue;
                const itemID = v.setVideoId || v.videoId;
                if (seen.has(itemID)) continue;
                seen.add(itemID);
                const byline = v.shortBylineText || v.longBylineText;
                entries.push({id: itemID, video: {
                    id: v.videoId, title: text(v.title), channelId: byline?.runs?.[0]?.navigationEndpoint?.browseEndpoint?.browseId || '',
                    channelTitle: text(byline), description: '',
                    thumbnailURL: v.thumbnail?.thumbnails?.slice(-1)[0]?.url || null,
                    publishedAt: null, duration: null
                }});
            }
            const continuations = find(contents, 'continuationItemRenderer');
            const token = continuations[0]?.continuationEndpoint?.continuationCommand?.token;
            if (!token) return entries;
            if (tokens.has(token)) throw new Error('YouTube repeated a playlist page. Please retry.');
            tokens.add(token);
            const next = await request('browse', {continuation: token});
            const commands = find(next, 'appendContinuationItemsAction');
            if (commands.length !== 1) throw new Error('YouTube returned an unreadable playlist page.');
            contents = commands[0].continuationItems || [];
        }
        throw new Error('The playlist could not be loaded completely. Please retry.');
    }
    let entries = await read();
    if (operation === 'list') return JSON.stringify(entries);
    if (!/^[a-zA-Z0-9_-]{11}$/.test(videoID)) throw new Error('Invalid video.');
    const existing = entries.filter(e => e.video.id === videoID);
    if ((operation === 'add' && existing.length) || (operation === 'remove' && !existing.length))
        return JSON.stringify(entries);
    const actions = operation === 'add'
        ? [{action: 'ACTION_ADD_VIDEO', addedVideoId: videoID}]
        : existing.map(e => ({action: 'ACTION_REMOVE_VIDEO', setVideoId: e.id}));
    if (normalizedID !== 'WL') throw new Error('This playlist is read-only here.');
    const result = await request('browse/edit_playlist', {playlistId: normalizedID, actions});
    if (result.status !== 'STATUS_SUCCEEDED')
        throw new Error('YouTube did not confirm the change. Refresh Watch Later before retrying.');
    // Confirm the server state; an accepted HTTP response alone is not a successful save.
    entries = await read();
    if (entries.some(e => e.video.id === videoID) !== (operation === 'add'))
        throw new Error('YouTube has not confirmed the updated playlist. Refresh before retrying.');
    return JSON.stringify(entries);
    """#

    static let playlistsScript = authenticationScript + playlistAggregationScript

    static let playlistAggregationScript = #"""
    function find(value, key) {
        if (!value || typeof value !== 'object') return [];
        const own = value[key] ? [value[key]] : [];
        return own.concat(Object.values(value).flatMap(v => find(v, key)));
    }
    const text = value => value?.simpleText || value?.content || value?.runs?.map(r => r.text).join('') || '';
    const thumbnail = value => {
        const lists = [...find(value, 'thumbnails'), ...find(value, 'sources')];
        for (const list of lists) {
            if (Array.isArray(list) && list.length) return list[list.length - 1]?.url || null;
        }
        return null;
    };
    const count = value => {
        const direct = Number(value?.videoCount);
        if (Number.isFinite(direct)) return direct;
        const match = text(value?.videoCountText || value?.videoCountShortText).match(/[\d,. ]+/)?.[0];
        return match ? Number(match.replace(/[^\d]/g, '')) : null;
    };
    function decode(response) {
        const candidates = [
            ...find(response, 'playlistRenderer'),
            ...find(response, 'gridPlaylistRenderer'),
            ...find(response, 'playlistPanelRenderer')
        ];
        for (const lockup of find(response, 'lockupViewModel')) {
            const id = lockup.contentId;
            const kind = lockup.contentType || lockup.contentTypeViewModel?.contentType;
            if (id && (kind === 'LOCKUP_CONTENT_TYPE_PLAYLIST' ||
                /^(PL|OLAK5uy_|WL$|LL$|UU|RD|FL)/.test(id))) candidates.push(lockup);
        }
        return candidates.map(item => {
            const metadata = item.metadata?.lockupMetadataViewModel;
            const id = String(item.playlistId || item.contentId ||
                item.navigationEndpoint?.browseEndpoint?.browseId || '').replace(/^VL/, '');
            const title = text(item.title || metadata?.title);
            if (!id || !title) return null;
            return {
                id, title, description: text(item.descriptionText || item.description),
                thumbnailURL: thumbnail(item), itemCount: count(item),
                channelTitle: text(item.shortBylineText || item.longBylineText || metadata?.metadata)
            };
        }).filter(Boolean);
    }
    let response = await request('browse', {browseId: 'FEplaylist_aggregation'});
    const playlists = [], seen = new Set(), tokens = new Set();
    for (let page = 0; page < 100; page++) {
        for (const playlist of decode(response)) {
            if (seen.has(playlist.id)) continue;
            seen.add(playlist.id);
            playlists.push(playlist);
        }
        const continuation = find(response, 'continuationItemRenderer')[0]
            ?.continuationEndpoint?.continuationCommand?.token;
        if (!continuation) return JSON.stringify(playlists);
        if (tokens.has(continuation)) throw new Error('YouTube repeated a playlist page. Please retry.');
        tokens.add(continuation);
        response = await request('browse', {continuation});
    }
    throw new Error('The playlist library could not be loaded completely. Please retry.');
    """#
}
