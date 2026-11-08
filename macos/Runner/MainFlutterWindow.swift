import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var syncChannel: FlutterMethodChannel?
  private var syncMethods: SyncPlatformMethods?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    self.setContentSize(NSSize(width: 1280, height: 720))
    self.minSize = NSSize(width: 800, height: 600)
    self.title = "SyncTune"
    self.center()
    self.delegate = self

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "synctune/sync_platform", binaryMessenger: flutterViewController.engine.binaryMessenger)
    let appDelegate = NSApp.delegate as! AppDelegate
    appDelegate.closeCoordinator.requestCancellation = { reply in
      channel.invokeMethod("windowCloseRequested", arguments: nil, result: reply)
    }
    let methods = SyncPlatformMethods(allowWindowClose: { [weak appDelegate] in
      appDelegate?.closeCoordinator.allow()
    })
    channel.setMethodCallHandler(methods.handle)
    syncChannel = channel
    syncMethods = methods

    super.awakeFromNib()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    NSApp.terminate(sender)
    return false
  }
}
