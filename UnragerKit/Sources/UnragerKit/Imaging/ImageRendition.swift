import Foundation

/// Which size of a picture to ask X's image host for.
public enum ImageRendition {
    /// X's image host serves a ~680 px rendition for `?name=small`, plenty for
    /// a tile under 340 pt and a fraction of the full-size download. Other
    /// hosts, and URLs that already pick a rendition, are left alone.
    public static func small(_ url: URL) -> URL {
        guard url.host == "pbs.twimg.com",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.queryItems?.contains(where: { $0.name == "name" }) != true else { return url }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "name", value: "small")]
        return components.url ?? url
    }
}
