// SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import FlutterMacOS
import Sparkle

// Sparkle owns the update lifecycle; Flutter owns its presentation and choices.
private final class UpdateUserDriver: NSObject, SPUUserDriver {
  weak var bridge: UpdateBridge?
  var foundReply: ((SPUUserUpdateChoice) -> Void)?
  var readyReply: ((SPUUserUpdateChoice) -> Void)?
  var checkCancel: (() -> Void)?
  var downloadCancel: (() -> Void)?
  var retryTermination: (() -> Void)?
  var pendingDownload = false
  private var foundStage: SPUUserUpdateStage = .notDownloaded
  private var expectedLength: UInt64 = 0
  private var receivedLength: UInt64 = 0

  var canInstall: Bool { foundReply != nil || readyReply != nil || retryTermination != nil }
  var canCancel: Bool { foundReply != nil || readyReply != nil || checkCancel != nil || downloadCancel != nil }

  func installUpdate() {
    if let reply = readyReply {
      readyReply = nil
      bridge?.installationRequested = true
      bridge?.setState("installing")
      reply(.install)
    } else if let reply = foundReply {
      foundReply = nil
      if foundStage == .installing { bridge?.installationRequested = true }
      bridge?.setState(foundStage == .installing ? "installing" : "downloading")
      reply(.install)
    } else if let retry = retryTermination {
      retryTermination = nil
      bridge?.installationRequested = true
      bridge?.setState("installing")
      retry()
      // Sparkle permits retries and does not send another installing callback.
      if bridge?.installationRequested == true {
        retryTermination = retry
        bridge?.setState("ready")
      }
    }
  }

  func cancelUpdate() {
    let check = checkCancel, download = downloadCancel
    let found = foundReply, ready = readyReply
    let choice: SPUUserUpdateChoice = foundStage == .installing ? .skip : .dismiss
    clearCallbacks()
    bridge?.installationRequested = false
    bridge?.restoreAvailability()
    if let download = download { download() }
    else if let check = check { check() }
    else if let ready = ready { ready(.skip) }
    else { found?(choice) }
  }

  func clearCallbacks() {
    foundReply = nil; readyReply = nil; checkCancel = nil
    downloadCancel = nil; retryTermination = nil; pendingDownload = false
  }

  func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
    reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    checkCancel = cancellation
    bridge?.beginChecking(preservingAvailable: true)
  }

  func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
    checkCancel = nil
    foundStage = state.stage
    foundReply = reply
    bridge?.foundUpdate(item)
    if item.isInformationOnlyUpdate {
      foundReply = nil; pendingDownload = false
      reply(.dismiss)
    } else if pendingDownload {
      pendingDownload = false
      // A resumed installation still needs the user's explicit restart choice.
      if state.stage == .installing { bridge?.setState("ready") }
      else { installUpdate() }
    } else if state.stage == .installing {
      bridge?.setState("ready")
    }
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
    // External release-note pages are deliberately not requested by the delegate.
  }

  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
    bridge?.recordFailure(error)
  }

  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    bridge?.handleNoUpdate(error)
    acknowledgement()
  }

  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    bridge?.recordFailure(error)
    acknowledgement()
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    checkCancel = nil; foundReply = nil
    downloadCancel = cancellation
    expectedLength = 0; receivedLength = 0
    bridge?.setState("downloading")
  }

  func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) {
    expectedLength = length
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    receivedLength += length
    if expectedLength > 0 {
      bridge?.setState("downloading", progress: min(1, Double(receivedLength) / Double(expectedLength)))
    }
  }

  func showDownloadDidStartExtractingUpdate() {
    downloadCancel = nil
    bridge?.setState("extracting")
  }

  func showExtractionReceivedProgress(_ progress: Double) {
    bridge?.setState("extracting", progress: max(0, min(1, progress)))
  }

  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    downloadCancel = nil; foundReply = nil
    readyReply = reply
    bridge?.setState("ready")
  }

  func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
    readyReply = nil
    retryTermination = applicationTerminated ? nil : retryTerminatingApplication
    bridge?.installationRequested = true
    // The installer may report this after the application rejected its quit event.
    bridge?.setState(retryTermination == nil ? "installing" : "ready")
  }

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    clearCallbacks()
    bridge?.updateInstalled()
    acknowledgement()
  }

  func dismissUpdateInstallation() {
    clearCallbacks()
    bridge?.finishPresentation()
  }

  func showUpdateInFocus() { bridge?.publish() }
}

final class UpdateBridge: NSObject, SPUUpdaterDelegate {
  private var channel: FlutterMethodChannel?
  private var updater: SPUUpdater?
  private var userDriver: UpdateUserDriver?
  private var observations: [NSKeyValueObservation] = []
  private var enabled = false
  private var reason: String?
  private var status = "idle"
  private var version: String?
  private var releaseNotes: String?
  private var informationOnly = false
  private var errorMessage: String?
  private var progress: Double?
  private var revision: Int64 = 0
  private var disposed = false
  fileprivate(set) var installationRequested = false

  private var canCheck: Bool {
    enabled && updater?.sessionInProgress == false && updater?.canCheckForUpdates == true
  }

  private var snapshot: [String: Any] {
    var value: [String: Any] = [
      "revision": revision, "enabled": enabled, "status": status,
      "capabilities": [
        "checkForUpdates": canCheck,
        "showUpdate": enabled && (updater?.sessionInProgress == true || canCheck),
        "installUpdate": enabled && !informationOnly && (userDriver?.canInstall == true || (version != nil && canCheck)),
        "cancelUpdate": enabled && status != "extracting" && userDriver?.canCancel == true
      ]
    ]
    if let reason = reason { value["reason"] = reason }
    if let version = version { value["version"] = version }
    if let releaseNotes = releaseNotes { value["releaseNotes"] = releaseNotes }
    if let errorMessage = errorMessage { value["error"] = errorMessage }
    if let progress = progress { value["progress"] = progress }
    return value
  }

  func install(on messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "tech.soit.flutterairplay/updates", binaryMessenger: messenger)
    channel?.setMethodCallHandler { [weak self] call, result in
      guard let self = self, !self.disposed else {
        result(FlutterError(code: "disposed", message: "Updater has been disposed", details: nil)); return
      }
      switch call.method {
      case "initialize": self.initialize(); result(self.snapshot)
      case "checkForUpdates":
        self.initialize()
        if self.canCheck {
          self.beginChecking()
          self.updater?.checkForUpdateInformation()
        }
        result(self.snapshot)
      case "showUpdate":
        self.initialize()
        if self.canCheck { self.updater?.checkForUpdates() }
        result(self.snapshot)
      case "installUpdate":
        self.initialize()
        if self.enabled && !self.informationOnly {
          if self.userDriver?.canInstall == true { self.userDriver?.installUpdate() }
          else if self.version != nil && self.canCheck {
            self.userDriver?.pendingDownload = true
            self.updater?.checkForUpdates()
          }
        }
        result(self.snapshot)
      case "cancelUpdate":
        if self.status != "extracting" && self.userDriver?.canCancel == true { self.userDriver?.cancelUpdate() }
        result(self.snapshot)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func initialize() {
    guard updater == nil, !disposed else { return }
    let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let decoded = Data(base64Encoded: key), decoded.count == 32,
          decoded.base64EncodedString() == key else {
      reason = "This application was built without a valid Ed25519 update public key."
      publish()
      return
    }
    let driver = UpdateUserDriver()
    driver.bridge = self
    let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
    // Dart owns scheduling; persisted Sparkle preferences must never create UI.
    updater.automaticallyChecksForUpdates = false
    updater.automaticallyDownloadsUpdates = false
    do {
      try updater.start()
      self.userDriver = driver
      self.updater = updater
      enabled = true
      reason = nil
      observations = [
        updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in self?.publish() },
        updater.observe(\.sessionInProgress, options: [.new]) { [weak self] _, _ in self?.publish() }
      ]
      publish()
    } catch {
      reason = error.localizedDescription
      recordFailure(error)
    }
  }

  fileprivate func beginChecking(preservingAvailable: Bool = false) {
    // Preserve the probe's available version while preparing a user session.
    setState(preservingAvailable && version != nil ? "available" : "checking")
  }

  fileprivate func setState(_ value: String, error: String? = nil, progress: Double? = nil) {
    status = value
    errorMessage = error
    self.progress = progress
    publish()
  }

  fileprivate func publish() {
    guard !disposed else { return }
    revision += 1
    channel?.invokeMethod("updateState", arguments: snapshot)
  }

  fileprivate func foundUpdate(_ item: SUAppcastItem) {
    version = item.displayVersionString
    informationOnly = item.isInformationOnlyUpdate
    releaseNotes = item.itemDescription.map { description in
      description
        .replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "(?i)<br\\s*/?>|</(?:p|div|li|h[1-6])>", with: "\n", options: .regularExpression)
        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "&nbsp;", with: " ")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&amp;", with: "&")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    reason = informationOnly ? "This update is informational and cannot be installed in the application." : nil
    setState("available")
  }

  fileprivate func restoreAvailability() {
    setState(version == nil ? "idle" : "available")
  }

  fileprivate func finishPresentation() {
    // Dismissal also follows failures; keep their diagnostics and discovered version.
    if ["checking", "downloading", "extracting"].contains(status) { restoreAvailability() }
    else { publish() }
  }

  fileprivate func recordFailure(_ error: Error) {
    installationRequested = false
    userDriver?.clearCallbacks()
    setState("error", error: error.localizedDescription)
  }

  fileprivate func handleNoUpdate(_ error: Error) {
    let native = error as NSError
    if native.domain == SUSparkleErrorDomain && native.code == SUError.noUpdateError.rawValue {
      userDriver?.clearCallbacks()
      version = nil; releaseNotes = nil; informationOnly = false; reason = nil
      installationRequested = false
      setState("idle")
    } else { recordFailure(error) }
  }

  fileprivate func updateInstalled() {
    installationRequested = false
    version = nil; releaseNotes = nil; informationOnly = false; reason = nil
    setState("idle")
  }

  func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

  func feedURLString(for updater: SPUUpdater) -> String? {
    // Ignore old preferences that may point to a different distribution feed.
    Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
  }

  func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool { false }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { foundUpdate(item) }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { handleNoUpdate(error) }

  func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
    version = item.displayVersionString
    setState("downloading")
  }

  func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    installationRequested = true
    setState("installing")
  }

  func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) { recordFailure(error) }

  func userDidCancelDownload(_ updater: SPUUpdater) { restoreAvailability() }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { handleNoUpdate(error) }

  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
    if let error = error { handleNoUpdate(error) }
    else if status == "checking" { restoreAvailability() }
  }

  func shouldTerminate(receiver: ReceiverBridge, text: (String) -> String) -> NSApplication.TerminateReply {
    guard installationRequested else { return .terminateNow }
    let state = receiver.host.queue.sync { receiver.host.snapshot() }
    guard state["status"] as? String == "streaming" else { return .terminateNow }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = text("updateInterruptTitle")
    alert.informativeText = text("updateInterruptMessage")
    alert.addButton(withTitle: text("updateInstallAndDisconnect"))
    alert.addButton(withTitle: text("cancel"))
    if alert.runModal() == .alertFirstButtonReturn { return .terminateNow }
    setState("ready")
    return .terminateCancel
  }

  func dispose() {
    disposed = true
    observations.removeAll()
    channel?.setMethodCallHandler(nil)
    channel = nil
    // Do not cancel Sparkle's installer while application termination is in progress.
    userDriver?.clearCallbacks()
    userDriver?.bridge = nil
  }
}
