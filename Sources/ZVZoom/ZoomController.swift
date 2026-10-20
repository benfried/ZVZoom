import Foundation
import Combine

/// Persisted settings.
enum Settings {
    private static let d = UserDefaults.standard

    /// Saved zoom as ZoomScale (magnification * 1000). nil = nothing saved yet.
    static var presetScale: Int64? {
        get { d.object(forKey: "presetScale") == nil ? nil : Int64(d.integer(forKey: "presetScale")) }
        set { if let v = newValue { d.set(Int(v), forKey: "presetScale") } else { d.removeObject(forKey: "presetScale") } }
    }

    static var restoreOnConnect: Bool {
        get { d.object(forKey: "restoreOnConnect") == nil ? true : d.bool(forKey: "restoreOnConnect") }
        set { d.set(newValue, forKey: "restoreOnConnect") }
    }

    /// How long a single zoom pulse lasts when fine-tuning (ms).
    static var pulseMs: Int {
        get { d.object(forKey: "pulseMs") == nil ? 80 : d.integer(forKey: "pulseMs") }
        set { d.set(newValue, forKey: "pulseMs") }
    }

    /// Accept this much ZoomScale error (ZV-1 reports in steps of 100 at the wide end).
    static var tolerance: Int64 {
        get { d.object(forKey: "tolerance") == nil ? 50 : Int64(d.integer(forKey: "tolerance")) }
        set { d.set(Int(newValue), forKey: "tolerance") }
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

    var presetText: String {
        guard let p = presetScale else { return "No zoom saved" }
        return String(format: "Saved zoom: x%.2f", Double(p) / 1000)
    }

    var zoomText: String {
        guard let z = currentZoom else { return "Zoom: –" }
        return String(format: "Zoom: x%.2f", z.magnification)
    }

    // MARK: Events

    private func attached(_ cam: SonyCamera) {
        camera = cam
        status = .connecting
        Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(Settings.connectDelay * 1_000_000_000))
                try await cam.handshake()
                try await cam.waitUntilZoomReady()
                currentZoom = try await cam.zoomState()
                status = .ready
                Log.info("camera ready, zoom \(currentZoom!)")
                if restoreOnConnect, presetScale != nil {
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
                let st = try await cam.zoomState()
                currentZoom = st
                presetScale = st.scale
                Settings.presetScale = st.scale
                Log.info("saved preset scale \(st.scale)")
            } catch {
                status = .failed("\(error)")
            }
        }
    }

    func clearPreset() {
        presetScale = nil
        Settings.presetScale = nil
    }

    func restoreNow() {
        Task { await restore() }
    }

    private func restore() async {
        guard let cam = camera, let target = presetScale, !busy else { return }
        busy = true
        defer { busy = false }
        status = .working(String(format: "Restoring zoom to x%.2f…", Double(target) / 1000))
        do {
            try await cam.waitUntilZoomReady()
            let final = try await cam.moveZoom(toScale: target, tolerance: Settings.tolerance,
                                               pulseMs: Settings.pulseMs) { [weak self] st in
                self?.currentZoom = st
            }
            currentZoom = try await cam.zoomState()
            status = .ready
            Log.info("restore finished at scale \(final)")
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
                try await Task.sleep(nanoseconds: UInt64(Settings.pulseMs) * 1_000_000)
                try await cam.zoom(.stop)
                try await Task.sleep(nanoseconds: 200_000_000)
                currentZoom = try await cam.zoomState()
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
