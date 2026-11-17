import Foundation

/// URLs for the YouTube screen: the mobile site for browsing and search, the official
/// IFrame Player (youtube-nocookie.com) for playback, and the YouTube app.
enum YouTubeLinks {
    static let home = URL(string: "https://m.youtube.com/")!

    /// `https://m.youtube.com/results?search_query=<query>`; nil for an empty query.
    static func search(_ query: String) -> URL? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var components = URLComponents(string: "https://m.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query", value: text)]
        // URLComponents leaves '+' and '&'-free text alone; make '+' explicit so it isn't read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    /// A video id is 11 characters of A–Z, a–z, 0–9, '-' and '_'. Anything else is rejected, so an id
    /// can be put into the player page safely.
    static func isValidVideoID(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy { scalar in
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").contains(scalar)
        }
    }

    /// The video in a watch, Shorts, embed, live or youtu.be link; nil for anything else.
    static func videoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        var candidate: String?
        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            candidate = parts.first
        } else if YouTubeNavigationPolicy.hostMatches(host, ["youtube.com", "youtube-nocookie.com"]) {
            if parts.first == "watch" {
                candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "v" })?.value
            } else if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]) {
                candidate = parts[1]
            }
        }
        guard let candidate, isValidVideoID(candidate) else { return nil }
        return candidate
    }

    /// The watch page on the mobile site (for videos the embedded player isn't allowed to play).
    static func watchPage(_ id: String) -> URL? {
        isValidVideoID(id) ? URL(string: "https://m.youtube.com/watch?v=\(id)") : nil
    }

    /// The YouTube app: the video when there is one, else the app's home.
    static func app(videoID: String?) -> URL {
        if let videoID, isValidVideoID(videoID) {
            return URL(string: "youtube://www.youtube.com/watch?v=\(videoID)")!
        }
        return URL(string: "youtube://")!
    }

    /// The page that hosts the official IFrame Player. `origin` identifies the app to YouTube
    /// (YouTube asks embedded players in apps for an https origin built from the app's ID).
    static func playerPage(videoID: String, origin: String) -> String? {
        guard isValidVideoID(videoID) else { return nil }
        let safeOrigin = origin.filter { $0.isLetter || $0.isNumber || ":/.-".contains($0) }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#player{position:absolute;inset:0;width:100%;height:100%}</style>
        </head><body><div id="player"></div>
        <script>
        function post(m){try{window.webkit.messageHandlers.duodashPlayer.postMessage(m)}catch(e){}}
        var player;
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('player',{host:'https://www.youtube-nocookie.com',videoId:'\(videoID)',width:'100%',height:'100%',
            playerVars:{playsinline:1,autoplay:1,rel:0,origin:'\(safeOrigin)'},
            events:{onReady:function(e){e.target.playVideo();post({type:'ready'})},
                    onStateChange:function(e){post({type:'state',state:e.data})},
                    onError:function(e){post({type:'error',code:e.data})}}});
        }
        function duodashPause(){if(player&&player.pauseVideo){player.pauseVideo()}}
        </script>
        <script src="https://www.youtube.com/iframe_api"></script>
        </body></html>
        """
    }
}

/// Where the YouTube web views may go. Only top-level (main-frame) navigations are checked:
/// YouTube's own frames, including its ads, load untouched (no ad blocking).
enum YouTubeNavigationPolicy {
    enum Decision: Equatable {
        /// Load it in the web view.
        case allow
        /// Not YouTube or a Google sign-in page: open in Safari (or the app that owns the link).
        case openExternally
        /// Never load (javascript: and friends).
        case cancel
    }

    /// YouTube and the Google sign-in pages it uses.
    static let allowedHosts = ["youtube.com", "youtube-nocookie.com", "youtu.be",
                               "accounts.google.com", "accounts.youtube.com", "consent.google.com",
                               "consent.youtube.com", "myaccount.google.com"]

    /// `host` is one of `domains` or a subdomain of one ("m.youtube.com" matches "youtube.com";
    /// "notyoutube.com" and "youtube.com.evil.example" don't).
    static func hostMatches(_ host: String, _ domains: [String]) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// - Parameter playerHost: the made-up https host the player page is loaded under.
    static func decision(for url: URL, isMainFrame: Bool, playerHost: String? = nil) -> Decision {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "javascript" { return .cancel }
        guard isMainFrame else { return .allow }
        switch scheme {
        case "about", "blob", "data":
            return .allow
        case "http", "https":
            guard let host = url.host?.lowercased(), !host.isEmpty else { return .cancel }
            if let playerHost, host == playerHost.lowercased() { return .allow }
            return hostMatches(host, allowedHosts) ? .allow : .openExternally
        default:
            // youtube://, mailto:, tel:, intent: … belong to other apps.
            return scheme.isEmpty ? .cancel : .openExternally
        }
    }
}
