import Foundation
import AppKit
import Combine

/// Tiny in-app updater that polls the GitHub Releases API for the latest tag
/// and, when newer than the current build, downloads the attached
/// `pagerduty-menubar-X.Y.Z.zip`, replaces the running app bundle, and
/// relaunches. Plain HTTP, no Sparkle, no signing required.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate(current: String)
        case available(Release)
        case downloading(progress: Double)
        case installing
        case failed(String)
    }

    struct Release: Equatable {
        let version: String          // "1.4.0" (tag without leading 'v')
        let zipURL: URL
        let htmlURL: URL?
        let publishedAt: Date?
        let notes: String?
    }

    @Published var autoInstall: Bool {
        didSet { UserDefaults.standard.set(autoInstall, forKey: Self.kAutoInstall) }
    }
    private static let kAutoInstall = "updater.autoInstall"

    @Published private(set) var status: Status = .idle
    @Published var lastCheckedAt: Date?

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    private let repo = "mattdholloway/pagerduty-menubar"
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        return URLSession(configuration: cfg)
    }()

    private init() {
        autoInstall = UserDefaults.standard.bool(forKey: Self.kAutoInstall)
    }

    /// Hit the Releases API. Returns the newest non-prerelease, non-draft
    /// release if it's > current. On failure, sets `.failed` and returns nil.
    func check() async -> Release? {
        status = .checking
        defer { lastCheckedAt = Date() }
        do {
            let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
            var req = URLRequest(url: url)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("pagerduty-menubar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                status = .failed("GitHub returned \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            guard let release = try parseLatest(data: data) else {
                status = .failed("Couldn't find a release zip asset.")
                return nil
            }
            if semverGreater(release.version, than: currentVersion) {
                status = .available(release)
                if autoInstall {
                    Task { await downloadAndInstall(release) }
                }
                return release
            } else {
                status = .upToDate(current: currentVersion)
                return nil
            }
        } catch {
            status = .failed(error.localizedDescription)
            return nil
        }
    }

    /// Download zip → expand → move to /Applications → relaunch.
    func downloadAndInstall(_ release: Release) async {
        status = .downloading(progress: 0)
        do {
            let tmpZip = try await download(release.zipURL) { p in
                self.status = .downloading(progress: p)
            }
            status = .installing
            let expanded = try unzip(tmpZip)
            try replaceRunningBundleAndRelaunch(with: expanded)
            // Process is exec'd away; nothing to do here.
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Manual "Check now" affordance for the menu, but also kicked off
    /// automatically once per launch (and every 24h thereafter while the
    /// app is running).
    func startBackgroundChecks() {
        Task {
            // First check on launch (small delay so we don't compete with
            // the initial PagerDuty refresh).
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            _ = await check()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 24 * 60 * 60 * 1_000_000_000)
                _ = await check()
            }
        }
    }

    // MARK: - Internals

    private func parseLatest(data: Data) throws -> Release? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let tag = json["tag_name"] as? String else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        let asset = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
        guard let urlString = asset?["browser_download_url"] as? String, let zip = URL(string: urlString) else {
            return nil
        }
        let html = (json["html_url"] as? String).flatMap(URL.init(string:))
        let notes = json["body"] as? String
        let publishedAt: Date? = {
            guard let s = json["published_at"] as? String else { return nil }
            let f = ISO8601DateFormatter()
            return f.date(from: s)
        }()
        return Release(version: version, zipURL: zip, htmlURL: html, publishedAt: publishedAt, notes: notes)
    }

    private func download(_ url: URL, onProgress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdaterError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let total = max(1, Double(http.expectedContentLength))
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pagerduty-menubar-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let outURL = tmpDir.appendingPathComponent("update.zip")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outURL)
        defer { try? handle.close() }

        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                let p = Double(received) / total
                await MainActor.run { onProgress(min(0.99, p)) }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        await MainActor.run { onProgress(1.0) }
        return outURL
    }

    private func unzip(_ zip: URL) throws -> URL {
        let dst = zip.deletingLastPathComponent().appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        // Use ditto — same tool we packaged with, preserves resource forks.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zip.path, dst.path]
        let err = Pipe(); proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ditto failed"
            throw UpdaterError.unzip(msg)
        }
        // Find the .app inside.
        let contents = try FileManager.default.contentsOfDirectory(at: dst, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdaterError.unzip("No .app found inside the downloaded zip.")
        }
        return app
    }

    private func replaceRunningBundleAndRelaunch(with newAppURL: URL) throws {
        let runningURL = Bundle.main.bundleURL
        // Strip Apple quarantine so the new bundle launches cleanly.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-rd", "com.apple.quarantine", newAppURL.path]
        try? xattr.run()
        xattr.waitUntilExit()

        // Write a small relaunch helper script. We can't move our own bundle
        // out from under ourselves, so spawn `osascript` to do it after we
        // exit, then relaunch.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        set -euo pipefail
        sleep 1
        # Wait for the old process to die (up to 10s).
        for i in $(seq 1 20); do
          if ! kill -0 \(pid) 2>/dev/null; then break; fi
          sleep 0.5
        done
        rm -rf "\(runningURL.path)"
        cp -R "\(newAppURL.path)" "\(runningURL.path)"
        open "\(runningURL.path)"
        """
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("pdmenu-update-\(UUID().uuidString).sh")
        try script.data(using: .utf8)!.write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path]
        try proc.run()
        // Exit cleanly so the helper can replace our bundle.
        NSApp.terminate(nil)
    }

    // MARK: - Semver compare

    private func semverGreater(_ a: String, than b: String) -> Bool {
        let pa = parts(a), pb = parts(b)
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func parts(_ v: String) -> [Int] {
        // Drop a pre-release suffix when comparing (treat 1.0.0-rc1 == 1.0.0).
        let clean = v.split(separator: "-").first.map(String.init) ?? v
        return clean.split(separator: ".").compactMap { Int($0) }
    }
}

enum UpdaterError: LocalizedError {
    case http(Int)
    case unzip(String)
    var errorDescription: String? {
        switch self {
        case .http(let code): return "Download failed: HTTP \(code)"
        case .unzip(let msg): return "Couldn't unpack the update: \(msg)"
        }
    }
}
