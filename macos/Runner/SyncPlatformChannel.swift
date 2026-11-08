import Cocoa
import FlutterMacOS
import Security

protocol SyncCredentialStorage {
  func read(_ identity: String) throws -> String?
  func exists(_ identity: String) throws -> Bool
  func write(_ identity: String, secret: String) throws
  func delete(_ identity: String) throws
}

struct SyncPlatformError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

final class WebDAVKeychain: SyncCredentialStorage {
  private func query(_ identity: String) throws -> [String: Any] {
    guard identity.count == 64,
      identity.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw SyncPlatformError(message: "The WebDAV credential key is invalid.") }
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "SyncTune.WebDAV.v2",
      kSecAttrAccount as String: identity,
      kSecAttrSynchronizable as String: false,
    ]
  }

  private func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else {
      let reason = SecCopyErrorMessageString(status, nil) as String? ?? "Status \(status)"
      throw SyncPlatformError(message: "Keychain could not complete the request: \(reason)")
    }
  }

  func read(_ identity: String) throws -> String? {
    var request = try query(identity)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    try check(status)
    guard let data = value as? Data, let secret = String(data: data, encoding: .utf8) else {
      throw SyncPlatformError(message: "Keychain returned an invalid WebDAV password.")
    }
    return secret
  }

  func exists(_ identity: String) throws -> Bool {
    var request = try query(identity)
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    let status = SecItemCopyMatching(request as CFDictionary, nil)
    if status == errSecItemNotFound { return false }
    try check(status)
    return true
  }

  func write(_ identity: String, secret: String) throws {
    guard !secret.isEmpty else { throw SyncPlatformError(message: "Enter the WebDAV password.") }
    let request = try query(identity)
    let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8)]
    let status = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = request.merging(attributes) { _, new in new }
      item[kSecAttrLabel as String] = "SyncTune WebDAV"
      let added = SecItemAdd(item as CFDictionary, nil)
      if added == errSecDuplicateItem {
        try check(SecItemUpdate(request as CFDictionary, attributes as CFDictionary))
      } else {
        try check(added)
      }
    } else {
      try check(status)
    }
  }

  func delete(_ identity: String) throws {
    let status = SecItemDelete(try query(identity) as CFDictionary)
    if status != errSecItemNotFound { try check(status) }
  }
}

/// Kept separate from the messenger so system failures and wire results can be tested.
final class SyncPlatformMethods {
  private let credentials: SyncCredentialStorage
  private let picker: (@escaping FlutterResult) -> Void
  private let databasePath: () throws -> String
  private let allowWindowClose: () -> Void

  init(
    credentials: SyncCredentialStorage = WebDAVKeychain(),
    picker: @escaping (@escaping FlutterResult) -> Void = SyncPlatformMethods.pickFolder,
    databasePath: @escaping () throws -> String = SyncPlatformMethods.stateDatabasePath,
    allowWindowClose: @escaping () -> Void
  ) {
    self.credentials = credentials
    self.picker = picker
    self.databasePath = databasePath
    self.allowWindowClose = allowWindowClose
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      switch call.method {
      case "stateDatabasePath": result(try databasePath())
      case "pickFolder": picker(result)
      case "credentialRead": result(try credentials.read(argument(call, "identity")))
      case "credentialExists": result(try credentials.exists(argument(call, "identity")))
      case "credentialWrite":
        try credentials.write(argument(call, "identity"), secret: argument(call, "secret"))
        result(nil)
      case "credentialDelete":
        try credentials.delete(argument(call, "identity"))
        result(nil)
      case "allowWindowClose":
        result(nil)
        // Deliver the method reply before tearing down the Flutter engine.
        DispatchQueue.main.async { self.allowWindowClose() }
      default: result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(code: "platform_error", message: error.localizedDescription, details: nil))
    }
  }

  private func argument(_ call: FlutterMethodCall, _ key: String) throws -> String {
    guard let arguments = call.arguments as? [String: Any], let value = arguments[key] as? String else {
      throw SyncPlatformError(message: "Missing \(key).")
    }
    return value
  }

  static func stateDatabasePath() throws -> String {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return try stateDatabasePath(in: support)
  }

  static func stateDatabasePath(in support: URL) throws -> String {
    let directory = support.appendingPathComponent("SyncTune", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("synctune-state-v2.sqlite").path
  }

  static func folderSelection(_ url: URL) throws -> [String: String] {
    guard url.isFileURL else {
      throw SyncPlatformError(message: "The selected folder has no filesystem path.")
    }
    // Resolve a picked alias or symlink once; FileLocalStore checks links beneath this root.
    let folder = url.resolvingSymlinksInPath().standardizedFileURL
    guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw SyncPlatformError(message: "The selected music folder is unavailable.")
    }
    return ["locator": folder.path, "stableId": folder.path, "generation": "macos-folder-v2"]
  }

  static func pickFolder(result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.resolvesAliases = true
    let complete: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK else { result(nil); return }
      do {
        guard let url = panel.url else {
          throw SyncPlatformError(message: "No folder was selected.")
        }
        result(try folderSelection(url))
      } catch {
        result(FlutterError(code: "platform_error", message: error.localizedDescription, details: nil))
      }
    }
    if let window = NSApp.mainWindow {
      panel.beginSheetModal(for: window, completionHandler: complete)
    } else {
      panel.begin(completionHandler: complete)
    }
  }
}

/// Both the close button and Cmd+Q enter this single, retryable handshake.
final class SyncWindowCloseCoordinator {
  private(set) var pending = false
  private(set) var allowed = false
  var requestCancellation: (@escaping FlutterResult) -> Void = { _ in }
  var completeClose: () -> Void = {}
  var reportError: (String) -> Void = { _ in }

  func request() {
    guard !pending && !allowed else { return }
    pending = true
    requestCancellation { [weak self] response in
      guard let self = self, self.pending else { return }
      if let error = response as? FlutterError {
        self.pending = false
        self.reportError(error.message ?? "SyncTune could not stop synchronization. Try quitting again.")
      } else if let response = response as? NSObject, response === FlutterMethodNotImplemented {
        // Dart has not bound a controller yet (startup or the startup-error screen).
        self.allow()
      }
    }
  }

  func allow() {
    guard pending && !allowed else { return }
    pending = false
    allowed = true
    completeClose()
  }
}
