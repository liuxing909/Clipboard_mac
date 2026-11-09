import AppKit
import SwiftUI
import ApplicationServices
import ClipboardCore

enum ClipFilter: String, CaseIterable, Identifiable {
    case all = "全部", text = "文字", image = "图片", files = "文件", pinned = "已固定"
    var id: String { rawValue }
    func includes(_ entry: ClipEntry) -> Bool {
        switch self {
        case .all: return true
        case .text: return entry.kind == .text || entry.kind == .richText
        case .image: return entry.kind == .image
        case .files: return entry.kind == .files
        case .pinned: return entry.isPinned
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var entries: [ClipEntry] = [] {
        didSet { cachedVisibleEntries = nil }
    }
    @Published var query = "" {
        didSet {
            if query != oldValue { selectArrivingCapture = false; cachedVisibleEntries = nil; normalizeSelection() }
        }
    }
    @Published var filter: ClipFilter = .all {
        didSet {
            if filter != oldValue { selectArrivingCapture = false; cachedVisibleEntries = nil; normalizeSelection() }
        }
    }
    @Published var selectedID: UUID? {
        didSet { if selectedID != oldValue { selectArrivingCapture = false } }
    }
    @Published var isPaused = false {
        didSet {
            guard oldValue != isPaused else { return }
            if isPaused {
                stopPolling()
                cancelCaptures()
            } else {
                guard store != nil else { isPaused = true; return }
                // Discard changes made while paused, even if the polling timer did not run.
                setCaptureBaseline(pasteboard?.changeCount ?? 0)
                schedulePolling()
            }
        }
    }
    @Published var accessibilityGranted = false
    @Published var toast: String?
    @Published var persistentError: String?
    @Published var showingSettings = false
    @Published var presentationID = UUID()
    @Published var hotkeyPreset = 0
    @Published private(set) var activeHotkeyPreset: Int?
    @Published private(set) var hotkeyWarning: HotkeyWarning?
    @Published var historyLimit = 200
    @Published private(set) var isPanelVisible = true
    @Published private(set) var thumbnailRevision: UInt64 = 0
    @Published private(set) var isPreparingCopy = false
    let isPreview: Bool
    private(set) var store: HistoryStore?
    private let poller: any ClipboardPolling
    private var monitoringRequested = false
    private var cachedVisibleEntries: [ClipEntry]?
    private var lastChangeCount = 0
    private struct CaptureState {
        let changeCount: Int
        var excludedDigests: Set<String> = []
    }
    private var retryCancelledCapture: CaptureState?
    private var unadmittedDeletion: CaptureState?
    private var toastTask: Task<Void, Never>?
    private let pasteboard: NSPasteboard?
    private let defaults: UserDefaults
    private let frontmostApplication: () -> NSRunningApplication?
    private let thumbnails: any ThumbnailProviding
    private let processing: ClipboardWorkScheduler
    private var captureGeneration: UInt64 = 0
    private var captureTasks: [UUID: CaptureState] = [:]
    private var copyTask: UUID?
    private var copyGeneration: UInt64 = 0
    private var selectArrivingCapture = false
    var isMonitoring: Bool { poller.isRunning }
    var thumbnailCacheCost: Int { thumbnails.totalCost }
    var captureExclusionCount: Int {
        captureTasks.values.reduce(0) { $0 + $1.excludedDigests.count }
            + (retryCancelledCapture?.excludedDigests.count ?? 0)
            + (unadmittedDeletion?.excludedDigests.count ?? 0)
    }
    private var isAwaitingLatestCapture: Bool {
        !captureTasks.isEmpty || retryCancelledCapture != nil
            || (!isPaused && pasteboard.map { $0.changeCount != lastChangeCount } == true)
    }
    private let excludedApps: Set<String> = [
        "com.apple.Passwords", "com.apple.keychainaccess",
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
    ]
    var onPaste: ((ClipEntry) -> Void)?
    var onDismiss: (() -> Void)?
    var onQuit: (() -> Void)?
    var onHotkeyChange: ((Int) -> Result<Void, HotkeyFailure>)?

    init(
        directory: URL, isPreview: Bool = false, pasteboard: NSPasteboard? = nil,
        defaults: UserDefaults = .standard,
        poller: (any ClipboardPolling)? = nil,
        thumbnails: (any ThumbnailProviding)? = nil,
        processing: ClipboardWorkScheduler? = nil,
        frontmostApplication: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    ) {
        self.isPreview = isPreview
        self.pasteboard = isPreview ? nil : (pasteboard ?? .general)
        self.defaults = defaults
        self.poller = poller ?? RunLoopClipboardPoller()
        self.thumbnails = thumbnails ?? ThumbnailPipeline()
        self.processing = processing ?? ClipboardWorkScheduler()
        self.frontmostApplication = frontmostApplication
        self.processing.onCancel = { [weak self] id in
            guard let self else { return }
            if let capture = self.captureTasks.removeValue(forKey: id),
                capture.changeCount == self.lastChangeCount
            {
                // Pressure cancellation must not permanently consume an uncommitted
                // clipboard change. Keep deletion exclusions for this version only;
                // cancellation of an older task must not poison a later explicit copy.
                self.retryCancelledCapture = capture
            }
            if self.copyTask == id {
                self.copyGeneration &+= 1
                self.copyTask = nil
                self.isPreparingCopy = false
                self.showToast("处理已取消，请稍后重试。")
            }
        }
        self.thumbnails.onChange = { [weak self] in
            guard let self else { return }
            self.thumbnailRevision &+= 1
        }
        if !isPreview {
            hotkeyPreset = min(2, max(0, defaults.integer(forKey: "hotkeyPreset")))
            let savedLimit = defaults.integer(forKey: "historyLimit")
            historyLimit = [100, 200, 500].contains(savedLimit) ? savedLimit : 200
        }
        do {
            store = try HistoryStore(directory: directory, maxItems: historyLimit)
            refresh()
        } catch {
            persistentError = error.localizedDescription
            isPaused = true
        }
    }

    var visibleEntries: [ClipEntry] {
        if let cachedVisibleEntries { return cachedVisibleEntries }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = entries.filter { entry in
            filter.includes(entry)
                && (q.isEmpty || entry.title.localizedCaseInsensitiveContains(q)
                    || entry.sourceApp.localizedCaseInsensitiveContains(q))
        }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.copiedAt > $1.copiedAt
        }
        cachedVisibleEntries = result
        return result
    }

    var shortcutLabel: String { HotkeyPresets.label(hotkeyPreset) }
    var isHotkeyAvailable: Bool { isPreview || activeHotkeyPreset != nil }
    var selectedEntry: ClipEntry? {
        let items = visibleEntries
        return items.first(where: { $0.id == selectedID }) ?? items.first
    }

    func startMonitoring() {
        guard let pasteboard, !monitoringRequested else { return }
        monitoringRequested = true
        setCaptureBaseline(pasteboard.changeCount)
        schedulePolling()
    }

    private func setCaptureBaseline(_ changeCount: Int) {
        lastChangeCount = changeCount
        retryCancelledCapture = nil
        unadmittedDeletion = nil
        if !isAwaitingLatestCapture { selectArrivingCapture = false }
    }

    private func schedulePolling() {
        guard monitoringRequested, !isPaused, store != nil, !poller.isRunning else { return }
        poller.start { [weak self] in
            self?.capturePendingCopy()
        }
    }

    private func stopPolling() { poller.stop() }

    func stopMonitoring() { monitoringRequested = false; stopPolling(); cancelCaptures() }

    private func cancelCaptures() {
        captureGeneration &+= 1
        let pending = Array(captureTasks.keys)
        captureTasks.removeAll()
        // Explicit cleanup also discards the current copy if a full queue or
        // pressure prevented us from taking its snapshot yet.
        setCaptureBaseline(pasteboard?.changeCount ?? lastChangeCount)
        selectArrivingCapture = false
        // Detach these identifiers before cancellation callbacks. Explicit pause,
        // stop and history cleanup deliberately discard their pending captures.
        for id in pending { processing.cancel(id) }
    }

    func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        thumbnails.setActive(visible)
        if !visible {
            showingSettings = false
        }
    }

    func prepareForPresentation() {
        query = ""
        showingSettings = false
        // A reopened list starts at the top; Return must target the visible first row.
        selectedID = visibleEntries.first?.id
        setPanelVisible(true)
        presentationID = UUID()
        // A panel opened immediately after copying initially shows old history.
        // Follow the arriving newest row unless the user changes selection/search.
        selectArrivingCapture = isAwaitingLatestCapture
    }

    /// Also called before opening the panel, so a recent copy need not wait for the timer.
    func capturePendingCopy() {
        guard !isPaused, let board = pasteboard, let store else { return }
        let changeCount = board.changeCount
        if unadmittedDeletion?.changeCount != changeCount { unadmittedDeletion = nil }
        guard changeCount != lastChangeCount || retryCancelledCapture != nil else { return }
        // When the queue is full, leave the change counter untouched so the next
        // poll can retry the newest clipboard without allocating another snapshot.
        guard processing.canSubmit else { return }
        let front = frontmostApplication()
        if let bundle = front?.bundleIdentifier, excludedApps.contains(bundle) {
            setCaptureBaseline(changeCount)
            return
        }
        do {
            guard let snapshot = try ClipboardAccess.snapshot(from: board) else {
                if board.changeCount == changeCount { setCaptureBaseline(changeCount) }
                return
            }
            guard board.changeCount == changeCount else { return }
            let generation = captureGeneration
            var exclusions =
                retryCancelledCapture?.changeCount == changeCount
                ? retryCancelledCapture?.excludedDigests ?? [] : []
            if let deletion = unadmittedDeletion, deletion.changeCount == changeCount {
                exclusions.formUnion(deletion.excludedDigests)
            }
            let source = front?.localizedName ?? "其他应用"
            let copiedAt = Date()
            var taskID: UUID?
            taskID = processing.submit(
                byteCount: snapshot.byteCount,
                work: {
                    try ClipboardAccess.process(snapshot)
                },
                completion: { [weak self] result in
                    guard let self else { return }
                    guard let taskID, let capture = self.captureTasks.removeValue(forKey: taskID) else { return }
                    defer {
                        if !self.isAwaitingLatestCapture {
                            self.selectArrivingCapture = false
                        }
                    }
                    guard generation == self.captureGeneration, !self.isPaused else { return }
                    do {
                        guard let payload = try result.get() else { return }
                        // Store mutations remain serialized on the main actor. Only
                        // immutable snapshots and format processing cross threads.
                        let capturedID = try store.add(
                            payload, sourceApp: source, at: copiedAt, excludingDigests: capture.excludedDigests)
                        if case .image = payload,
                            let image = store.entries.first(where: { $0.id == capturedID })
                        {
                            // Recopy can repair a corrupt sidecar. Retire failed or
                            // stale decodes for this image, without touching other keys.
                            self.thumbnails.remove(forKey: image.digest)
                        }
                        let followNewest = self.selectArrivingCapture && self.isPanelVisible
                        self.refresh()
                        if followNewest {
                            self.selectedID = self.visibleEntries.first?.id
                            self.selectArrivingCapture = self.isAwaitingLatestCapture
                        }
                    } catch HistoryError.excludedContent {
                        // The user deleted this content after it was queued.
                    } catch { self.showToast(error.localizedDescription) }
                })
            if let taskID {
                captureTasks[taskID] = CaptureState(changeCount: changeCount, excludedDigests: exclusions)
                setCaptureBaseline(changeCount)
            }
        } catch ClipboardAccess.FormatError.changedDuringCapture {
            // Clipboard metadata can be temporarily unavailable without a version
            // change. Let the existing poll retry instead of consuming this copy.
        } catch {
            if board.changeCount == changeCount { setCaptureBaseline(changeCount) }
            showToast(error.localizedDescription)
        }
    }

    func refresh() {
        entries = store?.entries ?? []
        normalizeSelection()
    }

    func normalizeSelection() {
        let items = visibleEntries
        if !items.contains(where: { $0.id == selectedID }), selectedID != items.first?.id {
            selectedID = items.first?.id
        }
    }

    func moveSelection(_ delta: Int) {
        let items = visibleEntries
        guard !items.isEmpty else { return }
        let index = items.firstIndex(where: { $0.id == selectedID }) ?? 0
        let next = items[min(items.count - 1, max(0, index + delta))].id
        if selectedID != next { selectedID = next }
    }

    func pasteSelected() {
        if selectArrivingCapture && isAwaitingLatestCapture {
            showToast("正在保存最新复制的内容，请稍候。")
            return
        }
        guard let entry = selectedEntry else { return }
        onPaste?(entry)
    }

    @discardableResult
    func copy(_ entry: ClipEntry, to destination: NSPasteboard? = nil) -> Bool {
        guard !isPreview, let store, let board = destination ?? pasteboard else { return false }
        do {
            guard try ClipboardAccess.write(entry, store: store, to: board) else {
                showToast("复制失败，请重试。")
                return false
            }
            if board.name == pasteboard?.name { setCaptureBaseline(board.changeCount) }
            return true
        } catch { showToast(error.localizedDescription); return false }
    }

    func copyOnly(_ entry: ClipEntry) {
        copyPrepared(entry) { [weak self] success in
            if success { self?.showToast("已复制，可以按 ⌘V 粘贴。") }
        }
    }

    /// The UI uses this path; synchronous copy is retained for isolated probes.
    func copyPrepared(
        _ entry: ClipEntry, to destination: NSPasteboard? = nil,
        completion: @escaping (Bool) -> Void
    ) {
        cancelPreparedCopy()
        guard !isPreview, let store, let board = destination ?? pasteboard else {
            completion(false)
            return
        }
        let directory = store.directory
        let changeCount = board.changeCount
        let generation = copyGeneration
        isPreparingCopy = true
        // A paste job holds one bounded sidecar/input at a time. Decoded pixels
        // and the prepared output have their own format limits.
        copyTask = processing.submit(
            byteCount: entry.byteCount,
            work: {
                try ClipboardAccess.prepareWrite(entry, directory: directory)
            },
            completion: { [weak self] result in
                guard let self, generation == self.copyGeneration else { return }
                self.copyTask = nil
                self.isPreparingCopy = false
                do {
                    let prepared = try result.get()
                    guard self.entries.contains(where: { $0.id == entry.id && $0.digest == entry.digest }) else {
                        completion(false)
                        return
                    }
                    // Do not overwrite a new copy made while preparation was running.
                    guard board.changeCount == changeCount else {
                        self.showToast("剪贴板已有新内容，本次粘贴已取消。")
                        completion(false)
                        return
                    }
                    guard try ClipboardAccess.commit(prepared, to: board) else {
                        self.showToast("复制失败，请重试。")
                        completion(false)
                        return
                    }
                    if board.name == self.pasteboard?.name { self.setCaptureBaseline(board.changeCount) }
                    completion(true)
                } catch {
                    self.showToast(error.localizedDescription)
                    completion(false)
                }
            })
        if copyTask == nil {
            isPreparingCopy = false
            showToast("正在处理其他内容或内存紧张，请稍后重试。")
            completion(false)
        }
    }

    func cancelPreparedCopy() {
        copyGeneration &+= 1
        let previous = copyTask
        copyTask = nil
        isPreparingCopy = false
        if let previous { processing.cancel(previous) }
    }

    func togglePin(_ entry: ClipEntry) {
        do { try store?.togglePin(entry.id); refresh() } catch { showToast(error.localizedDescription) }
    }

    func remove(_ entry: ClipEntry) {
        do {
            cancelPreparedCopy()
            let removedDigest = store?.entries.first(where: { $0.id == entry.id })?.digest
            try store?.remove(entry.id)
            // Suppress only this deleted content in captures already queued before
            // the deletion. Other pending copies and future explicit copies survive.
            if let removedDigest {
                for id in Array(captureTasks.keys) { captureTasks[id]?.excludedDigests.insert(removedDigest) }
                retryCancelledCapture?.excludedDigests.insert(removedDigest)
                if let changeCount = pasteboard?.changeCount, changeCount != lastChangeCount {
                    if unadmittedDeletion?.changeCount != changeCount {
                        unadmittedDeletion = CaptureState(changeCount: changeCount)
                    }
                    unadmittedDeletion?.excludedDigests.insert(removedDigest)
                }
            }
            thumbnails.remove(forKey: entry.digest)
            refresh()
        } catch { showToast(error.localizedDescription) }
    }

    func clear(keepingPinned: Bool) {
        cancelPreparedCopy()
        do {
            try store?.clear(keepingPinned: keepingPinned)
            cancelCaptures()
            thumbnails.removeAll()
            refresh()
        } catch {
            showToast(error.localizedDescription)
        }
    }

    func setLimit(_ value: Int) {
        do {
            try store?.applyLimit(value)
            historyLimit = value
            if !isPreview { defaults.set(value, forKey: "historyLimit") }
            refresh()
        } catch { showToast(error.localizedDescription) }
    }

    func setHotkey(_ value: Int) {
        guard HotkeyPresets.labels.indices.contains(value) else { return }
        if value == hotkeyPreset, activeHotkeyPreset == value {
            hotkeyWarning = nil
            return
        }
        applyHotkey(value)
    }

    func activateHotkey() { applyHotkey(hotkeyPreset) }

    private func applyHotkey(_ value: Int) {
        let result: Result<Void, HotkeyFailure> =
            isPreview ? .success(()) : (onHotkeyChange?(value) ?? .failure(.handlerUnavailable))
        switch result {
        case .success:
            activeHotkeyPreset = value
            hotkeyPreset = value
            hotkeyWarning = nil
            if !isPreview { defaults.set(value, forKey: "hotkeyPreset") }
        case .failure(let error):
            hotkeyWarning = HotkeyWarning(preset: value, failure: error, retainedPreset: activeHotkeyPreset)
        }
    }

    func refreshAccessibility() {
        accessibilityGranted = isPreview || AXIsProcessTrusted()
    }

    func openAccessibilitySettings() {
        guard !isPreview else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func image(for entry: ClipEntry) -> NSImage? {
        guard isPanelVisible, let url = store?.imageURL(for: entry) else { return nil }
        return thumbnails.image(forKey: entry.digest, at: url)
    }

    func thumbnailPresentation(for entry: ClipEntry, variant: ThumbnailVariant = .list) -> ThumbnailPresentation {
        ThumbnailPresentation(
            provider: thumbnails, key: entry.digest, url: store?.imageURL(for: entry), variant: variant)
    }

    func showToast(_ value: String) {
        toastTask?.cancel()
        toast = value
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
