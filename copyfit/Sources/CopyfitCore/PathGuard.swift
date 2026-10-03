import Foundation

/// 入力pathをmanifestのあるdirectory配下に限定する（`..`・絶対path・symlinkによる逸脱を拒否）。
public struct PathGuard: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    public func resolve(_ relative: String) throws -> URL {
        if relative.hasPrefix("/") || relative.hasPrefix("~") || relative.contains("\\") || relative.contains("\0") {
            throw CopyfitError.pathEscape("絶対path・~・バックスラッシュは使えません（manifestからの相対pathで指定）: \(relative)")
        }
        let comps = relative.split(separator: "/", omittingEmptySubsequences: true)
        if comps.contains("..") {
            throw CopyfitError.pathEscape("`..`を含むpathは使えません: \(relative)")
        }
        let url = comps.reduce(root) { $0.appendingPathComponent(String($1)) }
        let real = url.resolvingSymlinksInPath()
        guard PathGuard.isInside(real, root) else {
            throw CopyfitError.pathEscape("symlink等により入力root外を指しています: \(relative)")
        }
        return url
    }

    static func isInside(_ url: URL, _ root: URL) -> Bool {
        let p = url.standardizedFileURL.path, r = root.standardizedFileURL.path
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }
}
