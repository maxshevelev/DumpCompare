import Foundation

/// Tells the system that this app is interested in the shared library file
/// (`Design/FAVORITES_SYNC_PLAN.md`).
///
/// A file watcher hears about writes to the disk. A file in iCloud Drive — or
/// Google Drive, or Dropbox — is not written to the disk when the other machine
/// changes it: the provider fetches the new version **when something asks for
/// it**, which is why the change appeared only after the file was opened in the
/// Finder. Opening it in the Finder is the Finder saying it is interested.
///
/// A presenter is how an app says the same thing. Registered with
/// `NSFileCoordinator`, it puts this app into the coordination the provider
/// already takes part in: the provider keeps the file current for a presenter
/// that exists, and `presentedItemDidChange` arrives when it does.
final class LibraryFilePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: () -> Void

    init(url: URL, onChange: @escaping () -> Void) {
        presentedItemURL = url
        // **Not** the main queue. The library's own writes are coordinated
        // synchronously from the main thread, and a presenter whose queue is
        // that same thread is a deadlock waiting for the first write: the
        // coordinator asks the presenter to stand aside, on a queue that is
        // busy waiting for the coordinator. The write never happens, the error
        // lands in `publishError`, and the file simply stops changing.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "dev.maxik.DumpCompare.libraryPresenter"
        presentedItemOperationQueue = queue
        self.onChange = onChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
        // Ask for the newest version now: registering says this app is
        // interested from here on, and this is the one time it has to ask about
        // what happened before that. Once only — a repeated ask is a cloud
        // client kept busy for nothing.
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        if status != nil, status != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    func stop() {
        NSFileCoordinator.removeFilePresenter(self)
    }

    func presentedItemDidChange() {
        announce()
    }

    /// The provider replaced the file rather than editing it — an atomic write
    /// from another machine's app, or the download of a new version.
    func presentedItemDidGain(_ version: NSFileVersion) {
        announce()
    }

    func presentedItemDidResolveConflict(_ version: NSFileVersion) {
        announce()
    }

    /// The callbacks arrive on the presenter's own queue; the library is the
    /// main actor's.
    private func announce() {
        DispatchQueue.main.async { [onChange] in onChange() }
    }
}
