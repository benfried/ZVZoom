import Foundation
import Combine

/// Persisted settings.
enum Settings {
    private static let d = UserDefaults.standard

    /// Saved zoom bar position (ZoomBarInformation low byte). nil = nothing saved yet.
    static var presetBar: Int? {
        get { d.object(forKey: "presetBar") == nil ? nil : d.integer(forKey: "presetBar") }
        set { if let v = newValue { d.set(v, forKey: "presetBar") } else { d.removeObject(forKey: "presetBar") } }
    }

    /// Saved ZoomScale (magnification * 1000), kept for display and as a fallback metric.
    static var presetScale: Int64? {
        get { d.object(forKey: "presetScale") == nil ? nil : Int64(d.integer(forKey: "presetScale")) }
        set { if let v = newValue { d.set(Int(v), forKey: "presetScale") } else { d.removeObject(forKey: "presetScale") } }
    }

    static var restoreOnConnect: Bool {
        get { d.object(forKey: "restoreOnConnect") == nil ? true : d.bool(forKey: "restoreOnConnect") }
        set { d.set(newValue, forKey: "restoreOnConnect") }
    }

    /// Length of a manual nudge pulse (ms).
    static var nudgeMs: Int {
        get { d.object(forKey: "nudgeMs") == nil ? 80 : d.integer(forKey: "nudgeMs") }
        set { d.set(newValue, forKey: "nudgeMs") }
    }

    /// Accepted error in bar positions when restoring.
    static var tolerance: Int {
        get { d.object(forKey: "tolerance") == nil ? 3 : d.integer(forKey: "tolerance") }
        set { d.set(newValue, forKey: "tolerance") }
    }

    /// Initial estimate of lens travel time per bar position (ms). Refined during each restore.
    static var msPerUnit: Double {
        get { d.object(forKey: "msPerUnit") == nil ? 7.5 : d.double(forKey: "msPerUnit") }
        set { d.set(newValue, forKey: "msPerUnit") }
    }

    /// Seconds to wait after the zoom reports ready before the first restore pulse.
    static var zoomWarmup: Double {
        get { d.object(forKey: "zoomWarmup") == nil ? 2.0 : d.double(forKey: "zoomWarmup") }
        set { d.set(newValue, forKey: "zoomWarmup") }
    }

    /// Seconds to wait after the camera appears before talking to it (ZV-1 needs ~3 s).
    static var connectDelay: Double {
        get { d.object(forKey: "connectDelay") == nil ? 3.0 : d.double(forKey: "connectDelay") }
        set { d.set(newValue, forKey: "connectDelay") }
    }
}

/// Owns the watcher and runs save/restore. Drives the menubar UI.
@MainActor
final class ZoomController: ObservableObject {
    enum Status: Equatable {
        case noCamera
        case connecting
        case idle          // camera present, no session open
        case working(String)
        case failed(String)

        var text: String {
            switch self {
            case .noCamera: return "Camera: not found"
            case .connecting: return "Camera: connecting…"
            case .idle: return "Camera: connected"
            case .working(let s): return s
            case .failed(let s): return "Error: \(s)"
            }
        }

        var isWorking: Bool { if case .working = self { return true } else { return false } }
    }

    @Published var status: Status = .noCamera {
        didSet { updateAnimation() }
    }
    @Published var currentZoom: SonyCamera.ZoomState?
    @Published var presetBar: Int? = Settings.presetBar
    @Published var presetScale: Int64? = Settings.presetScale
    @Published var restoreOnConnect: Bool = Settings.restoreOnConnect {
        didSet { Settings.restoreOnConnect = restoreOnConnect }
    }
    /// Frame index for the menubar animation while working.
    @Published var animationFrame = 0

    let watcher = CameraWatcher()
    private var camera: SonyCamera?
    private var busy = false
    private var animationTimer: Timer?

    init() {
        watcher.onAttach = { [weak self] cam in self?.attached(cam) }
        watcher.onDetach = { [weak self] in self?.detached() }
        watcher.start()
    }

    var hasPreset: Bool { presetBar != nil || presetScale != nil }

    var presetText: String {
        guard hasPreset else { return "No zoom saved" }
        var s = "Saved zoom:"
        if let sc = presetScale { s += String(format: " x%.2f", Double(sc) / 1000) }
        if let b = presetBar { s += " (pos \(b))" }
        return s
    }

    var zoomText: String {
        guard let z = currentZoom else { return "Zoom: –" }
        var s = String(format: "Zoom: x%.2f", z.magnification)
        if let p = z.barPosition { s += " (pos \(p))" }
        return s
    }

    // MARK: Animation

    private func updateAnimation() {
        if status.isWorking {
            guard animationTimer == nil else { return }
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.animationFrame = (self.animationFrame + 1) % MenuIcon.workingFrameCount
                }
            }
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
            animationFrame = 0
        }
    }

    // MARK: Events

    private func attached(_ cam: SonyCamera) {
        camera = cam
        status = .connecting
        Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(Settings.connectDelay * 1_000_000_000))
                if restoreOnConnect, hasPreset {
                    await restore(afterPowerOn: true)
                } else {
                    try await run("Reading zoom…") { cam in
                        self.currentZoom = try await cam.waitUntilZoomReady()
                    }
                }
            } catch {
                Log.error("connect failed: \(error)")
                status = .failed("\(error)")
            }
        }
    }

    private func detached() {
        camera = nil
        currentZoom = nil
        status = .noCamera
    }

    /// Open a session, do one thing, close the session. Serialized by `busy`.
    private func run(_ label: String, _ body: (SonyCamera) async throws -> Void) async throws {
        guard let cam = camera else { throw PTPError(opcode: 0, message: "no camera") }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        status = .working(label)
        do {
            try await cam.withSession { try await body(cam) }
            status = .idle
        } catch {
            status = .failed("\(error)")
            throw error
        }
    }

    // MARK: Actions

    func refresh() {
        Task {
            try? await run("Reading zoom…") { cam in
                self.currentZoom = try await cam.waitUntilZoomReady()
            }
        }
    }

    func savePreset() {
        Task {
            try? await run("Saving zoom…") { cam in
                let st = try await cam.waitUntilZoomReady()
                self.currentZoom = st
                self.presetBar = st.barPosition
                self.presetScale = st.scale
                Settings.presetBar = st.barPosition
                Settings.presetScale = st.scale
                Log.info("saved preset: \(st)")
            }
        }
    }

    func clearPreset() {
        presetBar = nil
        presetScale = nil
        Settings.presetBar = nil
        Settings.presetScale = nil
    }

    func restoreNow() {
        Task { await restore(afterPowerOn: false) }
    }

    private func restore(afterPowerOn: Bool) async {
        guard hasPreset else { return }
        do {
            try await run("Restoring zoom…") { cam in
                self.currentZoom = try await cam.waitUntilZoomReady()
                if afterPowerOn {
                    // Right after power-on the ZV-1 reports zoom as enabled a moment before it
                    // acts on ZoomOperation; the first pulse was lost without this pause.
                    try await Task.sleep(nanoseconds: UInt64(Settings.zoomWarmup * 1_000_000_000))
                }
                let final: SonyCamera.ZoomState
                if let b = self.presetBar {
                    final = try await cam.moveZoom(to: b, metric: .bar, tolerance: Settings.tolerance,
                                                   msPerUnit: Settings.msPerUnit) { [weak self] st in
                        self?.currentZoom = st
                    }
                } else {
                    final = try await cam.moveZoom(to: Int(self.presetScale!), metric: .scale, tolerance: 60,
                                                   msPerUnit: Settings.msPerUnit / 17, minStep: 120) { [weak self] st in
                        self?.currentZoom = st
                    }
                }
                self.currentZoom = final
                Log.info("restore finished at \(final)")
            }
        } catch {
            Log.error("restore failed: \(error)")
        }
    }

    /// Nudge the zoom by one pulse in either direction.
    func nudge(_ dir: SonyCamera.ZoomDirection) {
        Task {
            try? await run("Zooming…") { cam in
                try await cam.waitUntilZoomReady()
                try await cam.zoom(dir)
                try await Task.sleep(nanoseconds: UInt64(Settings.nudgeMs) * 1_000_000)
                try await cam.zoom(.stop)
                self.currentZoom = try await cam.waitUntilZoomSettled()
            }
        }
    }

    func reconnect() {
        guard let cam = camera else { return }
        Task {
            await cam.close()
            attached(cam)
        }
    }
}
