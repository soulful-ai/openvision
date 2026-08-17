// OpenVision - OVLog.swift
// One-line bridge from the app's diagnostic prints to the unified log (AUR-723d).
//
// `print()` writes to stdout, which does NOT reach the iOS unified log unless the app is running
// under a debugger — so on a sideloaded build every "[AudioCapture] …" / "[OpenAIRealtime] …"
// line was invisible to `pymobiledevice3 syslog live`, and a field bug could only be diagnosed
// from the server side. `ovLog` writes to both.

import Foundation
import os

private let ovLogger = Logger(subsystem: "app.soulless.openvision", category: "openvision")

/// Diagnostic line: unified log (visible in the device console) + stdout (visible in Xcode).
func ovLog(_ message: String) {
    ovLogger.notice("\(message, privacy: .public)")
    print(message)
}
