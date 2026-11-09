import AppKit
import ClipboardCore

@MainActor
enum AppModelSelfTests {
    static func run(directory: URL, board: NSPasteboard) throws {
        let suite = "ClipboardDeck-self-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        board.clearContents()
        board.setString("before launch", forType: .string)
        let poller = ManualClipboardPoller()
        let model = AppModel(
            directory: directory, pasteboard: board, defaults: defaults, poller: poller,
            processing: ClipboardWorkScheduler(observesMemoryPressure: false),
            frontmostApplication: { nil })
        model.startMonitoring()
        defer { model.stopMonitoring() }
        try check(model.isMonitoring, "monitoring starts its timer")
        model.capturePendingCopy()
        try check(model.entries.isEmpty, "startup does not capture pre-existing content")

        board.clearContents()
        board.setString("just copied", forType: .string)
        model.startMonitoring()  // Repeated startup must not reset the capture baseline.
        try check(poller.startCount == 1, "poller injection preserves idempotent monitoring")
        model.capturePendingCopy()
        try check(
            SelfTestWait.until { model.entries.count == 1 } && model.entries.first?.text == "just copied",
            "opening immediately after copying schedules capture without a timer tick")
        model.capturePendingCopy()
        try check(model.entries.first?.copyCount == 1, "unchanged clipboard is captured once")

        model.isPaused = true
        try check(!model.isMonitoring, "pause stops polling entirely")
        board.clearContents()
        board.setString("copied while paused", forType: .string)
        model.isPaused = false
        try check(model.isMonitoring, "resume restarts requested monitoring")
        model.capturePendingCopy()
        try check(model.entries.count == 1, "resume discards copies made during pause")
        board.clearContents()
        board.setString("copied after resume", forType: .string)
        poller.fire()
        try check(
            SelfTestWait.until { model.entries.count == 2 },
            "injected polling callback captures new copies after resume")
        let entry = model.entries[0]
        try check(model.copy(entry), "history entry can be written to private pasteboard")
        model.capturePendingCopy()
        try check(
            model.entries.count == 2 && model.entries[0].copyCount == 1,
            "writing a history entry does not record it again")

        model.onHotkeyChange = { _ in .failure(.systemReserved) }
        model.activateHotkey()
        try check(
            !model.isHotkeyAvailable && model.hotkeyWarning?.retainedPreset == nil
                && model.hotkeyWarning?.failure == .systemReserved
                && model.hotkeyWarning?.message.contains("菜单栏") == true,
            "startup conflict reports no active shortcut and the menu-bar fallback")
        model.onHotkeyChange = { _ in .success(()) }
        model.setHotkey(0)
        try check(
            model.isHotkeyAvailable && model.hotkeyWarning == nil,
            "retry can activate the unchanged saved preset after startup failure")
        model.onHotkeyChange = { _ in .failure(.occupied) }
        model.setHotkey(1)
        try check(
            model.hotkeyPreset == 0 && defaults.integer(forKey: "hotkeyPreset") == 0,
            "registration failure preserves displayed and saved shortcut")
        try check(
            model.hotkeyWarning?.preset == 1 && model.hotkeyWarning?.retainedPreset == 0
                && model.hotkeyWarning?.title == "快捷键冲突" && model.isHotkeyAvailable,
            "replacement conflict names the rejected chord and retained active shortcut")
        model.showToast("unrelated clipboard message")
        try check(model.hotkeyWarning != nil, "clipboard notifications do not erase the persistent hotkey warning")
        model.onHotkeyChange = { _ in .failure(.registrationFailed(-1)) }
        model.setHotkey(2)
        try check(
            model.hotkeyWarning?.title == "快捷键未启用" && model.hotkeyPreset == 0,
            "non-conflict system errors are not mislabeled as conflicts")
        var registrations = 0
        model.onHotkeyChange = { _ in
            registrations += 1; return .success(())
        }
        model.setHotkey(1)
        model.setHotkey(1)
        model.setHotkey(3)
        try check(
            model.hotkeyPreset == 1 && defaults.integer(forKey: "hotkeyPreset") == 1 && registrations == 1
                && model.hotkeyWarning == nil && model.activeHotkeyPreset == 1,
            "only a successful changed shortcut is persisted")
        try checkFilteringAndResources(model)
        try checkFormatFiltering(model)
        try checkBackgroundOperations(directory: directory.appendingPathComponent("background"), defaults: defaults)
        try checkRepeatedCaptureLifecycle(
            directory: directory.appendingPathComponent("capture-stress"), defaults: defaults)
        try checkRecopyRepairsFailedThumbnail(
            directory: directory.appendingPathComponent("thumbnail-repair"), defaults: defaults)
        try checkSingleDeletionDuringCapture(
            directory: directory.appendingPathComponent("single-delete"), defaults: defaults)
        try checkPasteSelectionDuringPressureRetry(
            directory: directory.appendingPathComponent("retry-selection"), defaults: defaults)
        try checkUnadmittedCaptureBoundaries(
            directory: directory.appendingPathComponent("unadmitted"), defaults: defaults)
        model.stopMonitoring()
        model.isPaused = true
        model.isPaused = false
        try check(!model.isMonitoring, "resume cannot restart explicitly stopped monitoring")
        print(
            "PASS: immediate capture / startup baseline / pause-resume / own-copy suppression / shortcut settings rollback"
        )
    }

    private static func checkFilteringAndResources(_ model: AppModel) throws {
        let old = model.entries[1]
        model.query = "just copied"
        try check(
            model.visibleEntries.map(\.id) == [old.id] && model.selectedID == old.id,
            "query changes refresh results and selection")
        model.filter = .image
        try check(
            model.visibleEntries.isEmpty && model.selectedID == nil,
            "kind changes invalidate filtered results")
        model.query = ""
        model.filter = .all
        model.togglePin(old)
        try check(
            model.visibleEntries.first?.id == old.id && model.visibleEntries.first?.isPinned == true,
            "pin updates invalidate sorting")
        model.query = "中文"
        let id = try model.store!.add(.text("中文测试"), sourceApp: "Test")
        model.refresh()
        try check(
            model.visibleEntries.map(\.id) == [id] && model.selectedID == id,
            "new captures refresh active search results")
        model.remove(model.visibleEntries[0])
        try check(
            model.visibleEntries.isEmpty && model.selectedID == nil,
            "deletion removes cached search results")
        model.query = ""
        model.moveSelection(1)
        try check(
            model.visibleEntries.count == 2 && model.selectedID != old.id,
            "keyboard navigation uses the same ordered results")

        let png = try PreviewSupport.png(PreviewSupport.sampleImage())
        let imageID = try model.store!.add(.image(png: png, width: 800, height: 400), sourceApp: "Test")
        model.refresh()
        let image = model.entries.first { $0.id == imageID }!
        try check(
            SelfTestWait.until { model.image(for: image) != nil } && model.thumbnailCacheCost > 0,
            "thumbnail is loaded asynchronously and cached on demand")
        model.setPanelVisible(false)
        try check(
            !model.isPanelVisible && model.thumbnailCacheCost == 0 && model.entries.count == 3,
            "hiding releases thumbnails without deleting history")
        model.prepareForPresentation()
        try check(
            model.selectedID == model.visibleEntries.first?.id,
            "reopening selects the first visible row instead of an offscreen old selection")
        try check(
            SelfTestWait.until { model.image(for: image) != nil } && model.thumbnailCacheCost > 0,
            "thumbnail reloads asynchronously after reopening")
        model.setPanelVisible(false)
        print(
            "PASS: filtered-result invalidation / selection / pin ordering / hidden-panel cache release / thumbnail reload"
        )
    }

    private static func check(_ passed: Bool, _ message: String) throws {
        if !passed { throw PreviewSupport.TestError.failed(message) }
    }

    private static func checkRecopyRepairsFailedThumbnail(directory: URL, defaults: UserDefaults) throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let scheduler = ClipboardWorkScheduler(observesMemoryPressure: false)
        let thumbnails = ThumbnailPipeline(observesMemoryPressure: false)
        let model = AppModel(
            directory: directory, pasteboard: board, defaults: defaults,
            poller: ManualClipboardPoller(), thumbnails: thumbnails, processing: scheduler,
            frontmostApplication: { nil })
        model.startMonitoring()
        defer { model.stopMonitoring(); model.cancelPreparedCopy(); thumbnails.removeAll() }
        let png = try PreviewSupport.png(PreviewSupport.sampleImage())
        guard let store = model.store else { throw PreviewSupport.TestError.failed("thumbnail repair store") }
        let id = try store.add(.image(png: png, width: 800, height: 400), sourceApp: "Test")
        model.refresh()
        guard let original = model.entries.first, let file = store.imageURL(for: original) else {
            throw PreviewSupport.TestError.failed("thumbnail repair entry")
        }
        try Data("not a PNG".utf8).write(to: file)
        try check(model.image(for: original) == nil && thumbnails.pendingRequestCount == 1, "bad image requests decode")
        try check(
            SelfTestWait.until { thumbnails.pendingRequestCount == 0 } && thumbnails.totalCost == 0,
            "bad image finishes without a cached thumbnail")
        try check(
            model.image(for: original) == nil && thumbnails.pendingRequestCount == 0,
            "failed thumbnail is remembered until fresh content arrives")

        board.clearContents()
        board.setData(png, forType: .png)
        model.capturePendingCopy()
        try check(
            SelfTestWait.until { scheduler.outstandingCount == 0 && model.entries.first?.copyCount == 2 },
            "fresh copy repairs the same image history entry")
        try check(try Data(contentsOf: file) == png && model.entries.first?.id == id, "original PNG bytes repaired")
        let repaired = model.entries[0]
        try check(
            model.isPanelVisible && SelfTestWait.until { model.image(for: repaired) != nil },
            "recopy of repaired image retries its failed thumbnail without closing the panel")

        // A corrupt sidecar can still be a decodable PNG with wrong pixels.
        // Exercise the image retained by an already visible SwiftUI presentation.
        let wrongPixels = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")!
        thumbnails.remove(forKey: repaired.digest)
        try wrongPixels.write(to: file)
        let presentation = model.thumbnailPresentation(for: repaired)
        defer { presentation.disappear() }
        presentation.appear()
        try check(
            SelfTestWait.until {
                presentation.refresh(); return presentation.image?.size.width == 1
            },
            "visible presentation retains the wrong pixels from a decodable corrupt file")
        board.clearContents()
        board.setData(png, forType: .png)
        model.capturePendingCopy()
        try check(
            SelfTestWait.until { scheduler.outstandingCount == 0 && model.entries.first?.copyCount == 3 },
            "second fresh copy repairs a decodable corrupt sidecar")
        try check(model.entries[0].copiedAt != repaired.copiedAt, "fresh copy publishes a changed presentation date")
        // HistoryThumbnailView calls this when copiedAt changes. A cache removal
        // alone cannot discard the separate NSImage owned by a visible row.
        presentation.reload()
        try check(
            SelfTestWait.until {
                presentation.refresh(); return (presentation.image?.size.width ?? 0) > 1
            },
            "visible presentation reloads repaired pixels")
        presentation.disappear()
        thumbnails.remove(forKey: repaired.digest)
        presentation.reload()
        try check(
            presentation.image == nil && thumbnails.pendingRequestCount == 0,
            "recopy refresh does not activate an offscreen presentation")
        print(
            "STRESS CASE: corrupt thumbnail / recopy repairs PNG / failure and displayed-pixel recovery / hidden reload"
        )
    }

    private static func checkSingleDeletionDuringCapture(directory: URL, defaults: UserDefaults) throws {
        enum Timing: String, CaseIterable {
            case normal, pressureBefore, pressureAfter, newDuringPressure, newerPending, clear, pause, stop
        }
        for (index, scenario) in Timing.allCases.flatMap({ timing in
            [false, true].map { (timing, $0) }
        }).enumerated() {
            let (timing, sameContent) = scenario
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            // One held fixture job allows two real captures to be queued together.
            let scheduler = ClipboardWorkScheduler(maxOutstanding: 3, observesMemoryPressure: false)
            let model = AppModel(
                directory: directory.appendingPathComponent("case-\(index)"),
                pasteboard: board, defaults: defaults, poller: ManualClipboardPoller(), processing: scheduler,
                frontmostApplication: { nil })
            model.startMonitoring()
            defer { model.stopMonitoring(); model.cancelPreparedCopy() }
            guard let store = model.store else { throw PreviewSupport.TestError.failed("single-delete store") }
            let removedText = "remove only this record"
            let id = try store.add(.text(removedText), sourceApp: "Test")
            model.refresh()
            let removed = model.entries[0]
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            _ = scheduler.submit(
                byteCount: 0,
                work: {
                    _ = gate.wait(timeout: .now() + 5); return true
                }, completion: { _ in })
            let pendingText = sameContent ? removedText : "unrelated new copy must survive"
            board.clearContents()
            board.setString(pendingText, forType: .string)
            model.capturePendingCopy()
            try check(scheduler.outstandingCount == 2, "single-delete fixture queues a capture")
            if timing == .pressureBefore { scheduler.setMemoryPressure(isElevated: true) }
            model.remove(removed)
            try check(model.captureExclusionCount == 1, "deletion only marks already pending content")
            if timing == .newerPending {
                board.clearContents()
                board.setString(removedText, forType: .string)
                model.capturePendingCopy()
                try check(scheduler.outstandingCount == 3, "a newer explicit copy has its own pending version")
            }
            if [.pressureAfter, .newDuringPressure, .newerPending].contains(timing) {
                scheduler.setMemoryPressure(isElevated: true)
            }
            if timing == .newDuringPressure {
                board.clearContents()
                board.setString(removedText, forType: .string)
                model.capturePendingCopy()
            }
            switch timing {
            case .clear: model.clear(keepingPinned: false)
            case .pause: model.isPaused = true; model.isPaused = false
            case .stop: model.stopMonitoring(); model.startMonitoring()
            default: break
            }
            if [.clear, .pause, .stop, .newerPending].contains(timing) {
                try check(model.captureExclusionCount == 0, "cancelled or superseded deletion exclusions are released")
            }
            scheduler.setMemoryPressure(isElevated: false)
            gate.signal()
            try check(SelfTestWait.until { scheduler.outstandingCount == 0 }, "single-delete capture drains")
            model.capturePendingCopy()
            try check(SelfTestWait.until { scheduler.outstandingCount == 0 }, "post-pressure retry drains")
            try check(model.captureExclusionCount == 0, "finished captures release all deletion exclusions")
            try check(!model.entries.contains { $0.id == id }, "explicitly deleted entry stays deleted")
            if [.newDuringPressure, .newerPending].contains(timing) {
                try check(
                    model.entries.first?.text == removedText, "a new clipboard version never inherits an old deletion")
            } else if sameContent || [.clear, .pause, .stop].contains(timing) {
                try check(model.entries.isEmpty, "capture queued before deletion cannot resurrect deleted content")
            } else {
                try check(
                    model.entries.first?.text == pendingText,
                    "deleting an old row must not discard an unrelated pending copy")
            }
            // A later, explicit copy is a new user action and may restore the content.
            board.clearContents()
            board.setString(removedText, forType: .string)
            model.capturePendingCopy()
            try check(
                SelfTestWait.until {
                    scheduler.outstandingCount == 0 && model.entries.first?.text == removedText
                } && model.entries.first?.id != id,
                "copy made after deletion is accepted as a new record")
        }
        print(
            "STRESS CASE: 16 deletion/capture sequences / unrelated copy / pressure retry / no resurrection / newer copy / exclusion release"
        )
    }

    private static func checkPasteSelectionDuringPressureRetry(directory: URL, defaults: UserDefaults) throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let scheduler = ClipboardWorkScheduler(observesMemoryPressure: false)
        let model = AppModel(
            directory: directory, pasteboard: board, defaults: defaults,
            poller: ManualClipboardPoller(), processing: scheduler, frontmostApplication: { nil })
        model.startMonitoring()
        defer { model.stopMonitoring(); model.cancelPreparedCopy() }
        guard let store = model.store else { throw PreviewSupport.TestError.failed("retry-selection store") }
        let older = try store.add(
            .text("older selectable entry"), sourceApp: "Test", at: Date(timeIntervalSince1970: 1))
        let old = try store.add(.text("old selected entry"), sourceApp: "Test", at: Date(timeIntervalSince1970: 2))
        model.refresh()
        var pasted: [String] = []
        model.onPaste = { pasted.append($0.text ?? "") }
        func holdWorker() -> DispatchSemaphore {
            let gate = DispatchSemaphore(value: 0)
            _ = scheduler.submit(
                byteCount: 0,
                work: {
                    _ = gate.wait(timeout: .now() + 5); return true
                }, completion: { _ in })
            return gate
        }
        let pressureGate = holdWorker()
        defer { pressureGate.signal() }
        board.clearContents(); board.setString("latest pending entry", forType: .string)
        model.capturePendingCopy()
        model.prepareForPresentation()
        scheduler.setMemoryPressure(isElevated: true)
        model.pasteSelected()
        try check(pasted.isEmpty, "pressure retry must not silently paste an older selected entry")
        model.selectedID = older
        model.pasteSelected()
        try check(pasted == ["older selectable entry"], "explicit selection can paste while latest capture waits")
        model.prepareForPresentation()
        pressureGate.signal()
        try check(SelfTestWait.until { scheduler.outstandingCount == 0 }, "cancelled selection work drains")
        model.pasteSelected()
        try check(pasted.count == 1, "reopened panel still waits for pressure retry with no active tasks")
        scheduler.setMemoryPressure(isElevated: false)
        model.capturePendingCopy()
        try check(SelfTestWait.until { scheduler.outstandingCount == 0 }, "selection retry completes")
        model.pasteSelected()
        try check(pasted.last == "latest pending entry" && pasted.count == 2, "completed retry pastes newest history")

        // A deleted in-flight payload ends the wait, including when deleting it
        // does not change the visible selection (the pinned filter hides it).
        let latest = model.entries.first { $0.text == "latest pending entry" }!
        model.togglePin(model.entries.first { $0.id == old }!)
        model.filter = .pinned
        let deletionGate = holdWorker()
        defer { deletionGate.signal() }
        board.clearContents(); board.setString("latest pending entry", forType: .string)
        model.capturePendingCopy()
        model.prepareForPresentation()
        model.remove(latest)
        deletionGate.signal()
        try check(SelfTestWait.until { scheduler.outstandingCount == 0 }, "excluded selection work completes")
        let laterGate = holdWorker()
        defer { laterGate.signal() }
        board.clearContents(); board.setString("later unrelated capture", forType: .string)
        model.capturePendingCopy()
        model.pasteSelected()
        try check(
            pasted.last == "old selected entry" && pasted.count == 3, "excluded task releases the old opening wait")
        model.stopMonitoring()
        laterGate.signal()
        try check(SelfTestWait.until { scheduler.outstandingCount == 0 }, "selection test releases pending work")
        try check(model.captureExclusionCount == 0, "selection recovery retains no deletion exclusions")
        print(
            "STRESS CASE: pressure retry selection / explicit old-row selection / retry arrival / excluded-task wait release"
        )
    }

    private static func checkUnadmittedCaptureBoundaries(directory: URL, defaults: UserDefaults) throws {
        var failures: [String] = []
        for action in [
            "delete", "delete-new", "delete-pressure", "clear", "clear-pressure", "selection", "failed-clear",
            "failed-clear-unadmitted",
        ] {
            do {
                try checkUnadmittedCapture(
                    action: action, directory: directory.appendingPathComponent(action), defaults: defaults)
            } catch { failures.append("\(action): \(error)") }
        }
        try check(failures.isEmpty, failures.joined(separator: " | "))
        print(
            "STRESS CASE: full queue before snapshot / deletion and clear cutoff / latest-selection wait / failed-clear preservation"
        )
    }

    private static func checkUnadmittedCapture(action: String, directory: URL, defaults: UserDefaults) throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let scheduler = ClipboardWorkScheduler(observesMemoryPressure: false)
        let model = AppModel(
            directory: directory, pasteboard: board, defaults: defaults,
            poller: ManualClipboardPoller(), processing: scheduler, frontmostApplication: { nil })
        model.startMonitoring()
        defer { model.stopMonitoring(); model.cancelPreparedCopy() }
        guard let store = model.store else { throw PreviewSupport.TestError.failed("unadmitted store") }
        try store.add(.text("old history"), sourceApp: "Test")
        model.refresh()
        let old = model.entries[0]
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        _ = scheduler.submit(
            byteCount: 0,
            work: {
                _ = gate.wait(timeout: .now() + 5); return true
            }, completion: { _ in })
        if action != "failed-clear" {
            _ = scheduler.submit(byteCount: 0, work: { true }, completion: { _ in })
        }
        let latest = action.hasPrefix("delete") ? "old history" : "new copy before \(action)"
        board.clearContents(); board.setString(latest, forType: .string)
        model.capturePendingCopy()
        try check(scheduler.outstandingCount == 2, "boundary fixture fills both queue slots")
        if action.hasSuffix("pressure") { scheduler.setMemoryPressure(isElevated: true) }
        switch action {
        case "delete", "delete-pressure", "delete-new":
            model.remove(old)
            if action == "delete-new" {
                board.clearContents(); board.setString("old history", forType: .string)
                model.capturePendingCopy()
            }
        case "clear", "clear-pressure": model.clear(keepingPinned: false)
        case "selection":
            var pasted = 0
            model.onPaste = { _ in pasted += 1 }
            model.prepareForPresentation()
            model.pasteSelected()
            try check(pasted == 0, "opening while the latest copy has not entered the queue cannot paste old history")
        default:
            let manifest = directory.appendingPathComponent("history.json")
            let backup = directory.appendingPathComponent("history.backup")
            try FileManager.default.moveItem(at: manifest, to: backup)
            try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
            model.clear(keepingPinned: false)
            try FileManager.default.removeItem(at: manifest)
            try FileManager.default.moveItem(at: backup, to: manifest)
            try check(model.entries.map(\.id) == [old.id], "failed clear preserves old in-memory history")
        }
        gate.signal()
        try check(SelfTestWait.until { scheduler.outstandingCount == 0 }, "boundary fixture releases its queue")
        scheduler.setMemoryPressure(isElevated: false)
        model.capturePendingCopy()
        try check(SelfTestWait.until { scheduler.outstandingCount == 0 }, "latest pending clipboard is handled")
        switch action {
        case "delete", "delete-pressure":
            try check(model.entries.isEmpty, "delete excludes the latest copy even before snapshot admission")
        case "clear", "clear-pressure":
            try check(model.entries.isEmpty, "clear discards copies made before it even without a queued snapshot")
        default:
            try check(
                model.entries.first?.text == latest, "failed clear or delayed admission must not lose the new copy")
        }
        try check(model.captureExclusionCount == 0, "unadmitted deletion state releases after handling the version")
        board.clearContents(); board.setString("old history", forType: .string)
        model.capturePendingCopy()
        try check(
            SelfTestWait.until { scheduler.outstandingCount == 0 && model.entries.first?.text == "old history" },
            "an explicit new clipboard version remains eligible after boundary handling")
    }

    private static func checkBackgroundOperations(directory: URL, defaults: UserDefaults) throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let scheduler = ClipboardWorkScheduler(observesMemoryPressure: false)
        let model = AppModel(
            directory: directory, pasteboard: board, defaults: defaults,
            poller: ManualClipboardPoller(), processing: scheduler,
            frontmostApplication: { nil })
        model.startMonitoring()
        defer { model.stopMonitoring(); model.cancelPreparedCopy() }
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        _ = scheduler.submit(
            byteCount: 0,
            work: {
                gate.wait(); return true
            }, completion: { _ in })
        board.clearContents(); board.setString("captured snapshot", forType: .string)
        model.capturePendingCopy()
        try check(
            model.entries.isEmpty && scheduler.outstandingCount == 2,
            "capture returns while format work waits off the main thread")
        board.clearContents(); board.setString("newer copy", forType: .string)
        model.capturePendingCopy()  // Full queue must not consume the change counter.
        gate.signal()
        try check(
            SelfTestWait.until { scheduler.outstandingCount == 0 } && model.entries.first?.text == "captured snapshot",
            "snapshot remains immutable after the system clipboard changes")
        model.capturePendingCopy()
        try check(
            SelfTestWait.until { model.entries.count == 2 } && model.entries.first?.text == "newer copy",
            "queue saturation retries the latest change on the next poll")

        let selectionGate = DispatchSemaphore(value: 0)
        defer { selectionGate.signal() }
        _ = scheduler.submit(
            byteCount: 0,
            work: {
                selectionGate.wait(); return true
            }, completion: { _ in })
        board.clearContents(); board.setString("newest on opening", forType: .string)
        model.capturePendingCopy()
        model.prepareForPresentation()
        var pasteRequests = 0
        model.onPaste = { _ in pasteRequests += 1 }
        model.pasteSelected()
        try check(pasteRequests == 0, "Return cannot accidentally paste old history while opening capture is pending")
        selectionGate.signal()
        try check(
            SelfTestWait.until { scheduler.outstandingCount == 0 } && model.selectedEntry?.text == "newest on opening",
            "opening follows the arriving newest capture")
        model.onPaste = nil

        let saved = model.entries[0]
        let pasteGate = DispatchSemaphore(value: 0)
        defer { pasteGate.signal() }
        _ = scheduler.submit(
            byteCount: 0,
            work: {
                pasteGate.wait(); return true
            }, completion: { _ in })
        var pasteResult: Bool?
        model.copyPrepared(saved) { pasteResult = $0 }
        try check(model.isPreparingCopy, "UI exposes asynchronous paste preparation")
        board.clearContents(); board.setString("user copied while preparing", forType: .string)
        let before = board.changeCount
        pasteGate.signal()
        try check(
            SelfTestWait.until { pasteResult != nil } && pasteResult == false && board.changeCount == before
                && board.string(forType: .string) == "user copied while preparing",
            "late preparation cannot overwrite a newer user copy")
        try check(!model.isPreparingCopy, "failed preparation releases the busy state")

        pasteResult = nil
        model.copyPrepared(saved) { pasteResult = $0 }
        try check(
            SelfTestWait.until { pasteResult != nil } && pasteResult == true
                && board.string(forType: .string) == saved.text, "prepared copy commits successfully")

        let clearGate = DispatchSemaphore(value: 0)
        defer { clearGate.signal() }
        _ = scheduler.submit(
            byteCount: 0,
            work: {
                clearGate.wait(); return true
            }, completion: { _ in })
        board.clearContents(); board.setString("must not reappear", forType: .string)
        model.capturePendingCopy()
        model.clear(keepingPinned: false)
        clearGate.signal()
        try check(
            SelfTestWait.until { scheduler.outstandingCount == 0 } && model.entries.isEmpty,
            "clearing history invalidates pending captures without resurrecting entries")

        let pinID = try model.store!.add(.text("pressure fixture"), sourceApp: "Test")
        model.refresh()
        let pressureEntry = model.entries.first { $0.id == pinID }!
        let pressureGate = DispatchSemaphore(value: 0)
        defer { pressureGate.signal() }
        _ = scheduler.submit(
            byteCount: 0,
            work: {
                pressureGate.wait(); return true
            }, completion: { _ in })
        model.copyPrepared(pressureEntry) { _ in }
        scheduler.setMemoryPressure(isElevated: true)
        try check(!model.isPreparingCopy, "pressure cancellation clears paste progress")
        pressureGate.signal()
        try check(SelfTestWait.until { scheduler.outstandingCount == 0 }, "pressure work drains")
        scheduler.setMemoryPressure(isElevated: false)
        print(
            "PASS: asynchronous capture and paste / immutable snapshots / bounded backlog retry / newer-copy protection / clear cancellation / pressure UI recovery"
        )
    }

    private static func checkRepeatedCaptureLifecycle(directory: URL, defaults: UserDefaults) throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let scheduler = ClipboardWorkScheduler(observesMemoryPressure: false)
        let poller = ManualClipboardPoller()
        let model = AppModel(
            directory: directory, pasteboard: board, defaults: defaults, poller: poller,
            processing: scheduler, frontmostApplication: { nil })
        model.startMonitoring()
        defer { model.stopMonitoring(); model.cancelPreparedCopy(); scheduler.cancelAll() }

        for round in 0..<100 {
            model.clear(keepingPinned: false)
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            _ = scheduler.submit(
                byteCount: 0,
                work: {
                    _ = gate.wait(timeout: .now() + 5)
                    return true
                }, completion: { _ in })
            let text = "stress capture \(round) 中文 👩🏽‍💻"
            board.clearContents()
            board.setString(text, forType: .string)
            for _ in 0..<50 { poller.fire() }
            try check(
                scheduler.outstandingCount == 2 && model.entries.isEmpty,
                "round \(round): burst polling retains only one immutable capture")
            switch round % 4 {
            case 0:
                // Pressure is temporary: unlike an explicit clear/pause, it must not
                // permanently consume a clipboard change that was never committed.
                scheduler.setMemoryPressure(isElevated: true)
                scheduler.setMemoryPressure(isElevated: false)
            case 1:
                // Cover both direct cancellation and a cleanup after pressure has
                // already cancelled the task and marked the clipboard for retry.
                if (round / 4).isMultiple(of: 2) { scheduler.setMemoryPressure(isElevated: true) }
                model.clear(keepingPinned: false)
                scheduler.setMemoryPressure(isElevated: false)
            case 2:
                scheduler.setMemoryPressure(isElevated: true)
                if (round / 4).isMultiple(of: 2) {
                    model.isPaused = true
                    board.clearContents()
                    board.setString("ignored while paused \(round)", forType: .string)
                    model.isPaused = false
                } else {
                    model.stopMonitoring()
                    board.clearContents()
                    board.setString("ignored while stopped \(round)", forType: .string)
                    model.startMonitoring()
                }
                scheduler.setMemoryPressure(isElevated: false)
            default:
                board.clearContents()
                board.setString("newest during saturation \(round)", forType: .string)
                for _ in 0..<50 { poller.fire() }
            }
            gate.signal()
            try check(
                SelfTestWait.until { scheduler.outstandingCount == 0 },
                "round \(round): cancelled or completed capture releases its queue slot")
            poller.fire()
            try check(
                SelfTestWait.until { scheduler.outstandingCount == 0 },
                "round \(round): recovery polling drains")
            switch round % 4 {
            case 0:
                try check(
                    model.entries.count == 1 && model.entries.first?.text == text,
                    "round \(round): pressure-cancelled capture is retried without requiring another copy")
            case 1, 2:
                try check(
                    model.entries.isEmpty,
                    "round \(round): explicit clear/pause/stop never resurrects its cancelled capture")
            default:
                try check(
                    model.entries.count == 2 && model.entries.first?.text == "newest during saturation \(round)",
                    "round \(round): full queue retries the latest content in order")
            }
            try check(
                scheduler.retainedBytes == 0 && scheduler.canSubmit && !model.isPreparingCopy,
                "round \(round): capture budgets and UI recover")
            model.setPanelVisible(false)
            model.prepareForPresentation()
            try check(
                model.selectedID == model.visibleEntries.first?.id && model.thumbnailCacheCost == 0,
                "round \(round): repeated presentation has consistent selection and no image retention")
        }
        print(
            "STRESS CASE: 100 capture lifecycle rounds / 6350 polling attempts / pressure retry / clear-pause-stop cancellation / saturation recovery / presentation"
        )
    }

    private static func checkFormatFiltering(_ model: AppModel) throws {
        let store = model.store!
        let richID = try store.add(
            .richText(text: "保留样式的文字", formats: ["public.html": Data("<b>保留样式的文字</b>".utf8)]), sourceApp: "Format Test")
        let file = store.directory.appendingPathComponent("测试文件.txt")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let fileID = try store.add(.files([file]), sourceApp: "Format Test")
        model.refresh()
        model.filter = .text
        try check(
            model.visibleEntries.contains { $0.id == richID }
                && model.visibleEntries.allSatisfy { $0.kind == .text || $0.kind == .richText },
            "text category includes rich text and excludes files/images")
        model.query = "样式"
        try check(model.visibleEntries.map(\.id) == [richID], "rich text is searchable without decoding stored formats")
        model.query = "测试文件"
        model.filter = .files
        try check(
            model.visibleEntries.map(\.id) == [fileID] && model.selectedID == fileID,
            "file category searches filenames and updates selection")
        model.query = ""
        model.filter = .all
        print("PASS: rich-text category / text search / file category / filename search / selection")
    }
}

@MainActor
private final class ManualClipboardPoller: ClipboardPolling {
    private(set) var isRunning = false
    private(set) var startCount = 0
    private var tick: (@MainActor () -> Void)?
    func start(_ tick: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        isRunning = true
        startCount += 1
        self.tick = tick
    }
    func stop() { isRunning = false; tick = nil }
    func fire() { if isRunning { tick?() } }
}
