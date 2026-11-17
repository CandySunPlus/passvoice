import Darwin
import Foundation

if Bundle.main.bundleURL.pathExtension == "app" {
    if #available(macOS 13, *) {
        runMenuBarApp()
    } else {
        logBridgeMessage("The PassVoice menu bar app requires macOS 13 or later.")
        exit(EXIT_FAILURE)
    }
} else {
    runCommandLine()
}
