import Foundation

// MARK: - PTP wire format (USB transport, little-endian)
//
// Command block:  UInt32 length | UInt16 type (1) | UInt16 opcode | UInt32 txid | UInt32 params[0..5]
// Response block: UInt32 length | UInt16 type (3) | UInt16 respcode | UInt32 txid | UInt32 params[0..5]
//
// ImageCaptureCore's requestSendPTPCommand takes the command block as Data and returns
// the response block as Data, plus the data phase (device -> host) as a second Data.
// ptpcamerad owns the session and the transaction counter, so txid is sent as 0.

enum PTPContainerType: UInt16 {
    case command = 1
    case data = 2
    case response = 3
    case event = 4
}

enum PTPResponseCode: UInt16 {
    case ok = 0x2001
    case generalError = 0x2002
    case sessionNotOpen = 0x2003
    case invalidTransactionID = 0x2004
    case operationNotSupported = 0x2005
    case parameterNotSupported = 0x2006
    case incompleteTransfer = 0x2007
    case invalidStorageID = 0x2008
    case invalidObjectHandle = 0x2009
    case devicePropNotSupported = 0x200A
    case invalidObjectFormatCode = 0x200B
    case accessDenied = 0x200F
    case deviceBusy = 0x2019
    case invalidDevicePropFormat = 0x201B
    case invalidDevicePropValue = 0x201C
    case invalidParameter = 0x201D
    case sessionAlreadyOpen = 0x201E
    case transactionCancelled = 0x201F
}

struct PTPCommand {
    var opcode: UInt16
    var params: [UInt32] = []

    func encode() -> Data {
        precondition(params.count <= 5)
        var d = Data(capacity: 12 + 4 * params.count)
        d.appendLE(UInt32(12 + 4 * params.count))
        d.appendLE(PTPContainerType.command.rawValue)
        d.appendLE(opcode)
        d.appendLE(UInt32(0)) // transaction id, managed by ptpcamerad
        for p in params { d.appendLE(p) }
        return d
    }
}

struct PTPResponse {
    var length: UInt32
    var type: UInt16
    var code: UInt16
    var transactionID: UInt32
    var params: [UInt32]

    init?(_ d: Data) {
        guard d.count >= 12 else { return nil }
        length = d.readLE(UInt32.self, at: 0)
        type = d.readLE(UInt16.self, at: 4)
        code = d.readLE(UInt16.self, at: 6)
        transactionID = d.readLE(UInt32.self, at: 8)
        var ps: [UInt32] = []
        var off = 12
        while off + 4 <= d.count && ps.count < 5 {
            ps.append(d.readLE(UInt32.self, at: off))
            off += 4
        }
        params = ps
    }

    var isOK: Bool { code == PTPResponseCode.ok.rawValue }

    /// True if the header is consistent with a PTP response block of this buffer size.
    /// Standard response codes are 0x2xxx; vendor codes (Sony included) are 0xAxxx.
    func looksLikeContainer(size: Int) -> Bool {
        type == PTPContainerType.response.rawValue
            && ((code & 0xF000) == 0x2000 || (code & 0xF000) == 0xA000)
            && length >= 12 && length <= 32
            && Int(length) <= size
    }

    var describeCode: String {
        let hex = "0x" + String(code, radix: 16)
        if let c = PTPResponseCode(rawValue: code) { return "\(c) (\(hex))" }
        if let s = Self.sonyCodes[code] { return "Sony_\(s) (\(hex))" }
        return hex
    }

    /// Sony vendor response codes, from libgphoto2 ptp.h.
    static let sonyCodes: [UInt16: String] = [
        0xA101: "AuthenticationFailed",
        0xA102: "PasswordLengthOverMax",
        0xA103: "PasswordIncludesInvalidChar",
        0xA104: "FeatureVersionInvalidValue",
        0xA105: "TemporaryStorageFull",
        0xA106: "CameraStatusError",
    ]
}

struct PTPError: Error, CustomStringConvertible {
    var opcode: UInt16
    var message: String
    var description: String { "PTP op 0x\(String(opcode, radix: 16)): \(message)" }
}

// MARK: - PTP data types

enum PTPDataType: UInt16 {
    case undef = 0x0000
    case int8 = 0x0001
    case uint8 = 0x0002
    case int16 = 0x0003
    case uint16 = 0x0004
    case int32 = 0x0005
    case uint32 = 0x0006
    case int64 = 0x0007
    case uint64 = 0x0008
    case int128 = 0x0009
    case uint128 = 0x000A
    case aint8 = 0x4001
    case auint8 = 0x4002
    case aint16 = 0x4003
    case auint16 = 0x4004
    case aint32 = 0x4005
    case auint32 = 0x4006
    case aint64 = 0x4007
    case auint64 = 0x4008
    case str = 0xFFFF

    var scalarSize: Int? {
        switch self {
        case .int8, .uint8: return 1
        case .int16, .uint16: return 2
        case .int32, .uint32: return 4
        case .int64, .uint64: return 8
        case .int128, .uint128: return 16
        default: return nil
        }
    }

    var isSigned: Bool {
        switch self {
        case .int8, .int16, .int32, .int64, .int128: return true
        default: return false
        }
    }
}

/// A scalar property value, stored as Int64 for integers (wide enough for everything the Sony props use).
enum PTPValue: Equatable, CustomStringConvertible {
    case int(Int64)
    case string(String)
    case array([Int64])
    case raw(Data)

    var description: String {
        switch self {
        case .int(let v): return String(v)
        case .string(let s): return "\"\(s)\""
        case .array(let a): return "[" + a.map(String.init).joined(separator: ",") + "]"
        case .raw(let d): return "<" + d.map { String(format: "%02x", $0) }.joined() + ">"
        }
    }

    var intValue: Int64? {
        if case .int(let v) = self { return v }
        return nil
    }
}

/// Encode a scalar for a data phase (host -> device), in the property's declared type.
func ptpEncode(_ value: Int64, as type: PTPDataType) -> Data {
    var d = Data()
    switch type {
    case .int8: d.appendLE(Int8(truncatingIfNeeded: value))
    case .uint8: d.appendLE(UInt8(truncatingIfNeeded: value))
    case .int16: d.appendLE(Int16(truncatingIfNeeded: value))
    case .uint16: d.appendLE(UInt16(truncatingIfNeeded: value))
    case .int32: d.appendLE(Int32(truncatingIfNeeded: value))
    case .uint32: d.appendLE(UInt32(truncatingIfNeeded: value))
    case .int64: d.appendLE(value)
    case .uint64: d.appendLE(UInt64(bitPattern: value))
    default: preconditionFailure("cannot encode \(type)")
    }
    return d
}

/// Decode one value of `type` at `offset`, advancing it. Returns nil on short data.
func ptpDecode(_ d: Data, _ offset: inout Int, type: PTPDataType) -> PTPValue? {
    if let n = type.scalarSize {
        guard offset + n <= d.count else { return nil }
        let v: Int64
        switch type {
        case .int8: v = Int64(d.readLE(Int8.self, at: offset))
        case .uint8: v = Int64(d.readLE(UInt8.self, at: offset))
        case .int16: v = Int64(d.readLE(Int16.self, at: offset))
        case .uint16: v = Int64(d.readLE(UInt16.self, at: offset))
        case .int32: v = Int64(d.readLE(Int32.self, at: offset))
        case .uint32: v = Int64(d.readLE(UInt32.self, at: offset))
        case .int64: v = d.readLE(Int64.self, at: offset)
        case .uint64: v = Int64(bitPattern: d.readLE(UInt64.self, at: offset))
        default:
            // 128-bit: keep the raw bytes
            let raw = d.subdata(in: (d.startIndex + offset)..<(d.startIndex + offset + n))
            offset += n
            return .raw(raw)
        }
        offset += n
        return .int(v)
    }
    switch type {
    case .str:
        guard offset < d.count else { return nil }
        let len = Int(d.readLE(UInt8.self, at: offset)) // number of UTF-16 code units, including the NUL
        offset += 1
        guard offset + len * 2 <= d.count else { return nil }
        var units: [UInt16] = []
        for i in 0..<len {
            let u = d.readLE(UInt16.self, at: offset + i * 2)
            if u == 0 { break }
            units.append(u)
        }
        offset += len * 2
        return .string(String(utf16CodeUnits: units, count: units.count))
    case .aint8, .auint8, .aint16, .auint16, .aint32, .auint32, .aint64, .auint64:
        guard offset + 4 <= d.count else { return nil }
        let count = Int(d.readLE(UInt32.self, at: offset))
        offset += 4
        guard let elem = PTPDataType(rawValue: type.rawValue & 0x0FFF) else { return nil }
        var out: [Int64] = []
        for _ in 0..<count {
            guard let v = ptpDecode(d, &offset, type: elem), case .int(let iv) = v else { return nil }
            out.append(iv)
        }
        return .array(out)
    default:
        return nil
    }
}

// MARK: - Sony device property descriptor
//
// Layout of one entry in the GetAllExtDevicePropInfo (0x9209) blob, from libgphoto2's
// ptp_unpack_Sony_DPD:
//   UInt16 propcode | UInt16 datatype | UInt8 getset | UInt8 isEnabled
//   | default value | current value | UInt8 formflag
//   | (range: min, max, step) or (enum: UInt16 count, values...)
// The blob itself starts with UInt32 count, UInt32 zero.

struct SonyPropDesc: CustomStringConvertible {
    var code: UInt16
    var type: PTPDataType
    var getSet: UInt8
    var isEnabled: UInt8
    var defaultValue: PTPValue
    var currentValue: PTPValue
    var formFlag: UInt8 // 0 none, 1 range, 2 enum
    var rangeMin: PTPValue?
    var rangeMax: PTPValue?
    var rangeStep: PTPValue?
    var enumValues: [PTPValue] = []

    var description: String {
        let hex = String(format: "0x%04x", code)
        let name = SonyProp.name(code).padding(toLength: 20, withPad: " ", startingAt: 0)
        var s = "\(hex) \(name) type=\(type) getset=\(String(format: "0x%02x", getSet)) enabled=\(isEnabled) value=\(currentValue)"
        if formFlag == 1, let a = rangeMin, let b = rangeMax, let c = rangeStep {
            s += " range[\(a)..\(b) step \(c)]"
        } else if formFlag == 2 {
            s += " enum[" + enumValues.map { "\($0)" }.joined(separator: ",") + "]"
        }
        return s
    }
}

enum SonyDPDParser {
    /// Parse the full 0x9209 blob.
    static func parseAll(_ d: Data) -> [SonyPropDesc] {
        guard d.count > 8 else { return [] }
        var offset = 8
        var out: [SonyPropDesc] = []
        while offset < d.count {
            guard let p = parseOne(d, &offset) else { break }
            out.append(p)
        }
        return out
    }

    static func parseOne(_ d: Data, _ offset: inout Int) -> SonyPropDesc? {
        guard offset + 6 <= d.count else { return nil }
        let code = d.readLE(UInt16.self, at: offset)
        let typeRaw = d.readLE(UInt16.self, at: offset + 2)
        let getSet = d.readLE(UInt8.self, at: offset + 4)
        let isEnabled = d.readLE(UInt8.self, at: offset + 5)
        guard let type = PTPDataType(rawValue: typeRaw) else { return nil }
        offset += 6
        guard let def = ptpDecode(d, &offset, type: type) else { return nil }
        if type == .str && offset == d.count {
            return SonyPropDesc(code: code, type: type, getSet: getSet, isEnabled: isEnabled,
                                defaultValue: def, currentValue: def, formFlag: 0)
        }
        guard let cur = ptpDecode(d, &offset, type: type) else { return nil }
        var desc = SonyPropDesc(code: code, type: type, getSet: getSet, isEnabled: isEnabled,
                                defaultValue: def, currentValue: cur, formFlag: 0)
        guard offset < d.count else { return desc }
        let form = d.readLE(UInt8.self, at: offset)
        offset += 1
        desc.formFlag = form
        switch form {
        case 1:
            desc.rangeMin = ptpDecode(d, &offset, type: type)
            desc.rangeMax = ptpDecode(d, &offset, type: type)
            desc.rangeStep = ptpDecode(d, &offset, type: type)
            if desc.rangeStep == nil { return nil }
        case 2:
            guard offset + 2 <= d.count else { return nil }
            let n = Int(d.readLE(UInt16.self, at: offset))
            offset += 2
            for _ in 0..<n {
                guard let v = ptpDecode(d, &offset, type: type) else { break }
                desc.enumValues.append(v)
            }
        default:
            break
        }
        return desc
    }
}

// MARK: - Sony opcodes and property codes (from libgphoto2 ptp.h; the ZV-1 reports all of these)

enum SonyOp {
    static let sdioConnect: UInt16 = 0x9201
    static let getExtDeviceInfo: UInt16 = 0x9202
    static let getDevicePropDesc: UInt16 = 0x9203
    static let getDevicePropValue: UInt16 = 0x9204
    static let setExtDevicePropValue: UInt16 = 0x9205 // "ControlDeviceA": set a value
    static let getControlDeviceDesc: UInt16 = 0x9206
    static let controlDevice: UInt16 = 0x9207 // "ControlDeviceB": press a button
    static let getAllExtDevicePropInfo: UInt16 = 0x9209
}

enum SonyProp {
    static let zoomAbsolute: UInt16 = 0xD214 // UINT32; libgphoto2 treats as focal length * 1e6; unverified on ZV-1
    static let priorityMode: UInt16 = 0xD25A // not present on ZV-1
    static let zoomEnableStatus: UInt16 = 0xD25B // UINT8 0/1
    static let zoomScale: UInt16 = 0xD25C // UINT32, magnification * 1000 (1000 = 1.0x)
    static let zoomBarInformation: UInt16 = 0xD25D // UINT32, packed
    static let zoomSpeedRange: UInt16 = 0xD25E // not present on ZV-1
    static let zoomSetting: UInt16 = 0xD25F // UINT8 1 optical only, 3 clear image zoom, 4 digital zoom
    static let zoomTypeStatus: UInt16 = 0xD260 // UINT8
    static let zoomOperation: UInt16 = 0xD2DD // INT8 -1 wide, 0 stop, +1 tele (ControlDevice)
    static let saveZoomAndFocusPosition: UInt16 = 0xD2E9 // newer bodies only
    static let loadZoomAndFocusPosition: UInt16 = 0xD2EA // newer bodies only

    static func name(_ c: UInt16) -> String {
        switch c {
        case zoomAbsolute: return "Zoom(abs?)"
        case priorityMode: return "PriorityMode"
        case zoomEnableStatus: return "ZoomEnableStatus"
        case zoomScale: return "ZoomScale"
        case zoomBarInformation: return "ZoomBarInformation"
        case zoomSpeedRange: return "ZoomSpeedRange"
        case zoomSetting: return "ZoomSetting"
        case zoomTypeStatus: return "ZoomTypeStatus"
        case zoomOperation: return "ZoomOperation"
        case saveZoomAndFocusPosition: return "SaveZoomFocusPos"
        case loadZoomAndFocusPosition: return "LoadZoomFocusPos"
        case 0x5007: return "FNumber"
        case 0x500A: return "FocusMode"
        case 0x500E: return "ExposureProgramMode"
        case 0xD20D: return "ShutterSpeed"
        case 0xD218: return "BatteryLevel"
        case 0xD21E: return "ISO"
        case 0xD2C1: return "ShutterHalfRelease"
        case 0xD2C2: return "ShutterRelease"
        case 0xD2C8: return "Movie"
        default: return ""
        }
    }
}

// MARK: - Data helpers

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        let n = MemoryLayout<T>.size
        var v: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &v) { dst in
            self.copyBytes(to: dst, from: (startIndex + offset)..<(startIndex + offset + n))
        }
        return T(littleEndian: v)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}
