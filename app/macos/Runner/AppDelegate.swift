import Cocoa
import FlutterMacOS
import Network

@main
class AppDelegate: FlutterAppDelegate {
  /// Dart UDP never prompts macOS Local Network. Bonjour browse does.
  private var lanPrompt: NWBrowser?

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    promptLocalNetworkAccess()
    super.applicationDidFinishLaunching(notification)
  }

  private func promptLocalNetworkAccess() {
    let params = NWParameters.udp
    params.includePeerToPeer = true
    let browser = NWBrowser(for: .bonjour(type: "_aml-onedrop._udp", domain: nil), using: params)
    browser.stateUpdateHandler = { _ in }
    browser.browseResultsChangedHandler = { _, _ in }
    browser.start(queue: .main)
    lanPrompt = browser
  }
}
