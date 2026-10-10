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
///
/// THE NEWEST COPY WINS (build 120). A copy fetched under an older build used to win over the one
/// bundled with a newer build, so after an update the reader kept an old paper until a fetch went
/// through - never, on a plane. The paper carries no dates, so each PDF carries a revision number
/// in its keywords ("velocity-mode-paper revision N", N = the app build it was made for) and the
/// higher one is shown. A copy without a number (older revisions) is shown only if it was fetched
/// under this build or a later one.
///
/// AND IT OPENS WITHOUT PARSING THE PDF ON THE MAIN THREAD. Every launch, check and failure used to
/// open the whole document with PDFKit just to prove it was readable. A copy is proven once, off the
/// main thread, when it arrives; after that its size and date (with its revision) are remembered and
/// only compared.
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
    private let fetchedBuildKey = "paperFetchedBuild"
    private let provenKey = "paperProven"           // "size|modified|revision" of the cached copy, once proven

    private var bundled: URL? { Bundle.main.url(forResource: "velocity_mode", withExtension: "pdf") }
    private let bundledRevision: Int?
    private static let appBuild = Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0

    private var cached: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("velocity_mode_latest.pdf")
    }

    private init() {
        bundledRevision = Bundle.main.url(forResource: "velocity_mode", withExtension: "pdf").flatMap(Self.revisionFromBytes)
        // Resolve something readable before any network call, so opening the paper is instant and
        // works offline on first launch. No PDF is parsed here.
        if let rev = provenCachedRevision(), cachedIsNewest(cachedRevision: rev) {
            url = cached
            status = .cached(UserDefaults.standard.object(forKey: fetchedKey) as? Date ?? Date.distantPast)
        } else {
            url = bundled
            status = .bundled
            // A cached copy that was never proven (an older build wrote it): prove it off the main
            // thread and switch to it if it turns out to be the newer one.
            if FileManager.default.fileExists(atPath: cached.path), provenCachedRevision() == nil {
                let file = cached
                Task {
                    let found = await Task.detached(priority: .utility) { Self.inspect(file) }.value
                    self.remember(found, for: file)
                    if found.readable, self.cachedIsNewest(cachedRevision: found.revision ?? -1) {
                        self.url = file
                        self.status = .cached(UserDefaults.standard.object(forKey: self.fetchedKey) as? Date ?? Date.distantPast)
                    }
                }
            }
        }
    }

    // MARK: - Which copy

    /// The cached copy's revision (-1 for none) if it is the very file that was proven readable, else nil.
    private func provenCachedRevision() -> Int? {
        guard let proven = UserDefaults.standard.string(forKey: provenKey),
              let sig = Self.signature(cached) else { return nil }
        let parts = proven.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, "\(parts[0])|\(parts[1])" == sig else { return nil }
        return Int(parts[2]) ?? -1
    }

    /// Whether the cached copy (revision -1 = carries none) is at least as new as the bundled one.
    private func cachedIsNewest(cachedRevision: Int) -> Bool {
        if cachedRevision >= 0, let b = bundledRevision { return cachedRevision >= b }
        if cachedRevision >= 0, bundledRevision == nil { return true }
        // No number to compare: only a copy fetched under this build or a later one beats the bundled copy.
        let fetchedUnder = UserDefaults.standard.integer(forKey: fetchedBuildKey)
        return fetchedUnder >= Self.appBuild && Self.appBuild > 0
    }

    private func remember(_ found: (readable: Bool, revision: Int?), for file: URL) {
        guard found.readable, let sig = Self.signature(file) else {
            UserDefaults.standard.removeObject(forKey: provenKey); return
        }
        UserDefaults.standard.set("\(sig)|\(found.revision ?? -1)", forKey: provenKey)
    }

    // MARK: - Checking for a newer copy

    func refresh() async {
        guard status != .checking else { return }
        status = .checking

        var request = URLRequest(url: remote)
        request.timeoutInterval = 20
        // Ask only for what changed: a conditional request costs a few hundred bytes when nothing has.
        if let etag = UserDefaults.standard.string(forKey: etagKey), provenCachedRevision() != nil {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { settle(.failed("No response")); return }
            if http.statusCode == 304 {
                // The cached copy is the published one; show it if it is the newest, else the bundled.
                if let rev = provenCachedRevision(), cachedIsNewest(cachedRevision: rev) {
                    url = cached
                    status = .cached(UserDefaults.standard.object(forKey: fetchedKey) as? Date ?? Date())
                } else {
                    url = bundled
                    status = .bundled
                }
                return
            }
            guard http.statusCode == 200 else { settle(.failed("Server said \(http.statusCode)")); return }

            // Write to a scratch file first and prove it opens - off the main thread - before it becomes the paper.
            let scratch = cached.deletingLastPathComponent().appendingPathComponent("velocity_mode_incoming.pdf")
            try? FileManager.default.removeItem(at: scratch)
            try data.write(to: scratch, options: .atomic)
            let found = await Task.detached(priority: .utility) { Self.inspect(scratch) }.value
            guard found.readable else {
                try? FileManager.default.removeItem(at: scratch)
                settle(.failed("Downloaded file was not a readable PDF"))
                return
            }

            _ = try? FileManager.default.replaceItemAt(cached, withItemAt: scratch)
            if let tag = http.value(forHTTPHeaderField: "Etag") { UserDefaults.standard.set(tag, forKey: etagKey) }
            UserDefaults.standard.set(Date(), forKey: fetchedKey)
            UserDefaults.standard.set(Self.appBuild, forKey: fetchedBuildKey)
            remember(found, for: cached)
            if cachedIsNewest(cachedRevision: found.revision ?? -1) {
                url = cached
                status = .updated
            } else {
                // The published copy is older than the one this build carries (it has not been re-uploaded yet).
                url = bundled
                status = .bundled
            }
        } catch {
            settle(.failed(error.localizedDescription))
        }
    }

    /// Whatever went wrong, end on a readable document (the one already shown was proven or bundled).
    private func settle(_ s: Status) {
        if url == nil { url = bundled }
        status = s
    }

    /// Drop the fetched copy and go back to what shipped with the build.
    func resetToBundled() {
        try? FileManager.default.removeItem(at: cached)
        for key in [etagKey, fetchedKey, fetchedBuildKey, provenKey] { UserDefaults.standard.removeObject(forKey: key) }
        url = bundled
        status = .bundled
    }

    // MARK: - Reading files (no main-thread state)

    /// A file is only allowed to replace what the reader already has if it genuinely opens.
    ///
    /// Without this the cache is one captive-portal login page away from being a blank screen:
    /// hotel Wi-Fi answers 200 with HTML, the bytes get written under a .pdf name, and the paper
    /// is gone until the app is reinstalled. PDFKit parsing it, with at least one page, is the
    /// only evidence worth trusting here. Also reads the revision from its keywords.
    nonisolated private static func inspect(_ u: URL) -> (readable: Bool, revision: Int?) {
        guard let doc = PDFDocument(url: u), doc.pageCount > 0 else { return (false, nil) }
        let kw = doc.documentAttributes?[PDFDocumentAttribute.keywordsAttribute]
        let text = (kw as? String) ?? (kw as? [String])?.joined(separator: " ") ?? ""
        return (true, revision(in: text) ?? revisionFromBytes(u))
    }

    /// "velocity-mode-paper revision N" in the text, if present.
    nonisolated private static func revision(in text: String) -> Int? {
        guard let r = text.range(of: "velocity-mode-paper revision ") else { return nil }
        return Int(text[r.upperBound...].prefix { $0.isNumber })
    }

    /// The same marker read straight from the file's bytes (pdfTeX writes the document information
    /// uncompressed), so the bundled copy's revision costs a memory-mapped scan, not a PDF parse.
    nonisolated private static func revisionFromBytes(_ u: URL) -> Int? {
        guard let data = try? Data(contentsOf: u, options: .alwaysMapped),
              let marker = "velocity-mode-paper revision ".data(using: .ascii),
              let r = data.range(of: marker, options: .backwards) else { return nil }
        let digits = data[r.upperBound...].prefix { $0 >= 0x30 && $0 <= 0x39 }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    /// Size and modification time: what is compared instead of re-parsing a proven file.
    nonisolated private static func signature(_ u: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: u.path),
              let size = a[.size] as? NSNumber, let date = a[.modificationDate] as? Date else { return nil }
        return "\(size.int64Value)|\(Int64(date.timeIntervalSince1970 * 1000))"
    }
}
