import Foundation
import PDFKit

/// Keeps the paper up to date without shipping a new build.
///
/// The paper is revised far more often than the app is released — a corrected figure, a journey
/// added to the results table — and each of those used to mean an App Store submission and a
/// review wait for a document that has nothing to do with the binary. It is now fetched from the
/// release asset the repository already publishes, so a revision reaches readers the moment it is
/// uploaded.
///
/// The bundled copy is never removed and never stops working. It is what opens instantly, what
/// opens on a plane, and what opens if every fetch fails forever. The network copy is an
/// improvement on it, not a dependency: nothing here can leave the reader with no paper.
@MainActor
final class PaperStore: ObservableObject {
    static let shared = PaperStore()

    enum Status: Equatable {
        case bundled            // showing what shipped with the app
        case cached(Date)       // showing a newer copy fetched earlier
        case checking
        case updated            // a newer copy arrived just now
        case failed(String)     // check failed; still showing something readable
    }

    @Published private(set) var status: Status = .bundled
    /// The best copy available right now. Never nil while the app is correctly built.
    @Published private(set) var url: URL?

    /// The release asset is re-uploaded in place (`gh release upload --clobber`), so this URL is
    /// stable across revisions and always serves the current paper. A tag rather than `latest`
    /// on purpose: `latest` follows whichever release is newest, which would start serving app
    /// builds rather than the document.
    private let remote = URL(string: "https://github.com/yu314-coder/GPS-location-app/releases/download/v1.0-paper/velocity_mode.pdf")!

    private let etagKey = "paperETag"
    private let fetchedKey = "paperFetchedAt"

    private var bundled: URL? { Bundle.main.url(forResource: "velocity_mode", withExtension: "pdf") }

    private var cached: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("velocity_mode_latest.pdf")
    }

    private init() {
        // Resolve something readable before any network call, so opening the paper is instant
        // and works offline on first launch.
        if FileManager.default.fileExists(atPath: cached.path), isReadablePDF(cached) {
            url = cached
            let at = UserDefaults.standard.object(forKey: fetchedKey) as? Date
            status = .cached(at ?? Date.distantPast)
        } else {
            url = bundled
            status = .bundled
        }
    }

    /// A file is only allowed to replace what the reader already has if it genuinely opens.
    ///
    /// Without this the cache is one captive-portal login page away from being a blank screen:
    /// hotel Wi-Fi answers 200 with HTML, the bytes get written under a .pdf name, and the paper
    /// is gone until the app is reinstalled. PDFKit parsing it, with at least one page, is the
    /// only evidence worth trusting here.
    private func isReadablePDF(_ u: URL) -> Bool {
        guard let doc = PDFDocument(url: u), doc.pageCount > 0 else { return false }
        return true
    }

    func refresh() async {
        guard status != .checking else { return }
        status = .checking

        var request = URLRequest(url: remote)
        request.timeoutInterval = 20
        // Ask only for what changed. The paper is a quarter of a megabyte; re-downloading it on
        // every visit to the screen would be rude on a phone connection.
        if let etag = UserDefaults.standard.string(forKey: etagKey),
           FileManager.default.fileExists(atPath: cached.path) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                settle(.failed("No response"))
                return
            }
            if http.statusCode == 304 {
                settle(currentCachedStatus())
                return
            }
            guard http.statusCode == 200 else {
                settle(.failed("Server said \(http.statusCode)"))
                return
            }

            // Write to a scratch file first and prove it opens before it becomes the paper.
            let scratch = cached.deletingLastPathComponent()
                .appendingPathComponent("velocity_mode_incoming.pdf")
            try? FileManager.default.removeItem(at: scratch)
            try data.write(to: scratch, options: .atomic)
            guard isReadablePDF(scratch) else {
                try? FileManager.default.removeItem(at: scratch)
                settle(.failed("Downloaded file was not a readable PDF"))
                return
            }

            _ = try? FileManager.default.replaceItemAt(cached, withItemAt: scratch)
            if let tag = http.value(forHTTPHeaderField: "Etag") {
                UserDefaults.standard.set(tag, forKey: etagKey)
            }
            UserDefaults.standard.set(Date(), forKey: fetchedKey)
            url = cached
            status = .updated
        } catch {
            settle(.failed(error.localizedDescription))
        }
    }

    private func currentCachedStatus() -> Status {
        if FileManager.default.fileExists(atPath: cached.path), isReadablePDF(cached) {
            return .cached(UserDefaults.standard.object(forKey: fetchedKey) as? Date ?? Date())
        }
        return .bundled
    }

    /// Whatever went wrong, end on a readable document.
    private func settle(_ s: Status) {
        if url == nil || !(url.map(isReadablePDF) ?? false) {
            url = FileManager.default.fileExists(atPath: cached.path) && isReadablePDF(cached)
                ? cached : bundled
        }
        status = s
    }

    /// Drop the fetched copy and go back to what shipped with the build.
    func resetToBundled() {
        try? FileManager.default.removeItem(at: cached)
        UserDefaults.standard.removeObject(forKey: etagKey)
        UserDefaults.standard.removeObject(forKey: fetchedKey)
        url = bundled
        status = .bundled
    }
}
