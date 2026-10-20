import Foundation
import AppKit

// Entry point. With no arguments this runs the menubar app. With a subcommand it runs a
// one-shot diagnostic against the camera and exits, which is the right way to find out
// what your particular camera does before trusting the app.

let usage = """
ZVZoom - remember and restore the zoom position of a Sony ZV-1 over USB (PC Remote mode)

usage:
  ZVZoom                      run the menubar app
  ZVZoom [-v] dump            handshake, then print every property the camera reports
  ZVZoom [-v] get             print the current zoom state
  ZVZoom [-v] set <mag>       drive the zoom to a magnification, e.g. 1.8 (coarse: ZoomScale)
  ZVZoom [-v] pos <n>         drive the zoom to a bar position (fine: ZoomBarInformation)
  ZVZoom [-v] roundtrip       save the current position, zoom away, restore, report the error
  ZVZoom [-v] calib [ms ...]  measure positions moved per pulse length, tele then wide
  ZVZoom [-v] op <tele|wide|stop> [ms]
                              press a zoom direction for ms milliseconds (default 150) then stop
  ZVZoom [-v] abs <value>     EXPERIMENTAL: write property 0xD214 directly
  ZVZoom [-v] raw <opcode> [p1 p2 ...]
                              send a data-in PTP operation (hex) and hex-dump the reply
  ZVZoom [-v] watch           print zoom state every second until Ctrl-C

Log file: ~/Library/Logs/ZVZoom.log
"""

var args = Array(CommandLine.arguments.dropFirst())
if let i = args.firstIndex(of: "-v") {
    Log.verbose = true
    args.remove(at: i)
}

if args.isEmpty {
    ZVZoomApp.main()
    exit(0)
}

if args[0] == "-h" || args[0] == "--help" || args[0] == "help" {
    print(usage)
    exit(0)
}

@MainActor
func waitForCamera(_ watcher: CameraWatcher, timeout: TimeInterval = 30) async throws -> SonyCamera {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let c = watcher.camera { return c }
        try await Task.sleep(nanoseconds: 200_000_000)
    }
    throw PTPError(opcode: 0, message: "no Sony camera appeared in \(Int(timeout))s. Is USB Connection set to PC Remote and the camera on?")
}

@MainActor
func runCLI(_ args: [String]) async -> Int32 {
    let watcher = CameraWatcher()
    watcher.start()
    var camRef: SonyCamera?
    defer { camRef?.close() }
    do {
        print("waiting for camera…")
        let cam = try await waitForCamera(watcher)
        camRef = cam
        print("found \(cam.device.name ?? "camera"), waiting \(Settings.connectDelay)s before handshake")
        try await Task.sleep(nanoseconds: UInt64(Settings.connectDelay * 1_000_000_000))
        try await cam.handshake()
        print("handshake ok, protocol version \(cam.protocolVersion)")

        switch args[0] {
        case "dump":
            let codes = cam.supportedCodes.map { String(format: "0x%04x", $0) }
            print("vendor codes (\(codes.count)): " + codes.joined(separator: " "))
            let props = try await cam.refreshProps()
            let declared = cam.lastPropBlob.count >= 4 ? cam.lastPropBlob.readLE(UInt32.self, at: 0) : 0
            print("properties (parsed \(props.count), camera declared \(declared)):")
            for p in props.values.sorted(by: { $0.code < $1.code }) {
                print("  \(p)")
            }
            if Log.verbose {
                print("raw property blob (\(cam.lastPropBlob.count) bytes):")
                print(cam.lastPropBlob.hexString)
            }
            let z = try await cam.zoomState()
            print("zoom: \(z)")

        case "get":
            let z = try await cam.waitUntilZoomReady()
            print("zoom: \(z)")

        case "set":
            guard args.count >= 2, let mag = Double(args[1]) else { print(usage); return 2 }
            let target = Int((mag * 1000).rounded())
            let final = try await cam.moveZoom(to: target, metric: .scale, tolerance: 50,
                                               msPerUnit: Settings.msPerUnit / 25) { st in
                print("  now \(st)")
            }
            print(String(format: "done: x%.2f (target x%.2f)", final.magnification, mag))

        case "pos":
            guard args.count >= 2, let target = Int(args[1]) else { print(usage); return 2 }
            let final = try await cam.moveZoom(to: target, metric: .bar, tolerance: Settings.tolerance,
                                               msPerUnit: Settings.msPerUnit) { st in
                print("  now \(st)")
            }
            print("done: \(final) (target pos \(target))")

        case "calib":
            // Characterize the lens response: pulse lengths vs positions moved, both directions.
            let lengths = args.count >= 2 ? args.dropFirst().compactMap { Int($0) } : [100, 150, 200, 250, 300, 400, 600]
            var st = try await cam.waitUntilZoomReady()
            print("start: \(st)")
            print(" pulse_ms  dir   from   to   moved  first_change_s  last_change_s   (times from the start command; polled for 3 s after stop)")
            for ms in lengths {
                for dir in [SonyCamera.ZoomDirection.tele, .wide] {
                    let from = st.barPosition ?? -1
                    let t0 = Date()
                    try await cam.zoom(dir)
                    try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                    try await cam.zoom(.stop)
                    // Poll quickly for 3 s after the stop and note when the report changes.
                    var firstChange: TimeInterval = -1, lastChange: TimeInterval = -1
                    var prevPos = from
                    let deadline = Date().addingTimeInterval(3.0)
                    while Date() < deadline {
                        st = try await cam.zoomState()
                        let p = st.barPosition ?? -1
                        if p != prevPos {
                            let t = Date().timeIntervalSince(t0)
                            if firstChange < 0 { firstChange = t }
                            lastChange = t
                            prevPos = p
                        }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    let to = st.barPosition ?? -1
                    print(String(format: " %7d  %@  %4d  %4d  %5d  %14.2f  %13.2f", ms, dir == .tele ? "tele" : "wide", from, to, to - from, firstChange, lastChange))
                }
            }
            print("end: \(st)")

        case "roundtrip":
            // Save the current position, move away, restore, report the error.
            let start = try await cam.waitUntilZoomReady()
            guard let home = start.barPosition else { print("no bar position reported"); return 1 }
            print("start: \(start)")
            let awayDir: SonyCamera.ZoomDirection = home < 30 ? .tele : .wide
            try await cam.zoom(awayDir)
            try await Task.sleep(nanoseconds: 600_000_000)
            try await cam.zoom(.stop)
            let away = try await cam.waitUntilZoomSettled()
            print("moved away: \(away)")
            let t0 = Date()
            let final = try await cam.moveZoom(to: home, metric: .bar, tolerance: Settings.tolerance,
                                               msPerUnit: Settings.msPerUnit) { st in
                print(String(format: "  +%4.1f s  %@", Date().timeIntervalSince(t0), "\(st)"))
            }
            print("restored: \(final)")
            print("error: \((final.barPosition ?? -1) - home) positions, took \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")

        case "op":
            guard args.count >= 2 else { print(usage); return 2 }
            let ms = args.count >= 3 ? Int(args[2]) ?? 150 : 150
            let dir: SonyCamera.ZoomDirection
            switch args[1] {
            case "tele", "in", "+": dir = .tele
            case "wide", "out", "-": dir = .wide
            default: dir = .stop
            }
            let before = try await cam.waitUntilZoomReady()
            print("before: \(before)")
            let t0 = Date()
            try await cam.zoom(dir)
            if dir != .stop {
                try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                try await cam.zoom(.stop)
            }
            // Show how the reported scale settles after the stop.
            let after = try await cam.waitUntilZoomSettled(timeout: 3) { st in
                print(String(format: "  +%4.0f ms  %@", Date().timeIntervalSince(t0) * 1000, "\(st)"))
            }
            print("after:  \(after)")

        case "abs":
            guard args.count >= 2, let v = Int64(args[1]) else { print(usage); return 2 }
            let before = try await cam.zoomState()
            print("before: \(before)")
            let type = cam.props[SonyProp.zoomAbsolute]?.type ?? .uint32
            try await cam.setValue(SonyProp.zoomAbsolute, v, type: type)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let after = try await cam.zoomState()
            print("after:  \(after)")

        case "raw":
            guard args.count >= 2, let op = UInt16(args[1].replacingOccurrences(of: "0x", with: ""), radix: 16) else {
                print(usage); return 2
            }
            let params = args.dropFirst(2).compactMap { UInt32($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
            let (resp, data) = try await cam.send(op, params)
            print("response: \(resp.describeCode) params \(resp.params)")
            print("data (\(data.count) bytes): \(data.hexString)")

        case "watch":
            while true {
                let z = try await cam.zoomState()
                print("\(Date()): \(z)")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }

        default:
            print(usage)
            return 2
        }
        return 0
    } catch {
        print("error: \(error)")
        return 1
    }
}

// ImageCaptureCore delivers its callbacks on the main run loop, so keep it spinning.
let cliArgs = args
Task { @MainActor in
    let code = await runCLI(cliArgs)
    exit(code)
}
RunLoop.main.run()
