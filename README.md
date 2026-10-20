# ZVZoom

A macOS menubar app that remembers the zoom position of a Sony ZV-1 and restores it
when the camera powers on. It talks to the camera over USB in PC Remote mode, through
Apple's ImageCaptureCore framework. Because ImageCaptureCore is the front end for
`ptpcamerad`, the app goes through the daemon instead of fighting it for the USB
interface. No SIP changes, no kill loops, no libgphoto2.

Status: untested on real hardware. The protocol details come from libgphoto2's Sony
driver and a device dump from a real ZV-1, so the opcodes and property codes are right.
What has not been verified is how `ptpcamerad` handles Sony's vendor commands with a
data phase. The diagnostic subcommands exist so that is the first thing you find out.

## Camera setup

1. On the ZV-1: MENU > Setup > USB Connection > **PC Remote**.
2. Connect USB to the Mac. HDMI stays connected to your capture device as before.
3. Power the camera on. In PC Remote mode it enumerates as USB `054c:0c44`.

## Build

Requires Xcode command line tools (Swift 5.9+, macOS 13+).

```
cd ZVZoom
swift build
```

The binary is `.build/debug/ZVZoom`. Run it with no arguments for the menubar app, or with a
subcommand for diagnostics.

## First run: diagnostics, in this order

Each step uses the previous one's result. Stop at the first one that fails and send me the
output plus `~/Library/Logs/ZVZoom.log`.

```
# 1. Does ptpcamerad surface the camera, and does the Sony handshake complete?
#    Only data-in commands are used here.
.build/debug/ZVZoom -v dump
```

Look for `ZoomScale` (0xd25c), `ZoomEnableStatus` (0xd25b) and `ZoomOperation` (0xd2dd) in
the property list. On the ZV-1 dump in libgphoto2, ZoomScale is `1000` at full wide (1.0x);
the lens goes to about `2900` at full optical tele.

```
# 2. Does a control command with a data phase work? Press tele for 300 ms.
.build/debug/ZVZoom -v op tele 300
.build/debug/ZVZoom -v op wide 300
```

The `after` line should show a different ZoomScale and the lens should move. If the
command stalls for a long time or returns an error, ImageCaptureCore is not passing
Sony's data phase through cleanly; see Troubleshooting.

```
# 3. Closed-loop move to a magnification.
.build/debug/ZVZoom -v set 1.8
```

Watch the printed `now` lines to see how precisely it lands. Two settings tune this,
both stored in UserDefaults:

```
defaults write local.zvzoom pulseMs -int 80        # length of a fine-tuning pulse
defaults write local.zvzoom tolerance -int 50      # accepted ZoomScale error
defaults write local.zvzoom connectDelay -float 3  # wait after the camera appears
```

(When run as a bare binary rather than the .app, the defaults domain is the executable
name: use `defaults write ZVZoom ...` instead.)

```
# 4. Optional experiment: absolute zoom write.
.build/debug/ZVZoom -v abs 23462912
```

libgphoto2 maps property 0xD214 to an absolute "zoom" value (the ZV-1 dump shows
23462912 at wide). Whether the ZV-1 accepts a write to it is unknown. If it does, the
restore could be one command instead of a feedback loop; tell me and I will switch the
app over.

## The menubar app

```
.build/debug/ZVZoom
```

Menu items:

- **Save Current Zoom** reads ZoomScale and stores it.
- **Restore Saved Zoom** drives the lens to the stored value.
- **Restore Automatically on Connect** (default on) runs a restore every time the camera
  appears, after a 3 second settle and once the camera reports zoom as enabled.
- **Zoom In / Zoom Out (nudge)** sends one pulse.
- **Open Log** opens `~/Library/Logs/ZVZoom.log`.

To run it at login, build a bundle and add it as a Login Item:

```
./make-app.sh
open ZVZoom.app
```

## How it works

Sony's PC Remote protocol is plain PTP with vendor opcodes. After `ptpcamerad` opens the
session, the app runs the same handshake libgphoto2 uses:

```
0x9201 SDIO_Connect(1)
0x9201 SDIO_Connect(2)
0x9202 SDIO_GetExtDeviceInfo(0x12c, 1)   -> protocol version + list of vendor codes
0x9201 SDIO_Connect(3)
```

Then:

- `0x9209 GetAllExtDevicePropInfo` returns a blob with every property descriptor. The app
  parses it (PTP.swift, `SonyDPDParser`) and reads ZoomScale (0xD25C, magnification x1000),
  ZoomEnableStatus (0xD25B), ZoomBarInformation (0xD25D) and ZoomSetting (0xD25F).
- `0x9207 ControlDevice(0xD2DD)` with a 1-byte INT8 data phase moves the lens: -1 wide,
  +1 tele, 0 stop. The lens keeps moving until it gets the 0.

Restore is a feedback loop (`SonyCamera.moveZoom`): drive continuously while far from the
target, then short pulses, reading ZoomScale between steps, until within tolerance.

Every PTP exchange is sent with `ICCameraDevice.requestSendPTPCommand(_:outData:)`. The
command block is the standard USB PTP container (length, type 1, opcode, transaction id,
params) in little-endian; `ptpcamerad` fills in the transaction id.

## Troubleshooting

**No camera appears.** Check Image Capture.app: if the ZV-1 is not listed there either,
the Mac is not seeing it as a PTP device. Confirm USB Connection is PC Remote (not Mass
Storage or MTP) and the camera is on. The product id in the log should be `0c44`.

**Handshake fails or the camera stalls.** The Sony handshake must run before any
`0x9205`/`0x9207` command; the app does this. If `dump` works but `op` stalls, the
issue is the data phase. Things to try, in order: a longer `connectDelay`; power-cycle the
camera between runs (a half-finished Sony transaction leaves the camera mute until
replug); and tell me the exact response code from the log. There is an Apple developer
forum report of exactly this stall with a Sony body, so this is the known risk of the
ImageCaptureCore route. The fallback is Option 1 from our chat: a `gphoto2 --shell`
session opened under a `killall ptpcamerad` loop, which the app could drive instead.

**Zoom overshoots or hunts.** Lower `pulseMs` (try 50) and keep `tolerance` at 50 or
100. The ZV-1 reports ZoomScale in steps of 100 at the wide end, so a tolerance below 50
is not meaningful.

**Clear Image Zoom / Digital Zoom.** ZoomScale counts the whole range, so a saved value of
4000 restores into the digital range if ZoomSetting allows it. If you want optical only,
set Zoom Setting to Optical zoom only on the camera and the app cannot exceed 2.9x.

## Files

- `Sources/ZVZoom/PTP.swift` – PTP container encode/decode, data types, Sony property
  descriptor parser, opcode and property constants.
- `Sources/ZVZoom/SonyCamera.swift` – ImageCaptureCore device browser, camera session,
  handshake, property reads, zoom control, feedback loop.
- `Sources/ZVZoom/ZoomController.swift` – settings, save/restore, auto-restore on connect.
- `Sources/ZVZoom/App.swift` – SwiftUI `MenuBarExtra` UI.
- `Sources/ZVZoom/main.swift` – entry point and the CLI diagnostics.
- `make-app.sh` – wraps the release binary in a `.app` for Login Items.

References: libgphoto2 `camlibs/ptp2/{ptp.h,ptp.c,ptp-pack.c,library.c}` and
`camlibs/ptp2/cameras/sony-zv1.txt`.
