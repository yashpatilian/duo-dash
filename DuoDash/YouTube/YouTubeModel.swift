import AVFoundation
import Observation
import UIKit
import WebKit

/// The YouTube screen: a browser web view on the mobile site (home, search, results) and a
/// player web view with the official IFrame Player. Tapping a video in the browser plays it in
/// the player, so on a wide window the video stays on one half while you keep browsing.
@MainActor
@Observable
final class YouTubeModel {
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    /// The video in the player, if any.
    private(set) var videoID: String?
    /// The embedded player refused the video (the owner turned off embedding, for example).
    private(set) var embedError: Int?
    private(set) var isPlaying = false
    private(set) var isPictureInPicture = false
    var query = ""

    /// The passenger notice, shown once per launch.
    static var safetyNoticeDismissed = false
    var showsSafetyNotice = !YouTubeModel.safetyNoticeDismissed

    @ObservationIgnored private(set) lazy var browser: WKWebView = makeBrowser()
    @ObservationIgnored private(set) lazy var player: WKWebView = makePlayer()
    @ObservationIgnored private weak var playerView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private lazy var delegate = YouTubeWebDelegate(model: self)
    /// Videos the embedded player can't play, allowed to play on the mobile site instead.
    @ObservationIgnored private var playOnSite: Set<String> = []
    @ObservationIgnored private let canOpen: (URL) -> Bool
    @ObservationIgnored private let openURL: (URL) -> Void

    /// The made-up https origin the player page is loaded under: the app's bundle ID, which is how
    /// YouTube asks embedded players inside apps to identify themselves.
    let playerOrigin: URL

    init(canOpen: ((URL) -> Bool)? = nil, openURL: ((URL) -> Void)? = nil) {
        self.canOpen = canOpen ?? { LaunchOptions.demoExternalApps || UIApplication.shared.canOpenURL($0) }
        self.openURL = openURL ?? { UIApplication.shared.open($0) }
        let bundle = (Bundle.main.bundleIdentifier ?? "app.duodash").lowercased()
        playerOrigin = URL(string: "https://\(bundle)") ?? URL(string: "https://app.duodash")!
    }

    /// The YouTube app is on the phone ("Open in YouTube app"). Checked when the screen appears.
    private(set) var isYouTubeAppInstalled = false

    func refreshAppInstalled() {
        let installed = canOpen(YouTubeLinks.app(videoID: nil))
        if installed != isYouTubeAppInstalled { isYouTubeAppInstalled = installed }
    }

    // MARK: Browsing

    func loadHomeIfNeeded() {
        refreshAppInstalled()
        if browser.url == nil { browser.load(URLRequest(url: YouTubeLinks.home)) }
    }

    func goHome() { browser.load(URLRequest(url: YouTubeLinks.home)) }

    func search() {
        guard let url = YouTubeLinks.search(query) else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        browser.load(URLRequest(url: url))
    }

    func back() { if browser.canGoBack { browser.goBack() } }
    func forward() { if browser.canGoForward { browser.goForward() } }
    func reload() {
        if isLoading { browser.stopLoading() } else { browser.reload() }
    }

    // MARK: Playing

    func play(_ id: String) {
        guard let page = YouTubeLinks.playerPage(videoID: id, origin: playerOrigin.absoluteString) else { return }
        pauseBrowser()
        videoID = id
        embedError = nil
        player.loadHTMLString(page, baseURL: playerOrigin)
    }

    func closeVideo() {
        player.loadHTMLString("<html><body style='background:#000'></body></html>", baseURL: playerOrigin)
        videoID = nil
        embedError = nil
        isPlaying = false
        isPictureInPicture = false
        releaseAudio()
    }

    /// For a video the embedded player can't play: show its watch page on the mobile site.
    func playOnMobileSite() {
        guard let id = videoID, let url = YouTubeLinks.watchPage(id) else { return }
        playOnSite.insert(id)
        closeVideo()
        browser.load(URLRequest(url: url))
    }

    func openInYouTubeApp() {
        pauseAll()
        openURL(YouTubeLinks.app(videoID: videoID))
    }

    /// Leaving the screen or the app: pause, unless the video is in picture in picture.
    func pauseAll() {
        guard !isPictureInPicture else { return }
        playerView?.evaluateJavaScript("window.duodashPause && duodashPause()")
        pauseBrowser()
    }

    func dismissSafetyNotice() {
        Self.safetyNoticeDismissed = true
        showsSafetyNotice = false
    }

    private func pauseBrowser() {
        browser.evaluateJavaScript("window.__duodashPause && __duodashPause()", in: nil, in: .defaultClient) { _ in }
    }

    // MARK: Events from the pages

    fileprivate func handle(message: [String: Any], fromPlayer: Bool) {
        switch message["type"] as? String {
        case "watch":
            if let id = message["id"] as? String, YouTubeLinks.isValidVideoID(id) { play(id) }
        case "state" where fromPlayer:
            // YT.PlayerState: 1 playing, 2 paused, 0 ended.
            switch message["state"] as? Int {
            case 1: mediaStarted(inPlayer: true)
            case 0, 2: mediaStopped()
            default: break
            }
        case "error" where fromPlayer:
            embedError = (message["code"] as? Int) ?? -1
            mediaStopped()
        case "play":
            mediaStarted(inPlayer: fromPlayer)
        case "pause", "ended":
            mediaStopped()
        case "pip":
            isPictureInPicture = (message["active"] as? Bool) ?? false
        default:
            break
        }
    }

    /// A video started: take the audio session for playback so music pauses (or the music app
    /// stops), as it would for any video app; and keep only one video playing.
    private func mediaStarted(inPlayer: Bool) {
        isPlaying = true
        if inPlayer { pauseBrowser() } else { playerView?.evaluateJavaScript("window.duodashPause && duodashPause()") }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    private func mediaStopped() {
        isPlaying = false
        releaseAudio()
    }

    /// Lets other audio (music) resume.
    private func releaseAudio() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The mobile site reached a watch page without our tap handler (a redirect, a link from
    /// another page): play it in the player and step the browser back.
    fileprivate func browserURLChanged(_ url: URL?) {
        guard let url, let id = YouTubeLinks.videoID(from: url), !playOnSite.contains(id) else { return }
        pauseBrowser()
        play(id)
        if browser.canGoBack { browser.goBack() } else { goHome() }
    }

    fileprivate func openOutside(_ url: URL) {
        // A YouTube link that can't stay here goes to the YouTube app when it's installed.
        if let id = YouTubeLinks.videoID(from: url), isYouTubeAppInstalled {
            openURL(YouTubeLinks.app(videoID: id))
        } else {
            openURL(url)
        }
    }

    fileprivate func decision(for url: URL, isMainFrame: Bool) -> YouTubeNavigationPolicy.Decision {
        YouTubeNavigationPolicy.decision(for: url, isMainFrame: isMainFrame, playerHost: playerOrigin.host)
    }

    // MARK: Web views

    private func configuration(scripts: [WKUserScript], handler: String, world: WKContentWorld) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .default()
        let content = configuration.userContentController
        for script in scripts { content.addUserScript(script) }
        content.add(delegate, contentWorld: world, name: handler)
        if handler != YouTubeScripts.mediaHandler {
            content.add(delegate, contentWorld: .defaultClient, name: YouTubeScripts.mediaHandler)
        }
        return configuration
    }

    private func makeBrowser() -> WKWebView {
        let scripts = [WKUserScript(source: YouTubeScripts.media, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient),
                       WKUserScript(source: YouTubeScripts.watchTaps, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient)]
        let view = WKWebView(frame: .zero, configuration: configuration(scripts: scripts, handler: YouTubeScripts.mediaHandler, world: .defaultClient))
        setUp(view, identifier: "youtube.web")
        view.allowsBackForwardNavigationGestures = true
        observations += [
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoForward = view.canGoForward }
            },
            view.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.isLoading = view.isLoading }
            },
            // The mobile site is a single-page app: links change the URL without a navigation.
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.browserURLChanged(view.url) }
            },
        ]
        return view
    }

    private func makePlayer() -> WKWebView {
        let scripts = [WKUserScript(source: YouTubeScripts.media, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient)]
        let view = WKWebView(frame: .zero, configuration: configuration(scripts: scripts, handler: YouTubeScripts.playerHandler, world: .page))
        setUp(view, identifier: "youtube.player")
        view.scrollView.isScrollEnabled = false
        playerView = view
        return view
    }

    private func setUp(_ view: WKWebView, identifier: String) {
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.backgroundColor = .black
        view.isInspectable = LaunchOptions.isUITesting
        view.accessibilityIdentifier = identifier
    }

    fileprivate func isPlayer(_ view: WKWebView?) -> Bool {
        guard let view, let playerView else { return false }
        return view === playerView
    }
}

/// Navigation, new-window and script-message handling for both web views.
private final class YouTubeWebDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var model: YouTubeModel?

    init(model: YouTubeModel) { self.model = model }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let model, let url = action.request.url else { return decisionHandler(.cancel) }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        switch model.decision(for: url, isMainFrame: mainFrame) {
        case .allow:
            decisionHandler(.allow)
        case .openExternally:
            decisionHandler(.cancel)
            model.openOutside(url)
        case .cancel:
            decisionHandler(.cancel)
        }
    }

    /// target=_blank links: YouTube pages load here, everything else opens outside.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let model, let url = action.request.url else { return nil }
        if let id = YouTubeLinks.videoID(from: url) {
            model.play(id)
        } else if model.decision(for: url, isMainFrame: true) == .allow {
            model.browser.load(URLRequest(url: url))
        } else {
            model.openOutside(url)
        }
        return nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let model, let body = message.body as? [String: Any] else { return }
        model.handle(message: body, fromPlayer: model.isPlayer(message.webView))
    }
}

/// Scripts injected into the YouTube pages. They run in Duo Dash's own script world, apart
/// from YouTube's code, and only listen: nothing on the page is hidden or changed.
enum YouTubeScripts {
    static let mediaHandler = "duodashMedia"
    static let playerHandler = "duodashPlayer"

    /// Reports play/pause and picture in picture, and offers a pause for when Duo Dash leaves.
    static let media = """
    (function(){
      if (window.__duodashMediaInstalled) return; window.__duodashMediaInstalled = true;
      function post(m){ try { window.webkit.messageHandlers.duodashMedia.postMessage(m) } catch(e){} }
      function isMedia(t){ return t && (t.tagName === 'VIDEO' || t.tagName === 'AUDIO') }
      document.addEventListener('play', function(e){ if (isMedia(e.target)) post({type:'play'}) }, true);
      document.addEventListener('pause', function(e){ if (isMedia(e.target)) post({type:'pause'}) }, true);
      document.addEventListener('ended', function(e){ if (isMedia(e.target)) post({type:'ended'}) }, true);
      document.addEventListener('enterpictureinpicture', function(){ post({type:'pip', active:true}) }, true);
      document.addEventListener('leavepictureinpicture', function(){ post({type:'pip', active:false}) }, true);
      document.addEventListener('webkitpresentationmodechanged', function(e){
        if (isMedia(e.target)) post({type:'pip', active: e.target.webkitPresentationMode === 'picture-in-picture'})
      }, true);
      window.__duodashPause = function(){
        document.querySelectorAll('video,audio').forEach(function(v){
          if (v.webkitPresentationMode !== 'picture-in-picture') v.pause()
        })
      };
    })();
    """

    /// A tap on a video link plays it in Duo Dash's player instead of the mobile site's.
    static let watchTaps = """
    (function(){
      function idFor(href){
        try {
          var u = new URL(href, location.href);
          if (!/(^|\\.)youtube\\.com$/.test(u.hostname) && u.hostname !== 'youtu.be') return null;
          if (u.pathname === '/watch') return u.searchParams.get('v');
          var m = u.pathname.match(/^\\/(shorts|live)\\/([A-Za-z0-9_-]{11})/);
          return m ? m[2] : null;
        } catch(e) { return null }
      }
      document.addEventListener('click', function(e){
        var a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        if (!a) return;
        var id = idFor(a.getAttribute('href'));
        if (!id || !/^[A-Za-z0-9_-]{11}$/.test(id)) return;
        e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation();
        try { window.webkit.messageHandlers.duodashMedia.postMessage({type:'watch', id:id}) } catch(err){}
      }, true);
    })();
    """
}
