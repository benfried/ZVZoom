import Foundation
import ImageCaptureCore

// MARK: - Logging

enum Log {
    static var verbose = false
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ZVZoom.log")
    }()
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()

    static func info(_ s: String) { write("I", s) }
    static func debug(_ s: String) { if verbose { write("D", s) } }
    static func error(_ s: String) { write("E", s) }

    private static func write(_ level: String, _ s: String) {
        let line = "\(fmt.string(from: Date())) \(level) \(s)\n"
        FileHandle.standardError.write(line.data(using: .utf8)!)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Device discovery

/// Watches ImageCaptureCore for Sony cameras in PC Remote mode.
@MainActor
final class CameraWatcher: NSObject, ICDeviceBrowserDelegate, ObservableObject {
    static let sonyVendorID = 0x054C
    static let zv1PCRemoteProductID = 0x0C44 // ZV-1 in PC Remote mode (0x0C1B is MTP mode)

    @Published private(set) var camera: SonyCamera?
    var onAttach: ((SonyCamera) -> Void)?
    var onDetach: (() -> Void)?

    private let browser = ICDeviceBrowser()

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)
    }

    func start() {
        Log.info("device browser starting")
        browser.start()
    }

    func stop() {
        browser.stop()
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in self.handleAdd(device) }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in self.handleRemove(device) }
    }

    private func handleAdd(_ device: ICDevice) {
        let vid = device.usbVendorID, pid = device.usbProductID
        Log.info("device added: \(device.name ?? "?") usb \(String(vid, radix: 16)):\(String(pid, radix: 16)) transport=\(device.transportType ?? "?")")
        guard let cam = device as? ICCameraDevice else { return }
        let isSony = vid == Self.sonyVendorID || (device.name ?? "").lowercased().contains("zv-1")
        guard isSony else { return }
        if pid != Self.zv1PCRemoteProductID {
            Log.info("Sony camera found but not in PC Remote mode (product id 0x\(String(pid, radix: 16))). Set MENU > Setup > USB Connection > PC Remote.")
        }
        if camera != nil {
            Log.info("ignoring second camera")
            return
        }
        let sc = SonyCamera(device: cam)
        camera = sc
        onAttach?(sc)
    }

    private func handleRemove(_ device: ICDevice) {
        Log.info("device removed: \(device.name ?? "?")")
        if let c = camera, c.device === device {
            c.invalidate()
            camera = nil
            onDetach?()
        }
    }
}

// MARK: - Camera session

/// One Sony camera reached through ptpcamerad. All PTP traffic goes through
/// ICCameraDevice.requestSendPTPCommand, so there is no fight over the USB interface.
@MainActor
final class SonyCamera: NSObject, ICCameraDeviceDelegate {
    let device: ICCameraDevice
    private(set) var isOpen = false
    private(set) var handshakeDone = false
    private(set) var protocolVersion: Int = 0
    private(set) var supportedCodes: [UInt16] = []
    private(set) var props: [UInt16: SonyPropDesc] = [:]
    private var openContinuation: CheckedContinuation<Void, Error>?

    init(device: ICCameraDevice) {
        self.device = device
        super.init()
        device.delegate = self
    }

    func invalidate() {
        isOpen = false
        handshakeDone = false
        openContinuation?.resume(throwing: PTPError(opcode: 0, message: "device removed"))
        openContinuation = nil
    }

    // MARK: Session

    func open() async throws {
        if isOpen { return }
        Log.info("opening session with \(device.name ?? "camera")")
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            openContinuation = c
            device.requestOpenSession()
        }
        isOpen = true
    }

    func close() {
        if isOpen {
            device.requestCloseSession()
            isOpen = false
            handshakeDone = false
        }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        Task { @MainActor in
            if let e = error {
                Log.error("open session failed: \(e)")
                self.openContinuation?.resume(throwing: e)
            } else {
                Log.info("session open")
                self.openContinuation?.resume()
            }
            self.openContinuation = nil
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        Task { @MainActor in
            Log.info("session closed \(error.map { "(\($0))" } ?? "")")
            self.isOpen = false
            self.handshakeDone = false
        }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor in self.invalidate() }
    }

    // Required ICCameraDeviceDelegate methods we do not use.
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {}
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        Task { @MainActor in
            Log.debug("PTP event: \(eventData.hexString)")
        }
    }

    // MARK: Raw PTP

    /// Send one PTP operation. Returns the parsed response and the inbound data phase.
    @discardableResult
    func send(_ opcode: UInt16, _ params: [UInt32] = [], data: Data? = nil,
              timeout: TimeInterval = 8) async throws -> (PTPResponse, Data) {
        let cmd = PTPCommand(opcode: opcode, params: params).encode()
        Log.debug("-> op 0x\(String(opcode, radix: 16)) params=[\(params.map { "0x" + String($0, radix: 16) }.joined(separator: ","))] out=\(data?.hexString ?? "-")")
        let (respData, inData) = try await withThrowingTaskGroup(of: (Data, Data).self) { group in
            group.addTask { try await self.device.requestSendPTPCommand(cmd, outData: data) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw PTPError(opcode: opcode, message: "timeout after \(timeout)s")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        guard let resp = PTPResponse(respData) else {
            throw PTPError(opcode: opcode, message: "short response (\(respData.count) bytes): \(respData.hexString)")
        }
        Log.debug("<- resp \(resp.describeCode) params=[\(resp.params.map { "0x" + String($0, radix: 16) }.joined(separator: ","))] in=\(inData.count) bytes")
        guard resp.isOK else {
            throw PTPError(opcode: opcode, message: "response \(resp.describeCode)")
        }
        return (resp, inData)
    }

    // MARK: Sony handshake (same sequence as libgphoto2 camera_init)

    func handshake() async throws {
        if handshakeDone { return }
        try await open()
        try await send(SonyOp.sdioConnect, [1, 0, 0])
        try await send(SonyOp.sdioConnect, [2, 0, 0])

        // Ask for protocol 3.00 (0x12c); older bodies answer with the version they support.
        var codes: [UInt16] = []
        for _ in 0..<20 {
            let (_, info) = try await send(SonyOp.getExtDeviceInfo, [0x12C, 1])
            if info.count >= 2 {
                protocolVersion = Int(info.readLE(UInt16.self, at: 0))
                var off = 2
                if let a = ptpDecode(info, &off, type: .auint16), case .array(let arr) = a {
                    codes += arr.map { UInt16($0) }
                }
                if let b = ptpDecode(info, &off, type: .auint16), case .array(let arr) = b {
                    codes += arr.map { UInt16($0) }
                }
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        supportedCodes = codes
        Log.info("Sony protocol version \(protocolVersion) (0x\(String(protocolVersion, radix: 16))), \(codes.count) vendor codes")

        try await send(SonyOp.sdioConnect, [3, 0, 0])

        // Newer bodies expose PriorityMode; set it to "PC" like libgphoto2 does. The ZV-1 does not have it.
        if supportedCodes.contains(SonyProp.priorityMode) {
            do {
                try await setValue(SonyProp.priorityMode, 1, type: .int8)
            } catch {
                Log.info("PriorityMode not accepted: \(error)")
            }
        }
        handshakeDone = true
        Log.info("handshake complete")
    }

    // MARK: Properties

    /// Refresh every property descriptor from the camera.
    @discardableResult
    func refreshProps() async throws -> [UInt16: SonyPropDesc] {
        let (_, blob) = try await send(SonyOp.getAllExtDevicePropInfo)
        let list = SonyDPDParser.parseAll(blob)
        var dict: [UInt16: SonyPropDesc] = [:]
        for p in list { dict[p.code] = p }
        props = dict
        Log.debug("refreshed \(list.count) properties")
        return dict
    }

    func intValue(_ code: UInt16) async throws -> Int64? {
        try await refreshProps()
        return props[code]?.currentValue.intValue
    }

    /// SetExtDevicePropValue (0x9205): set a property to a value.
    func setValue(_ code: UInt16, _ value: Int64, type: PTPDataType) async throws {
        try await send(SonyOp.setExtDevicePropValue, [UInt32(code)], data: ptpEncode(value, as: type))
    }

    /// ControlDevice (0x9207): press/release a control such as ZoomOperation.
    func control(_ code: UInt16, _ value: Int64, type: PTPDataType) async throws {
        try await send(SonyOp.controlDevice, [UInt32(code)], data: ptpEncode(value, as: type))
    }

    // MARK: Zoom

    struct ZoomState: CustomStringConvertible {
        var scale: Int64 // magnification * 1000
        var enabled: Bool
        var barInfo: Int64?
        var absolute: Int64?
        var setting: Int64?
        var typeStatus: Int64?

        var magnification: Double { Double(scale) / 1000 }
        var description: String {
            var s = String(format: "x%.2f (scale %lld)", magnification, scale) + " enabled=\(enabled ? "yes" : "no")"
            if let b = barInfo { s += " bar=0x" + String(UInt64(bitPattern: b), radix: 16) }
            if let a = absolute { s += " abs=\(a)" }
            if let t = setting { s += " setting=\(t)" }
            if let ts = typeStatus { s += " type=\(ts)" }
            return s
        }
    }

    func zoomState() async throws -> ZoomState {
        try await refreshProps()
        guard let scale = props[SonyProp.zoomScale]?.currentValue.intValue else {
            throw PTPError(opcode: SonyOp.getAllExtDevicePropInfo, message: "camera did not report ZoomScale (0xD25C)")
        }
        return ZoomState(
            scale: scale,
            enabled: (props[SonyProp.zoomEnableStatus]?.currentValue.intValue ?? 1) != 0,
            barInfo: props[SonyProp.zoomBarInformation]?.currentValue.intValue,
            absolute: props[SonyProp.zoomAbsolute]?.currentValue.intValue,
            setting: props[SonyProp.zoomSetting]?.currentValue.intValue,
            typeStatus: props[SonyProp.zoomTypeStatus]?.currentValue.intValue)
    }

    enum ZoomDirection: Int64 { case wide = -1, stop = 0, tele = 1 }

    /// Start or stop the power zoom. The lens keeps moving until .stop is sent.
    func zoom(_ dir: ZoomDirection) async throws {
        let type = props[SonyProp.zoomOperation]?.type ?? .int8
        try await control(SonyProp.zoomOperation, dir.rawValue, type: type)
    }

    /// Wait until the camera reports zoom as usable (lens extended after power-on).
    func waitUntilZoomReady(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let st = try? await zoomState(), st.enabled { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw PTPError(opcode: 0, message: "zoom not ready after \(timeout)s")
    }

    /// Drive the zoom to a target ZoomScale value (magnification * 1000) using ZoomOperation
    /// pulses with ZoomScale feedback. Returns the final scale.
    @discardableResult
    func moveZoom(toScale target: Int64, tolerance: Int64 = 50, pulseMs: Int = 80,
                  maxIterations: Int = 40, progress: ((ZoomState) -> Void)? = nil) async throws -> Int64 {
        var last: Int64 = -1
        var stalls = 0
        for i in 0..<maxIterations {
            let st = try await zoomState()
            progress?(st)
            let diff = target - st.scale
            if abs(diff) <= tolerance {
                Log.info("zoom at target: \(st)")
                return st.scale
            }
            if st.scale == last { stalls += 1 } else { stalls = 0 }
            last = st.scale
            if stalls >= 6 {
                Log.info("zoom not moving, giving up at \(st)")
                return st.scale
            }
            let dir: ZoomDirection = diff > 0 ? .tele : .wide
            let far = abs(diff) >= 500
            Log.debug("iteration \(i): scale \(st.scale) target \(target) -> \(dir) \(far ? "continuous" : "pulse")")
            try await zoom(dir)
            if far {
                // Drive continuously, poll, stop when close.
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    try await Task.sleep(nanoseconds: 60_000_000)
                    let now = try await zoomState()
                    progress?(now)
                    let remaining = target - now.scale
                    if abs(remaining) < 300 || (remaining > 0) != (diff > 0) { break }
                }
                try await zoom(.stop)
            } else {
                try await Task.sleep(nanoseconds: UInt64(pulseMs) * 1_000_000)
                try await zoom(.stop)
            }
            try await Task.sleep(nanoseconds: 200_000_000) // let the lens settle before reading
        }
        let final = try await zoomState()
        Log.info("zoom loop exhausted at \(final)")
        return final.scale
    }
}
