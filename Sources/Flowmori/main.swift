import AppKit
import Foundation
import FlowmoriCore

umask(0o077)
if CommandLine.arguments.contains("--diagnose") {
    let system = MenuBarSystem()
    let report: [String:Any] = ["os":ProcessInfo.processInfo.operatingSystemVersionString,
                              "menuBridgeAvailable":system.available,"accessibility":AXIsProcessTrusted(),
                              "screenCapture":CGPreflightScreenCaptureAccess()]
    if let json = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { print(String(decoding:json,as:UTF8.self)) }
    exit(0)
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: AppController?
    func applicationDidFinishLaunching(_ notification:Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier:bundleID).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("app.flowmori.showSettings"),object:nil,userInfo:nil,deliverImmediately:true)
            NSApp.terminate(nil); return
        }
        var diagnostics: URL?
        if let index = CommandLine.arguments.firstIndex(of:"--diagnostics"), CommandLine.arguments.indices.contains(index+1) { diagnostics = URL(fileURLWithPath:CommandLine.arguments[index+1]) }
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        var migrationError: Error?
        do {
            let legacyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier:ProductMigration.legacyBundleID).isEmpty
            let hadLegacyData = FileManager.default.fileExists(atPath:support.appendingPathComponent(ProductMigration.legacyDirectoryName).path)
            let directory = try ProductMigration.dataDirectory(in:support,legacyRunning:legacyRunning)
            ProductMigration.preferences(legacy:UserDefaults.standard.persistentDomain(forName:ProductMigration.legacyBundleID) ?? [:],
                                         into:.standard,dataDirectory:directory,hadLegacyData:hadLegacyData)
        } catch { migrationError = error }
        controller = AppController(diagnosticsURL:diagnostics,migrationError:migrationError)
    }
    func applicationWillTerminate(_ notification:Notification) { controller?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool { controller?.showSettings(); return true }
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.run()
