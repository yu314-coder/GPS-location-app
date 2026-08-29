import SwiftUI
import PDFKit

/// The paper, read inside the app.
///
/// It is bundled rather than fetched. The claims in it are about the build you are holding, and
/// a version that silently changed underneath the app it describes would be worse than none —
/// so it ships with the binary and works with no network at all.
struct PaperView: View {
    @State private var showingShare = false

    private var url: URL? {
        Bundle.main.url(forResource: "velocity_mode", withExtension: "pdf")
    }

    var body: some View {
        Group {
            if let url {
                PDFDocumentView(url: url)
                    .ignoresSafeArea(edges: .bottom)
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
            if let url {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
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

    func updateUIView(_ view: PDFView, context: Context) {}
}
