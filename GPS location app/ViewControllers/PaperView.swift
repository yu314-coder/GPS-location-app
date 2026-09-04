import SwiftUI
import PDFKit

/// The paper, read inside the app.
///
/// A copy ships with the binary so this screen works instantly, offline, and on a plane. That
/// copy is also the floor: the newest revision is fetched from the repository's release asset in
/// the background, but nothing about that fetch can leave the reader without a document. See
/// PaperStore — the download has to parse as a PDF before it is allowed to replace anything.
struct PaperView: View {
    @StateObject private var store = PaperStore.shared

    var body: some View {
        Group {
            if let url = store.url {
                PDFDocumentView(url: url)
                    .id(url)                       // reload the view when a newer copy lands
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) { banner }
            } else {
                EmptyStateCard(
                    icon: "doc.text.magnifyingglass",
                    title: "Paper unavailable",
                    message: "The document did not ship with this build."
                )
                .padding()
            }
        }
        .navigationTitle("The paper")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        if case .checking = store.status {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(store.status == .checking)
                    if let url = store.url {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
        }
        .task {
            // Check once per appearance. A conditional request costs a few hundred bytes when
            // nothing has changed, so this is not worth rationing further.
            await store.refresh()
        }
    }

    /// Only says something when there is something to say. A permanent "up to date" badge over
    /// the first paragraph would be noise on every single read.
    @ViewBuilder private var banner: some View {
        switch store.status {
        case .updated:
            label("Updated to the latest revision", icon: "checkmark.circle.fill", tint: .green)
        case .failed(let why):
            label("Showing the bundled copy — \(why)", icon: "wifi.exclamationmark", tint: .orange)
        case .bundled, .cached, .checking:
            EmptyView()
        }
    }

    private func label(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(text).lineLimit(2)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// PDFKit does the rendering. It handles selection, search and continuous scrolling for free,
/// which a WebView would not.
private struct PDFDocumentView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemGroupedBackground
        // Fit the page width on first appearance rather than showing a page-sized thumbnail.
        DispatchQueue.main.async {
            view.scaleFactor = view.scaleFactorForSizeToFit
            view.minScaleFactor = view.scaleFactorForSizeToFit
        }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}
