# ZVZoom

A macOS menubar app that remembers the zoom position of a Sony ZV-1 and restores it
when the camera powers on. It talks to the camera over USB in PC Remote mode through
Apple's ImageCaptureCore framework. Because ImageCaptureCore is the front end for
`ptpcamerad`, the app goes through the daemon instead of fighting it for the USB
interface. No SIP changes, no kill loops, no libgphoto2.

Tested on a ZV-1 running Sony PC Remote protocol 3.00 (current firmware) on macOS 26.

## Camera setup

1. On the ZV-1: MENU > Setup > USB Connection > **PC Remote**.
2. Connect USB to the Mac. HDMI stays connected to your capture device as before.
3. Power the camera on. In PC Remote mode it enumerates as USB `054c:0c44`.

## Build and run

Requires Xcode command line tools (Swift 5.9+, macOS 13+).

```
cd ZVZoom
swift build
.build/debug/ZVZoom            # menubar app
.build/debug/ZVZoom -h         # CLI diagnostics
```

To run it at login, build a bundle and add it as a Login Item:

```
./make-app.sh
open ZVZoom.app
```

Menu items:

- **Save Current Zoom** reads the zoom position and stores it.
- **Restore Saved Zoom** drives the lens to the stored position.
- **Restore Automatically on Connect** (default on) runs a restore every time the camera
  appears, after a 3 second settle and once the camera reports a valid zoom position.
- **Zoom In / Zoom Out (nudge)** sends one short pulse.
- **Open Log** opens `~/Library/Logs/ZVZoom.log`.

## CLI diagnostics

```
ZVZoom [-v] dump            handshake, then print every property the camera reports
ZVZoom [-v] get             print the current zoom state
ZVZoom [-v] pos <n>         drive the zoom to a bar position (0 = full wide)
ZVZoom [-v] set <mag>       drive the zoom to a magnification, e.g. 1.8 (coarser)
ZVZoom [-v] roundtrip       save the current position, zoom away, restore, report the error
ZVZoom [-v] calib [ms ...]  measure positions moved and report lag per pulse length
ZVZoom [-v] op <tele|wide|stop> [ms]
ZVZoom [-v] raw <opcode> [p1 p2 ...]
ZVZoom [-v] watch
```

`run-diag.command` is a double-clickable wrapper: it builds, then runs each line of
`diag-args.txt` as a ZVZoom invocation and saves the output to `diag-dump.txt`.

## How it works

Sony's PC Remote protocol is plain PTP with vendor opcodes. After `ptpcamerad` opens the
session, the app runs the handshake libgphoto2 uses:

```
0x9201 SDIO_Connect(1)
0x9201 SDIO_Connect(2)
0x9202 SDIO_GetExtDeviceInfo(0x12c, 1)   -> protocol version + list of vendor codes
0x9201 SDIO_Connect(3)
0x9205 SetExtDevicePropValue(PriorityMode=1)
```

Then:

- `0x9209 GetAllExtDevicePropInfo` returns a blob of 88 property descriptors in the
  protocol 3.00 format (each enum carries a second "settable now" list). The parser is in
  `PTP.swift`.
- `0x9207 ControlDevice(0xD2DD ZoomOperation)` with a 1-byte INT8 payload moves the lens:
  -1 wide, +1 tele, 0 stop.
- Position feedback comes from `0xD25D ZoomBarInformation`: its low byte is the zoom bar
  position, 0 at full wide, about 100 at full optical tele (2.7x). `0xD25C ZoomScale`
  (magnification x1000) is also read but is quantized to 0.1x, so the bar position is
  what gets saved and restored.

Every PTP exchange goes through `ICCameraDevice.requestSendPTPCommand(_:outData:)`. The
command block is the standard USB PTP container in little-endian; `ptpcamerad` fills in
the transaction id. The two buffers it returns are not in a documented order, so the
response container is identified by its header.

## What the ZV-1 actually does (measured)

- The zoom report updates about 0.9 to 1.1 s after a `ZoomOperation` command, and keeps
  updating until about 1.5 s for long pulses. The camera sends PTP event 0xC203 when it
  updates. Reading sooner returns the old value.
- Any pulse of 40 ms or more moves at least 7 bar positions. Beyond that the travel is
  roughly linear at about 7.5 ms per position, with some jitter.
- Right after the handshake, `ZoomScale` can read 0 for a short time; the app waits for a
  nonzero value.
- `0xD214` (which libgphoto2 maps to an absolute zoom) reads 0xFFFFFFFF and is read-only
  on this firmware. There is no absolute zoom command on the ZV-1.
- If a PC Remote session is left half-open (a crashed client), the next
  `SDIO_Connect(1)` fails with Sony response 0xA101 (AuthenticationFailed). Power-cycle
  the camera or replug USB.

The restore loop (`SonyCamera.moveZoom`) sizes each pulse from that model, waits for the
report to settle, and repeats until within tolerance (default 3 positions, about 0.03x).
Typical restore from power-on: two pulses, 4 to 6 seconds.

Tunables, stored in UserDefaults (`defaults write ZVZoom <key> ...` for the bare binary,
`defaults write local.zvzoom <key> ...` for the .app):

```
tolerance     -int 3       accepted error in bar positions
msPerUnit     -float 7.5   initial travel estimate, refined during each restore
nudgeMs       -int 80      length of a manual nudge pulse
connectDelay  -float 3     seconds to wait after the camera appears
zoomWarmup    -float 2     seconds to wait after power-on before the first restore pulse
```

## Troubleshooting

**No camera appears.** Check Image Capture.app: if the ZV-1 is not listed there either,
the Mac is not seeing it as a PTP device. Confirm USB Connection is PC Remote and the
camera is on. The product id in the log should be `0c44`.

**AuthenticationFailed on connect.** Power the camera off and on, or unplug and replug.

**Zoom lands a few positions off.** Tolerance 3 is about 0.03x. Lower it to 1 if you
want, at the cost of an extra pulse or two per restore.

**Clear Image Zoom / Digital Zoom.** With Zoom Setting on the camera set to optical only
(`ZoomSetting` = 1), the bar runs 0 to about 100 over the optical range. Other settings
extend the bar into the digital range; the app does not care, it restores whatever
position was saved.

## Files

- `Sources/ZVZoom/PTP.swift` – PTP container encode/decode, data types, Sony property
  descriptor parser (protocol 2 and 3), opcode and property constants.
- `Sources/ZVZoom/SonyCamera.swift` – ImageCaptureCore device browser, camera session,
  handshake, property reads, zoom control, settle logic, restore loop.
- `Sources/ZVZoom/ZoomController.swift` – settings, save/restore, auto-restore on connect.
- `Sources/ZVZoom/App.swift` – SwiftUI `MenuBarExtra` UI.
- `Sources/ZVZoom/main.swift` – entry point and the CLI diagnostics.
- `make-app.sh` – wraps the release binary in a `.app` for Login Items.
- `run-diag.command` – double-clickable diagnostic runner.

References: libgphoto2 `camlibs/ptp2/{ptp.h,ptp.c,ptp-pack.c,library.c}` and
`camlibs/ptp2/cameras/sony-zv1.txt`.
