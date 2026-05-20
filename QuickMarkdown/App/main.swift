import AppKit

// Explicit entry point. We deliberately do not use `@main` on AppDelegate
// because the Swift Foundation overlay's default `main()` implementation
// in some SDK builds does not register the delegate with NSApplication
// before the runloop starts, leaving the app stuck with no delegate and
// auto-creating an untitled document we can't intercept.

// Install our custom NSDocumentController FIRST so AppKit's document
// restoration machinery uses it from the moment NSApplication starts.
_ = QuickMarkdownDocumentController.shared

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
