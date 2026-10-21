import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

/// Re-enumerate a USB device from software. To the device this looks like an unplug/replug:
/// the host drops the connection and enumerates it again a moment later.
enum USBReset {
    enum Failure: Error, CustomStringConvertible {
        case notFound
        case plugin(Int32)
        case interface(Int32)
        case open(Int32)
        case reenumerate(Int32)

        var description: String {
            switch self {
            case .notFound: return "USB device not found"
            case .plugin(let r): return "IOCreatePlugInInterfaceForService failed: 0x\(String(UInt32(bitPattern: r), radix: 16))"
            case .interface(let r): return "QueryInterface failed: 0x\(String(UInt32(bitPattern: r), radix: 16))"
            case .open(let r): return "USBDeviceOpen failed: 0x\(String(UInt32(bitPattern: r), radix: 16))"
            case .reenumerate(let r): return "USBDeviceReEnumerate failed: 0x\(String(UInt32(bitPattern: r), radix: 16))"
            }
        }
    }

    // These are C macros in IOKit headers and are not imported into Swift.
    private static let pluginInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    private static let usbDeviceUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil,
        0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xd4, 0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
    private static let usbDeviceInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
        0x5c, 0x81, 0x87, 0xd0, 0x9e, 0xf3, 0x11, 0xD4, 0x8b, 0x45, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)

    /// Find the first device matching vendor/product and ask the host to re-enumerate it.
    static func reenumerate(vendorID: Int, productID: Int) throws {
        guard let matching = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary? else {
            throw Failure.notFound
        }
        matching[kUSBVendorID] = vendorID
        matching[kUSBProductID] = productID

        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else { throw Failure.notFound }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { throw Failure.notFound }
        defer { IOObjectRelease(service) }

        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let pr = IOCreatePlugInInterfaceForService(service, usbDeviceUserClientTypeID, pluginInterfaceID, &plugin, &score)
        guard pr == KERN_SUCCESS, let plugin else { throw Failure.plugin(pr) }
        defer { _ = plugin.pointee?.pointee.Release(plugin) }

        var deviceInterfacePtr: UnsafeMutableRawPointer?
        let qr = withUnsafeMutablePointer(to: &deviceInterfacePtr) { ptr -> HRESULT in
            ptr.withMemoryRebound(to: Optional<LPVOID>.self, capacity: 1) { lp in
                plugin.pointee!.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(usbDeviceInterfaceID), lp)
            }
        }
        guard qr == S_OK, let raw = deviceInterfacePtr else { throw Failure.interface(qr) }
        let dev = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface>?.self)
        defer { _ = dev.pointee?.pointee.Release(dev) }

        // Opening the device (not an interface) does not conflict with ptpcamerad's claim on
        // the PTP interface; re-enumeration does not require the open to succeed on every OS,
        // so try without it first.
        var rr = dev.pointee!.pointee.USBDeviceReEnumerate(dev, 0)
        if rr != KERN_SUCCESS {
            let orr = dev.pointee!.pointee.USBDeviceOpen(dev)
            guard orr == KERN_SUCCESS else { throw Failure.open(orr) }
            rr = dev.pointee!.pointee.USBDeviceReEnumerate(dev, 0)
            _ = dev.pointee!.pointee.USBDeviceClose(dev)
        }
        guard rr == KERN_SUCCESS else { throw Failure.reenumerate(rr) }
    }
}
