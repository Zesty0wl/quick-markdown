import Foundation
import CoreServices  // FSEvents

/// Watches a single directory on disk (and, implicitly, its subtree) and
/// fires `onChange` on the main queue whenever any file inside is modified,
/// added, renamed, or removed.
///
/// Used by `DocumentWindowController` to refresh the preview when images
/// or other linked assets that live next to the Markdown file are edited
/// externally (e.g. saving a tweaked SVG, regenerating a PNG). The
/// document's own `.md` file is handled separately by `MarkdownDocument`'s
/// `NSFilePresenter` — this watcher exists for the *siblings*.
///
/// We use FSEvents rather than `DispatchSource.makeFileSystemObjectSource`
/// because the latter, when pointed at a directory file descriptor, only
/// fires on inode-level changes to the directory itself (file add / remove
/// / rename). It does **not** fire when an existing file inside the
/// directory is modified in place, which is what most editors do when
/// saving. FSEvents streams the full subtree and catches content writes.
///
/// `kFSEventStreamCreateFlagIgnoreSelf` keeps the watcher from firing on
/// writes from the QuickMarkdown process itself (e.g. the document
/// auto-saving its own `.md`). Writes to the document from *other*
/// processes (an agent or another editor) are ignored by name, along with
/// the temporary files an atomic save creates beside it, because
/// `MarkdownDocument` already handles those; reacting here too caused a
/// second, full preview reload on every outside save.
///
/// `onChange` is captured at construction time so it can be read off the
/// internal serial queue without further synchronisation, which keeps the
/// type compatible with Swift 6 strict concurrency.
final class MediaWatcher: @unchecked Sendable {

    private let onChange: @MainActor () -> Void

    /// File name of the watched document, whose own changes are skipped.
    private let ignoredFileName: String?

    private let queue = DispatchQueue(
        label: "QuickMarkdown.MediaWatcher",
        qos: .userInitiated
    )
    /// FSEvents coalesces bursts of writes within this window before
    /// firing the callback — saves us implementing our own debounce.
    private let latency: CFTimeInterval = 0.2

    private var stream: FSEventStreamRef?

    init(ignoredFileName: String? = nil, onChange: @escaping @MainActor () -> Void) {
        self.ignoredFileName = ignoredFileName
        self.onChange = onChange
    }

    /// Begin watching `folderURL`. Safe to call multiple times — any prior
    /// stream is torn down first. No-op if FSEvents refuses the path
    /// (sandbox denial on an unmounted volume, etc.).
    func start(watching folderURL: URL) {
        queue.async { [weak self] in
            self?._start(watching: folderURL)
        }
    }

    /// Stop watching. Safe to call when not started.
    func stop() {
        queue.async { [weak self] in
            self?._stop()
        }
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }

    // MARK: - Private (executed on `queue`)

    private func _start(watching folderURL: URL) {
        _stop()

        // FSEvents callbacks are C function pointers and can't capture
        // Swift context, so we pass `self` as an opaque pointer via the
        // context's `info` slot. We use `passUnretained` and rely on the
        // strict ordering of `_stop()` (which synchronously stops and
        // invalidates the stream) to guarantee no callback can fire after
        // the watcher is torn down.
        let unmanaged = Unmanaged.passUnretained(self)
        var context = FSEventStreamContext(
            version: 0,
            info: unmanaged.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [folderURL.path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagIgnoreSelf
        )

        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let me = Unmanaged<MediaWatcher>.fromOpaque(info).takeUnretainedValue()
            // With `UseCFTypes`, the paths arrive as a CFArray of CFStrings.
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths)
                .takeUnretainedValue() as? [String] ?? []
            if !paths.isEmpty, paths.allSatisfy(me.isIgnored) { return }
            me.fire()
        }

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    private func _stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
        stream = nil
    }

    /// True for the document itself and for atomic-save temporaries named
    /// after it (`notes.md.tmp.123`, `.notes.md.swp`, ...).
    private func isIgnored(_ path: String) -> Bool {
        guard let ignoredFileName else { return false }
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix(ignoredFileName) || name.hasPrefix("." + ignoredFileName)
    }

    private func fire() {
        let cb = onChange
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                cb()
            }
        }
    }
}
