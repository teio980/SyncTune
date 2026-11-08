import Cocoa
import FlutterMacOS
import XCTest
@testable import synctune

final class RunnerTests: XCTestCase {
  func testFolderSelectionAndDatabaseUseUnicodePaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let music = root.appendingPathComponent("中文 音乐", isDirectory: true)
    try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
    let selection = try SyncPlatformMethods.folderSelection(music)
    XCTAssertEqual(selection["locator"], music.resolvingSymlinksInPath().path)
    XCTAssertEqual(selection["stableId"], selection["locator"])
    XCTAssertEqual(selection["generation"], "macos-folder-v2")
    let path = try SyncPlatformMethods.stateDatabasePath(in: root)
    XCTAssertEqual(path, root.appendingPathComponent("SyncTune/synctune-state-v2.sqlite").path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("SyncTune").path))
    XCTAssertEqual(try SyncPlatformMethods.stateDatabasePath(in: root), path)
    XCTAssertThrowsError(try SyncPlatformMethods.folderSelection(URL(string: "https://example.test")!))
    let file = root.appendingPathComponent("file.mp3")
    try Data([1]).write(to: file)
    XCTAssertThrowsError(try SyncPlatformMethods.folderSelection(file))
    XCTAssertThrowsError(try SyncPlatformMethods.stateDatabasePath(in: file))
  }

  func testCancelledPickerAndMissingCredentialReturnEmptyResults() {
    let methods = SyncPlatformMethods(
      credentials: FakeCredentials(), picker: { $0(nil) }, allowWindowClose: {})
    methods.handle(FlutterMethodCall(methodName: "pickFolder", arguments: nil)) { XCTAssertNil($0) }
    methods.handle(call("credentialRead")) { XCTAssertNil($0) }
    methods.handle(call("credentialExists")) { XCTAssertEqual($0 as? Bool, false) }
  }

  func testSystemFailuresAndInvalidArgumentsReturnPlatformErrors() {
    let credentials = FakeCredentials()
    credentials.fail = true
    let methods = SyncPlatformMethods(
      credentials: credentials,
      picker: { $0(FlutterError(code: "platform_error", message: "picker failed", details: nil)) },
      databasePath: { throw SyncPlatformError(message: "directory failed") },
      allowWindowClose: {})
    for method in ["pickFolder", "stateDatabasePath", "credentialRead", "credentialExists", "credentialWrite", "credentialDelete"] {
      methods.handle(call(method)) { XCTAssertEqual(($0 as? FlutterError)?.code, "platform_error", method) }
    }
    methods.handle(FlutterMethodCall(methodName: "credentialWrite", arguments: nil)) {
      XCTAssertEqual(($0 as? FlutterError)?.code, "platform_error")
    }
    methods.handle(call("isReparsePoint")) {
      XCTAssertTrue(($0 as? NSObject) === FlutterMethodNotImplemented)
    }
  }

  func testKeychainRoundTripUpdatesAndDeletesOnlyItsOwnIdentity() throws {
    // A disposable 64-character account avoids touching any saved application credential.
    let identity = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let keychain = WebDAVKeychain()
    defer { try? keychain.delete(identity) }
    XCTAssertNil(try keychain.read(identity))
    XCTAssertFalse(try keychain.exists(identity))
    try keychain.write(identity, secret: "中文 password 🔑")
    XCTAssertTrue(try keychain.exists(identity))
    XCTAssertEqual(try keychain.read(identity), "中文 password 🔑")
    try keychain.write(identity, secret: "updated secret")
    XCTAssertEqual(try keychain.read(identity), "updated secret")
    try keychain.delete(identity)
    try keychain.delete(identity)
    XCTAssertNil(try keychain.read(identity))
    XCTAssertThrowsError(try keychain.read("invalid"))
    XCTAssertThrowsError(try keychain.write(identity, secret: ""))
  }

  func testDuplicateQuitRequestsWaitForExplicitDartAcknowledgement() {
    let close = SyncWindowCloseCoordinator()
    var requests = 0
    var exits = 0
    var reply: FlutterResult?
    close.requestCancellation = { requests += 1; reply = $0 }
    close.completeClose = { exits += 1 }
    close.allow() // An unsolicited acknowledgement must not terminate the app.
    XCTAssertEqual(exits, 0)
    close.request()
    close.request()
    XCTAssertEqual(requests, 1)
    XCTAssertTrue(close.pending)
    reply?(nil)
    XCTAssertEqual(exits, 0)
    close.allow()
    close.allow()
    close.request()
    XCTAssertTrue(close.allowed)
    XCTAssertEqual(exits, 1)
    XCTAssertEqual(requests, 1)
  }

  func testQuitFailureKeepsAppOpenAndAllowsRetry() {
    let close = SyncWindowCloseCoordinator()
    var requests = 0
    var failures = 0
    close.requestCancellation = { reply in
      requests += 1
      reply(FlutterError(code: "platform_error", message: "stop failed", details: nil))
    }
    close.reportError = { _ in failures += 1 }
    close.request()
    close.request()
    XCTAssertFalse(close.pending)
    XCTAssertFalse(close.allowed)
    XCTAssertEqual(requests, 2)
    XCTAssertEqual(failures, 2)
  }

  func testQuitBeforeDartControllerIsBoundStillCloses() {
    let close = SyncWindowCloseCoordinator()
    var exits = 0
    close.requestCancellation = { $0(FlutterMethodNotImplemented) }
    close.completeClose = { exits += 1 }
    close.request()
    XCTAssertEqual(exits, 1)
  }

  func testCloseMethodRepliesBeforeCompletingQuit() {
    let close = expectation(description: "quit allowed")
    var replied = false
    let methods = SyncPlatformMethods(allowWindowClose: {
      XCTAssertTrue(replied)
      close.fulfill()
    })
    methods.handle(call("allowWindowClose")) { result in
      XCTAssertNil(result)
      replied = true
    }
    wait(for: [close], timeout: 2)
  }

  private func call(_ method: String) -> FlutterMethodCall {
    FlutterMethodCall(methodName: method, arguments: ["identity": String(repeating: "a", count: 64), "secret": "test"])
  }
}

private final class FakeCredentials: SyncCredentialStorage {
  var fail = false
  private func check() throws {
    if fail { throw SyncPlatformError(message: "Keychain unavailable") }
  }
  func read(_ identity: String) throws -> String? { try check(); return nil }
  func exists(_ identity: String) throws -> Bool { try check(); return false }
  func write(_ identity: String, secret: String) throws { try check() }
  func delete(_ identity: String) throws { try check() }
}
