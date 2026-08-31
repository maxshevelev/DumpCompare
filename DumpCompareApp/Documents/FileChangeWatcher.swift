import Foundation

/// Watches a file on disk for external modifications (§5.5).
///
/// Opens the file read-only (`O_EVTONLY`) and listens for write/rename/delete
/// events on a background queue. Events are debounced and delivered once on the
/// main actor via `onChange`. The watcher holds no document state — the caller
/// (the pane) decides what the event means and whether to prompt.
final class FileChangeWatcher {
    /// How long events are coalesced before one is delivered. A `var` so tests
    /// can shorten it: three tests were spending a second each waiting out a
    /// literal, and an inverted expectation ("nothing fires after stop") has to
    /// outlast whatever this is.
    static var debounceInterval: TimeInterval = 0.4

    /// Fired on the main actor after an external change, debounced.
    var onChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var debounceWorkItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "dev.maxik.DumpCompare.fileWatcher")

    init(url: URL) {
        start(url: url)
    }

    deinit {
        stop()
    }

    /// Restarts the watcher for `url`, dropping any pending debounce. Called
    /// after a save/revert when the file's inode may have been replaced by an
    /// atomic write — the old descriptor would otherwise keep watching an
    /// unlinked file forever.
    func rebind(to url: URL?) {
        stop()
        if let url {
            start(url: url)
        }
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        source?.cancel()
        source = nil
    }

    // MARK: - Internals

    private func start(url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: queue
        )
        source = src
        src.setEventHandler { [weak self] in
            self?.scheduleNotify()
        }
        src.setCancelHandler { [weak self] in
            self?.closeDescriptor()
        }
        src.resume()
    }

    private func closeDescriptor() {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    /// Coalesces bursts of events (a save can produce several writes) into one
    /// `onChange` delivery a short while after the last one.
    private func scheduleNotify() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.onChange?()
            }
        }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: item)
    }
}
