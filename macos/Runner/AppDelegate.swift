import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  let closeCoordinator = SyncWindowCloseCoordinator()
  private var terminationPending = false

  override func applicationDidFinishLaunching(_ notification: Notification) {
    closeCoordinator.completeClose = { [weak self] in
      guard let self = self else { return }
      if self.terminationPending {
        self.terminationPending = false
        NSApp.reply(toApplicationShouldTerminate: true)
      } else {
        NSApp.terminate(nil)
      }
    }
    closeCoordinator.reportError = { [weak self] message in
      guard let self = self else { return }
      if self.terminationPending {
        self.terminationPending = false
        NSApp.reply(toApplicationShouldTerminate: false)
      }
      let alert = NSAlert()
      alert.messageText = "SyncTune could not finish quitting"
      alert.informativeText = message
      alert.addButton(withTitle: "OK")
      if let window = self.mainFlutterWindow {
        alert.beginSheetModal(for: window)
      }
    }
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if closeCoordinator.allowed { return .terminateNow }
    terminationPending = true
    // AppKit must receive terminateLater before Dart can acknowledge the request.
    DispatchQueue.main.async { self.closeCoordinator.request() }
    return .terminateLater
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
