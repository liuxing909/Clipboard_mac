import AppKit
import Combine

/// Ownership for one visible image. A cache eviction must not turn every
/// completion-driven redraw into another decode request for an already shown image.
@MainActor
final class ThumbnailPresentation: ObservableObject {
    @Published private(set) var image: NSImage?
    private let provider: any ThumbnailProviding
    private let key: String
    private let url: URL?
    private let variant: ThumbnailVariant
    private var appeared = false
    private var invalidationID: UUID

    init(provider: any ThumbnailProviding, key: String, url: URL?, variant: ThumbnailVariant = .list) {
        self.provider = provider
        self.key = key
        self.url = url
        self.variant = variant
        invalidationID = provider.invalidationID
    }

    func appear() {
        appeared = true
        refresh()
    }

    func disappear() {
        appeared = false
        image = nil
    }

    /// A fresh copy may have repaired the backing image. Keep visibility intact:
    /// offscreen views must not start loading merely because their entry changed.
    func reload() {
        image = nil
        refresh()
    }

    func refresh() {
        if invalidationID != provider.invalidationID {
            invalidationID = provider.invalidationID
            image = nil
        }
        guard appeared, image == nil, let url else { return }
        image = provider.image(forKey: key, at: url, variant: variant)
    }
}
