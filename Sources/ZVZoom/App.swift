import SwiftUI
import AppKit

struct ZVZoomApp: App {
    @StateObject private var controller = ZoomController()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory) // menubar only, no Dock icon
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(systemName: "camera.aperture")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var controller: ZoomController

    var body: some View {
        Text(controller.status.text)
        Text(controller.zoomText)
        Text(controller.presetText)
        Divider()
        Button("Save Current Zoom") { controller.savePreset() }
            .disabled(controller.status == .noCamera)
        Button("Restore Saved Zoom") { controller.restoreNow() }
            .disabled(controller.status == .noCamera || controller.presetScale == nil)
        Toggle("Restore Automatically on Connect", isOn: $controller.restoreOnConnect)
        Divider()
        Button("Zoom In (nudge)") { controller.nudge(.tele) }
            .disabled(controller.status == .noCamera)
        Button("Zoom Out (nudge)") { controller.nudge(.wide) }
            .disabled(controller.status == .noCamera)
        Button("Refresh") { controller.refresh() }
            .disabled(controller.status == .noCamera)
        Divider()
        Button("Reconnect") { controller.reconnect() }
            .disabled(controller.status == .noCamera)
        Button("Clear Saved Zoom") { controller.clearPreset() }
            .disabled(controller.presetScale == nil)
        Button("Open Log") {
            NSWorkspace.shared.open(Log.url)
        }
        Divider()
        Button("Quit ZVZoom") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
