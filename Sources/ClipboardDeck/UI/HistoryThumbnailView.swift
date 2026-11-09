import SwiftUI
import ClipboardCore

/// Requests are driven by visibility and completion events, never by body evaluation.
@MainActor
@available(macOS 14.0, *)
struct HistoryThumbnailView: View {
    @ObservedObject private var model: AppModel
    @StateObject private var presentation: ThumbnailPresentation
    private let copiedAt: Date

    init(entry: ClipEntry, model: AppModel, variant: ThumbnailVariant = .list) {
        self.model = model
        copiedAt = entry.copiedAt
        _presentation = StateObject(wrappedValue: model.thumbnailPresentation(for: entry, variant: variant))
    }

    var body: some View {
        Group {
            if let image = presentation.image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { presentation.appear() }
        .onDisappear { presentation.disappear() }
        .onChange(of: copiedAt) { _, _ in presentation.reload() }
        .onChange(of: model.thumbnailRevision) { _, _ in presentation.refresh() }
    }
}
