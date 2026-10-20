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
        get { d.object(forKey: "tolerance") == nil ? 1 : d.integer(forKey: "tolerance") }
        set { d.set(newValue, forKey: "tolerance") }
    }

    /// Initial estimate of lens travel time per bar position (ms). Refined during each restore.
    static var msPerUnit: Double {
        get { d.object(forKey: "msPerUnit") == nil ? 15 : d.double(forKey: "msPerUnit") }
        set { d.set(newValue, forKey: "msPerUnit") }
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
        case ready
        case working(String)
        case failed(String)

        var text: String {
            switch self {
            case .noCamera: return "Camera: not found"
            case .connecting: return "Camera: connecting…"
            case .ready: return "Camera: ready"
            case .working(let s): return s
            case .failed(let s): return "Error: \(s)"
            }
        }
    }

    @Published var status: Status = .noCamera
    @Published var currentZoom: SonyCamera.ZoomState?
    @Published var presetBar: Int? = Settings.presetBar
    @Published var presetScale: Int64? = Settings.presetScale
    @Published var restoreOnConnect: Bool = Settings.restoreOnConnect {
        didSet { Settings.restoreOnConnect = restoreOnConnect }
    }

    let watcher = CameraWatcher()
    private var camera: SonyCamera?
    private var busy = false

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

    // MARK: Events

    private func attached(_ cam: SonyCamera) {
        camera = cam
        status = .connecting
        Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(Settings.connectDelay * 1_000_000_000))
                try await cam.handshake()
                currentZoom = try await cam.waitUntilZoomReady()
                status = .ready
                Log.info("camera ready, zoom \(currentZoom!)")
                if restoreOnConnect, hasPreset {
                    await restore()
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

    // MARK: Actions

    func refresh() {
        guard let cam = camera, !busy else { return }
        Task {
            do { currentZoom = try await cam.zoomState() } catch { status = .failed("\(error)") }
        }
    }

    func savePreset() {
        guard let cam = camera, !busy else { return }
        Task {
            do {
                let st = try await cam.waitUntilZoomReady()
                currentZoom = st
                presetBar = st.barPosition
                presetScale = st.scale
                Settings.presetBar = st.barPosition
                Settings.presetScale = st.scale
                Log.info("saved preset: \(st)")
            } catch {
                status = .failed("\(error)")
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
        Task { await restore() }
    }

    private func restore() async {
        guard let cam = camera, hasPreset, !busy else { return }
        busy = true
        defer { busy = false }
        status = .working("Restoring zoom…")
        do {
            let final: SonyCamera.ZoomState
            if let b = presetBar {
                final = try await cam.moveZoom(to: b, metric: .bar, tolerance: Settings.tolerance,
                                               msPerUnit: Settings.msPerUnit) { [weak self] st in
                    self?.currentZoom = st
                }
            } else {
                final = try await cam.moveZoom(to: Int(presetScale!), metric: .scale, tolerance: 50,
                                               msPerUnit: Settings.msPerUnit / 25) { [weak self] st in
                    self?.currentZoom = st
                }
            }
            currentZoom = final
            status = .ready
            Log.info("restore finished at \(final)")
        } catch {
            Log.error("restore failed: \(error)")
            status = .failed("\(error)")
        }
    }

    /// Nudge the zoom by one pulse in either direction.
    func nudge(_ dir: SonyCamera.ZoomDirection) {
        guard let cam = camera, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await cam.zoom(dir)
                try await Task.sleep(nanoseconds: UInt64(Settings.nudgeMs) * 1_000_000)
                try await cam.zoom(.stop)
                currentZoom = try await cam.waitUntilZoomSettled()
                status = .ready
            } catch {
                status = .failed("\(error)")
            }
        }
    }

    func reconnect() {
        guard let cam = camera else { return }
        cam.close()
        attached(cam)
    }
}
