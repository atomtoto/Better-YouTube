import Foundation

/// Builds the embed page with the state of the playback that requested it.
enum PlayerShell {
    static let baseURL = URL(string: "https://www.youtube-nocookie.com")!

    static func render(videoID: String, startTime: Double, playbackID: String,
                       autoplay: Bool, muted: Bool, controls: String) -> String {
        html
            .replacingOccurrences(of: "__VIDEO_ID__", with: videoID)
            .replacingOccurrences(of: "__START_SECONDS__", with: String(startTime))
            .replacingOccurrences(of: "__PLAYBACK_ID__", with: playbackID)
            .replacingOccurrences(of: "__AUTOPLAY__", with: String(autoplay))
            .replacingOccurrences(of: "__MUTED__", with: String(muted))
            .replacingOccurrences(of: "__CHROME__", with: controls)
    }

    /// A plain `youtube-nocookie.com/embed` iframe — the same embed that plays reliably in a
    /// `WKWebView`. Control and state ride on the embed's `enablejsapi` postMessage protocol, so
    /// nothing depends on loading YouTube's IFrame API script into a `loadHTMLString` document,
    /// whose origin the API rejects (playback failed with error 152).
    ///
    /// `rel=1` matters more than it looks: `rel=0` confines the end screen to more from the same
    /// channel, while `rel=1` leaves YouTube's own related videos there. Since the Data API
    /// retired every recommendation endpoint it had, that panel is the one place in the app
    /// where YouTube's real suggestions show up.
    private static let html = """
    <!DOCTYPE html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
      <style>
        html, body { margin: 0; padding: 0; background: #000; height: 100%; overflow: hidden; }
        #frame { position: absolute; top: 0; left: 0; width: 100%; height: 100%; border: 0; }
      </style>
    </head>
    <body>
      <iframe id="frame"
        allow="accelerometer; autoplay; encrypted-media; fullscreen; gyroscope; picture-in-picture"
        allowfullscreen>
      </iframe>
      <script>
        var frame = document.getElementById('frame');
        var handshake;
        // The ID of the video this page is playing. Never an element: the full-screen code
        // keeps its video element in `fullScreenVideo`, and sharing one variable between the
        // two used to stamp a DOM node onto outgoing reports as their `videoID`.
        var watchedVideo;
        var fullScreenVideo;
        var reportedVideoID;
        var playbackID;
        var pendingStartSeconds = 0;
        var playing = false;
        // Set once the video has reached its end, which is when YouTube's own suggestions are up
        // and one of them can be picked.
        var reachedEnd = false;
        // Whether the video starts as it loads. Off only for a paused video coming back from
        // the background.
        var startsPlaying = true;
        // Whether the video starts muted, while the app's own player still carries the sound.
        var startsMuted = false;
        var lastReport = '';
        var chapterCache = null;
        var controlsShown = false;
        // Whose controls are over the video: 'app', the app's own, drawn over this page with
        // YouTube's hidden underneath; 'youTube', YouTube's own, left showing; 'system', WebKit's
        // own on the video element, as in Safari — a Mac's.
        var chrome = '__CHROME__';
        // Whether YouTube's layer is showing for an ad or its end screen.
        var youTubeLayerShown = false;

        function post(message) {
          message.videoID = reportedVideoID || watchedVideo;
          message.playbackID = playbackID;
          try { window.webkit.messageHandlers.player.postMessage(message); } catch (e) {}
        }

        function send(message) {
          try { frame.contentWindow.postMessage(JSON.stringify(message), '*'); } catch (e) {}
        }

        function command(func, args) {
          send({ event: 'command', func: func, args: args || [] });
        }

        function setVideo(id, seconds, sessionID, autoplay, muted) {
          clearInterval(handshake);
          startsPlaying = autoplay !== false;
          startsMuted = muted === true;
          watchedVideo = id;
          fullScreenVideo = null;
          reportedVideoID = null;
          playbackID = sessionID;
          pendingStartSeconds = seconds || 0;
          playing = false;
          reachedEnd = false;
          lastReport = '';
          chapterCache = null;
          // A fresh iframe gives each playback its own message source. Reports still in flight
          // from the previous video cannot overwrite this video's checkpoint.
          var nextFrame = frame.cloneNode(false);
          installHandshake(nextFrame);
          nextFrame.src = 'https://www.youtube-nocookie.com/embed/' + id +
            '?enablejsapi=1&playsinline=1&rel=1&modestbranding=1&controls=1&start=' +
            Math.floor(pendingStartSeconds);
          frame.replaceWith(nextFrame);
          frame = nextFrame;
        }

        // Full screen, in the two forms iOS offers, best first.
        //
        // The embed's own video element, when it can be reached, goes to the *system's* video
        // player: iOS draws the transport, the AirPlay and picture-in-picture buttons and the
        // Done button itself, which is the full screen the phone gives every other video. When
        // it can't be reached, the iframe goes into WebKit's element full screen instead —
        // still a real full-screen window over the app, drawn by the system, but with the
        // embed's own controls inside it.

        function embedDocument() {
          try { return frame.contentDocument || null; } catch (e) { return null; }
        }

        function videoElement() {
          var doc = embedDocument();
          return doc ? doc.querySelector('video') : null;
        }

        function reportFullScreen(active) {
          post({ type: 'fullscreen', state: active ? 1 : 0 });
        }

        // The system player reports its own comings and goings on the video element; the app
        // needs them to know when Done was tapped.
        function watch(video) {
          if (fullScreenVideo === video) { return; }
          fullScreenVideo = video;
          video.addEventListener('webkitbeginfullscreen', function () { reportFullScreen(true); });
          video.addEventListener('webkitendfullscreen', function () { reportFullScreen(false); });
        }

        function enterElementFullScreen() {
          var request = frame.requestFullscreen || frame.webkitRequestFullscreen;
          if (!request) { return; }
          try { request.call(frame); } catch (e) {}
        }

        // `mayFallBack` is the app's last ask of a run: settle for the iframe's full screen
        // rather than leave the video where it is.
        function enterFullScreen(mayFallBack) {
          var video = videoElement();
          var enter = video && originalFullScreen(video, 'webkitEnterFullscreen');
          if (enter) {
            watch(video);
            if (video.webkitDisplayingFullscreen) { return; }
            try { enter.call(video); return; } catch (e) {}
          }
          // An embed we can't see into will never hand over its video element, so there is
          // nothing to wait for. One we can see into is still booting, and the app asks again
          // in a moment.
          if (mayFallBack || !embedDocument()) { enterElementFullScreen(); }
        }

        function exitFullScreen() {
          var video = fullScreenVideo || videoElement();
          if (video && video.webkitDisplayingFullscreen) {
            try { video.webkitExitFullscreen(); } catch (e) {}
            return;
          }
          var exit = document.exitFullscreen || document.webkitExitFullscreen;
          if (exit && (document.fullscreenElement || document.webkitFullscreenElement)) {
            try { exit.call(document); } catch (e) {}
          }
        }

        function fullScreenDidChange() {
          reportFullScreen(!!(document.fullscreenElement || document.webkitFullscreenElement));
        }

        document.addEventListener('fullscreenchange', fullScreenDidChange);
        document.addEventListener('webkitfullscreenchange', fullScreenDidChange);

        // The embed's own player object. This page is loaded with the embed's origin as its base
        // URL, so the player inside the iframe can be reached directly — and with it everything
        // YouTube's gear menu offers that the postMessage protocol doesn't: quality, caption
        // tracks and their translations, audio tracks, and the chapters of the progress bar.
        function moviePlayer() {
          var doc = embedDocument();
          return doc ? doc.getElementById('movie_player') : null;
        }

        // YouTube's own controls stay under the app's, hidden — except while they are the only way
        // to do something: skipping an ad, or picking one of YouTube's suggestions at the end — or
        // when they are the ones chosen. Captions move up out of the way of the app's controls
        // while those are showing. Under the system's controls, the clicks go through YouTube's
        // layer to the video element, whose controls they are.
        var embedStyle =
          'html:not(.by-youtube-layer) #player-controls,' +
          'html:not(.by-youtube-layer) #bottom-sheet-wrapper,' +
          'html:not(.by-youtube-layer) .ytp-chrome-top,' +
          'html:not(.by-youtube-layer) .ytp-chrome-bottom,' +
          'html:not(.by-youtube-layer) .ytp-gradient-top,' +
          'html:not(.by-youtube-layer) .ytp-gradient-bottom,' +
          'html:not(.by-youtube-layer) .ytp-pause-overlay,' +
          'html:not(.by-youtube-layer) .ytp-large-play-button,' +
          'html:not(.by-youtube-layer) .ytp-spinner,' +
          'html:not(.by-youtube-layer) .ytp-watermark { display: none !important; }' +
          '.ytp-caption-window-container { transition: transform 0.2s ease; }' +
          'html.by-controls-shown:not(.by-youtube-layer) .ytp-caption-window-container {' +
          ' transform: translateY(-44px); }' +
          'html.by-native-controls #movie_player * { pointer-events: none !important; }' +
          'html.by-native-controls #movie_player video { pointer-events: auto !important; }';

        function prepareEmbed(doc, showsYouTubeLayer) {
          youTubeLayerShown = showsYouTubeLayer;
          if (!doc.getElementById('by-style')) {
            var style = doc.createElement('style');
            style.id = 'by-style';
            style.textContent = embedStyle;
            (doc.head || doc.documentElement).appendChild(style);
          }
          routeFullScreenToApp(doc);
          // An ad or the end screen gets YouTube's layer whoever's controls are chosen: it is the
          // only way to skip the ad or pick a suggestion.
          var native = chrome === 'system' && !showsYouTubeLayer;
          doc.documentElement.classList.toggle('by-youtube-layer', showsYouTubeLayer || chrome === 'youTube');
          doc.documentElement.classList.toggle('by-native-controls', native);
          doc.documentElement.classList.toggle('by-controls-shown', controlsShown);
          var video = doc.querySelector('video');
          if (video) { setNativeControls(video, native); }
        }

        function setChrome(value) {
          chrome = value;
          var doc = embedDocument();
          if (doc && doc.documentElement) { prepareEmbed(doc, youTubeLayerShown); }
        }

        // WebKit's controls on YouTube's video element. Their clicks stop at the video: YouTube
        // listens for clicks on its player too, and would undo every play or pause.
        function setNativeControls(video, on) {
          if (video.controls !== on) { video.controls = on; }
          if (!on || video.byNativeControls) { return; }
          video.byNativeControls = true;
          ['click', 'dblclick', 'mousedown', 'mouseup', 'pointerdown', 'pointerup', 'contextmenu']
            .forEach(function (type) {
              video.addEventListener(type, function (event) {
                if (video.controls) { event.stopPropagation(); }
              });
            });
        }

        // YouTube's own full-screen button, its double click and its F key ask for full screen
        // here. With YouTube's controls chosen, the app's full screen is what they get — the phone
        // turning, the Mac's window going full screen — rather than a second one of WebKit's.
        // The originals stay at hand for the app's own requests: see `enterFullScreen`.
        var fullScreenMethods = {
          Element: ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen'],
          HTMLVideoElement: ['webkitEnterFullscreen', 'webkitEnterFullScreen']
        };

        function routeFullScreenToApp(doc) {
          var win = doc.defaultView;
          if (!win || win.byOriginalFullScreen) { return; }
          win.byOriginalFullScreen = {};
          Object.keys(fullScreenMethods).forEach(function (type) {
            var prototype = win[type] && win[type].prototype;
            if (!prototype) { return; }
            fullScreenMethods[type].forEach(function (name) {
              var original = prototype[name];
              if (typeof original !== 'function') { return; }
              win.byOriginalFullScreen[name] = original;
              prototype[name] = function () {
                if (chrome !== 'youTube') { return original.apply(this, arguments); }
                post({ type: 'fullScreenRequest' });
                return win.Promise ? win.Promise.resolve() : undefined;
              };
            });
          });
        }

        function originalFullScreen(video, name) {
          var win = video.ownerDocument && video.ownerDocument.defaultView;
          var original = win && win.byOriginalFullScreen && win.byOriginalFullScreen[name];
          if (original) { return original; }
          return typeof video[name] === 'function' ? video[name] : null;
        }

        function setControlsShown(shown) {
          controlsShown = shown;
          var doc = embedDocument();
          if (doc) { doc.documentElement.classList.toggle('by-controls-shown', shown); }
        }

        function textOf(value) {
          if (!value) { return ''; }
          if (value.simpleText) { return value.simpleText; }
          if (value.runs) { return value.runs.map(function (run) { return run.text; }).join(''); }
          return '';
        }

        function findKey(node, key, depth) {
          if (!node || typeof node !== 'object' || depth > 24) { return null; }
          if (Array.isArray(node)) {
            for (var i = 0; i < node.length; i++) {
              var inItem = findKey(node[i], key, depth + 1);
              if (inItem) { return inItem; }
            }
            return null;
          }
          if (node[key]) { return node[key]; }
          for (var name in node) {
            var found = findKey(node[name], key, depth + 1);
            if (found) { return found; }
          }
          return null;
        }

        // The chapters YouTube's progress bar is split into, from the same response it draws them
        // from: the ones written in the description first, then YouTube's automatic ones.
        function chapters(player) {
          if (chapterCache && chapterCache.video === watchedVideo) { return chapterCache.list; }
          var response = null;
          try { response = player.getWatchNextResponse && player.getWatchNextResponse(); } catch (e) {}
          if (!response) { return []; }
          var markers = findKey(response, 'markersMap', 0) || [];
          var rank = function (marker) {
            return marker.key === 'DESCRIPTION_CHAPTERS' ? 0 : (marker.key === 'AUTO_CHAPTERS' ? 1 : 2);
          };
          var lists = markers.filter(function (marker) {
            return marker && marker.value && Array.isArray(marker.value.chapters);
          }).sort(function (a, b) { return rank(a) - rank(b); });
          var list = [];
          if (lists.length) {
            list = lists[0].value.chapters.map(function (chapter) {
              return chapter.chapterRenderer;
            }).filter(Boolean).map(function (chapter) {
              return { title: textOf(chapter.title), start: (chapter.timeRangeStartMillis || 0) / 1000,
                thumbnail: chapterThumbnail(chapter.thumbnail) };
            });
          }
          chapterCache = { video: watchedVideo, list: list };
          return list;
        }

        // The smallest of a chapter's pictures that is still sharp in a list row.
        function chapterThumbnail(thumbnail) {
          var sizes = (thumbnail && thumbnail.thumbnails) || [];
          var sharp = sizes.filter(function (size) { return size.width >= 300; })
            .sort(function (a, b) { return a.width - b.width; })[0];
          var picked = sharp || sizes[sizes.length - 1];
          return picked && picked.url ? picked.url : undefined;
        }

        function captionID(track) {
          if (!track) { return null; }
          return track.vss_id || track.vssId || ((track.kind === 'asr' ? 'a.' : '.') + track.languageCode);
        }

        // The caption tracks on offer. YouTube lists them once its captions module is loaded;
        // before that, the audio track carries the same list.
        function captionTracks(player) {
          var list = [];
          try { list = player.getOption('captions', 'tracklist') || []; } catch (e) {}
          if (list.length) { return list; }
          var audio = null;
          try { audio = player.getAudioTrack(); } catch (e) {}
          for (var name in audio || {}) {
            var value = audio[name];
            if (Array.isArray(value) && value.length && value[0] && value[0].languageCode) {
              return value.map(function (track) {
                return { languageCode: track.languageCode, languageName: track.languageName,
                  displayName: track.displayName || track.languageName, kind: track.kind,
                  name: track.name, vss_id: track.vssId, is_translateable: track.isTranslateable };
              });
            }
          }
          return [];
        }

        function currentCaption(player) {
          try {
            var track = player.getOption('captions', 'track');
            return track && track.languageCode ? track : null;
          } catch (e) { return null; }
        }

        // What describes an audio track sits under a property whose name YouTube's build minifies,
        // so it is found by its shape: a name to show and an id to choose it by.
        function audioInfo(track) {
          for (var name in track || {}) {
            var value = track[name];
            if (value && typeof value === 'object' && typeof value.name === 'string' &&
                typeof value.id === 'string') { return value; }
          }
          return null;
        }

        function collectOptions(player) {
          var report = {};
          try {
            report.qualities = (player.getAvailableQualityData() || []).filter(function (quality) {
              return quality.isPlayable !== false && quality.quality !== 'auto';
            }).map(function (quality) { return { id: quality.quality, title: quality.qualityLabel }; });
          } catch (e) {}
          try { report.quality = player.getPreferredQuality(); } catch (e) {}
          try { report.qualityLabel = player.getPlaybackQualityLabel(); } catch (e) {}
          var tracks = captionTracks(player);
          report.captions = tracks.map(function (track) {
            return { id: captionID(track), title: track.displayName || track.languageName || track.languageCode };
          });
          var caption = currentCaption(player);
          report.caption = captionID(caption);
          report.translation = caption && caption.translationLanguage ? caption.translationLanguage.languageCode : null;
          try {
            report.translations = (player.getOption('captions', 'translationLanguages') || []).map(function (language) {
              return { id: language.languageCode, title: language.languageName };
            });
          } catch (e) { report.translations = []; }
          try {
            report.audioTracks = (player.getAvailableAudioTracks() || []).map(audioInfo).filter(Boolean)
              .map(function (info) { return { id: info.id, title: info.name }; });
            var audio = audioInfo(player.getAudioTrack());
            report.audioTrack = audio ? audio.id : null;
          } catch (e) {}
          try { report.rates = player.getAvailablePlaybackRates(); } catch (e) {}
          try { report.rate = player.getPlaybackRate(); } catch (e) {}
          report.chapters = chapters(player);
          report.ad = player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting');
          report.ended = player.classList.contains('ended-mode');
          return report;
        }

        // Reports what the menus would offer whenever any of it changes — and keeps YouTube's own
        // layer hidden or shown, which can change with the video, an ad, or the end.
        function reportOptions() {
          if (!watchedVideo) { return; }
          var player = moviePlayer();
          if (!player || typeof player.getAvailableQualityData !== 'function') { return; }
          var report = collectOptions(player);
          prepareEmbed(player.ownerDocument, !!(report.ad || report.ended));
          var text = JSON.stringify(report);
          if (text === lastReport) { return; }
          lastReport = text;
          post({ type: 'options', payload: text });
        }

        setInterval(reportOptions, 500);

        function setQuality(quality) {
          var player = moviePlayer();
          if (!player || !player.setPlaybackQualityRange) { return; }
          try { player.setPlaybackQualityRange(quality, quality); } catch (e) {}
          reportOptions();
        }

        // A caption track by id, translated or not; no id at all turns captions off, and an empty
        // one turns them on in whatever language YouTube would pick itself.
        function setCaptions(id, translation) {
          var player = moviePlayer();
          if (!player) { return; }
          if (id === null && !translation) {
            try { player.setOption('captions', 'track', {}); } catch (e) {}
            reportOptions();
            return;
          }
          try { player.loadModule('captions'); } catch (e) {}
          var apply = function () {
            var tracks = captionTracks(player);
            var current = currentCaption(player);
            var track = tracks.filter(function (candidate) { return captionID(candidate) === id; })[0];
            if (!track && translation) {
              track = current || tracks.filter(function (candidate) {
                return candidate.is_translateable || candidate.isTranslateable;
              })[0];
            }
            if (!track && id === '') {
              if (current) { return true; }
              var language = (navigator.language || 'en').split('-')[0];
              track = tracks.filter(function (candidate) { return candidate.languageCode.split('-')[0] === language; })[0] || tracks[0];
            }
            if (!track) { return false; }
            var choice = Object.assign({}, track);
            delete choice.translationLanguage;
            if (translation) {
              var names = [];
              try { names = player.getOption('captions', 'translationLanguages') || []; } catch (e) {}
              var named = names.filter(function (language) { return language.languageCode === translation; })[0];
              choice.translationLanguage = { languageCode: translation, languageName: named ? named.languageName : translation };
            }
            try { player.setOption('captions', 'track', choice); } catch (e) { return false; }
            return true;
          };
          // The module loads asynchronously, and until it has, a choice may not take.
          if (!apply()) { setTimeout(apply, 400); }
          setTimeout(reportOptions, 450);
        }

        function setAudioTrack(id) {
          var player = moviePlayer();
          if (!player) { return; }
          try {
            var track = (player.getAvailableAudioTracks() || []).filter(function (candidate) {
              var info = audioInfo(candidate);
              return info && info.id === id;
            })[0];
            if (track) { player.setAudioTrack(track); }
          } catch (e) {}
          reportOptions();
        }

        function setRate(rate) {
          var player = moviePlayer();
          if (player && player.setPlaybackRate) {
            try { player.setPlaybackRate(rate); } catch (e) { command('setPlaybackRate', [rate]); }
          } else {
            command('setPlaybackRate', [rate]);
          }
          reportOptions();
        }

        // The embed only starts reporting state once we introduce ourselves; it can miss the
        // first few messages while it boots, so repeat briefly.
        function installHandshake(loadedFrame) {
          loadedFrame.addEventListener('load', function () {
            if (loadedFrame !== frame || !watchedVideo) { return; }
            var doc = embedDocument();
            if (doc) { prepareEmbed(doc, false); }
            clearInterval(handshake);
            var attempts = 0;
            handshake = setInterval(function () {
              send({ event: 'listening', id: 'frame', channel: 'widget' });
              if (attempts === 2 && startsPlaying) {
                if (startsMuted) { command('mute'); }
                command('playVideo');
              }
              if (++attempts > 20) { clearInterval(handshake); }
            }, 250);
            post({ type: 'ready' });
          });
        }

        window.addEventListener('message', function (event) {
          if (!watchedVideo || event.source !== frame.contentWindow) { return; }
          var data;
          try { data = JSON.parse(event.data); } catch (e) { return; }
          if (!data) { return; }

          if (data.event === 'onStateChange') {
            playing = data.info === 1;
            if (data.info === 0) { reachedEnd = true; }
            post({ type: 'state', state: data.info });
          } else if (data.event === 'onError') {
            post({ type: 'error', state: data.info });
          } else if (data.event === 'infoDelivery' && data.info) {
            var info = data.info;
            if (info.videoData && info.videoData.video_id) {
              var shownVideo = info.videoData.video_id;
              // Only YouTube's end screen can put another video in the embed: tell the app, which
              // takes it over as the video playing.
              if (reachedEnd && reportedVideoID && shownVideo !== reportedVideoID) {
                reachedEnd = false;
                post({ type: 'switched', payload: shownVideo });
              }
              reportedVideoID = shownVideo;
            }
            if (pendingStartSeconds > 0 && info.duration > 0 &&
                (!reportedVideoID || reportedVideoID === watchedVideo)) {
              command('seekTo', [pendingStartSeconds < info.duration ? pendingStartSeconds : 0, true]);
              pendingStartSeconds = 0;
            }
            if (typeof info.playerState === 'number') {
              if (info.playerState === 0) { reachedEnd = true; }
              post({ type: 'state', state: info.playerState, duration: info.duration || 0 });
            }
            if (typeof info.currentTime === 'number') {
              post({ type: 'time', time: info.currentTime, duration: info.duration || 0 });
            }
            if (typeof info.errorCode === 'number' && info.errorCode) {
              post({ type: 'error', state: info.errorCode });
            }
          }
        });

        function resume() { command('playVideo'); }
        function unMute() { startsMuted = false; command('unMute'); }
        // Not playing from this moment, before the embed confirms it.
        function pauseVideo() { playing = false; command('pauseVideo'); }

        // Puts the video back in the page from its Picture in Picture window.
        function exitPictureInPicture() {
          var video = videoElement();
          if (!video) { return; }
          try {
            if (video.webkitPresentationMode === 'picture-in-picture') {
              video.webkitSetPresentationMode('inline');
            } else if (document.pictureInPictureElement || (embedDocument() || {}).pictureInPictureElement) {
              (embedDocument() || document).exitPictureInPicture();
            }
          } catch (e) {}
        }
        function seekTo(seconds) { command('seekTo', [seconds, true]); }
        function stopVideo() {
          clearInterval(handshake);
          watchedVideo = null;
          fullScreenVideo = null;
          playing = false;
          frame.src = 'about:blank';
        }

        setVideo('__VIDEO_ID__', __START_SECONDS__, '__PLAYBACK_ID__', __AUTOPLAY__, __MUTED__);
      </script>
    </body>
    </html>
    """
}
