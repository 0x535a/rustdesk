# Experimental macOS ten-point touch injector

Standalone PoC for the iPad → macOS native touch path. It accepts full snapshots
of up to ten contacts and sends touchscreen HID reports through CoreHID. It does
not recognize gestures or synthesize mouse input. RustDesk does not invoke this
tool yet; its existing input paths are unchanged.

The HID descriptor and undocumented display binding come from Duo Workspace at
`d89f7937070a87c9efcaa73282af2e426f4a546f`; see `THIRD_PARTY_NOTICES`.

## Build and inspect

Requires macOS 15+ APIs and Swift 6. A successful build does not establish native
touch support: Duo enables the feature on macOS 27.3+, while this standalone
tool allows probing the current OS, including 27.2.

```sh
cd examples/macos-native-touch
swift test
swift build -c release
.build/release/TouchInjector --check
.build/release/TouchInjector --list-displays
```

The build has no external dependencies and does not create signing identities,
modify Keychain, install a service, or alter AMFI/SIP. The supplied entitlement
plist is not automatically applied or granted by building the package.

## Raw input

`--encode` validates stdin and prints hex input reports without creating a HID
device. Each JSON line is the full active-contact snapshot, not a gesture:

```sh
.build/release/TouchInjector --encode <<'EOF'
{"contacts":[{"id":1,"x":0.25,"y":0.5},{"id":2,"x":0.75,"y":0.5}]}
{"contacts":[{"id":1,"x":0.2,"y":0.5},{"id":2,"x":0.8,"y":0.5}]}
{"contacts":[]}
EOF
```

IDs must remain stable during a contact, in `1...127`; coordinates must be finite
and normalized to `[0,1]` on the selected display. Eleven contacts, duplicate IDs
and invalid coordinates fail. Empty snapshots lift all fingers. The HID input
report is 62 bytes, including its report ID. Feature report 2 advertises ten
contacts. Lifts are explicitly published before removing or replacing slots.

## Device probe and injection

Choose an active display ID from `--list-displays`:

```sh
.build/release/TouchInjector --probe --display DISPLAY_ID
.build/release/TouchInjector --run --display DISPLAY_ID < frames.jsonl
```

`--probe` creates and removes the device without sending any input reports.
Device creation alone does not prove macOS consumes native touches. `--run`
requires Accessibility and HID post-event access; it processes stdin in order,
preserves contact transitions, and releases contacts on empty snapshots, EOF,
input errors, SIGINT or SIGTERM. The device is destroyed on exit. Like Duo, it
waits 60ms after contact-set changes for AppKit to consume the transition.

Creating the device requires `com.apple.developer.hid.virtual.device` permission.
Declaring that entitlement in an ad-hoc signature does not grant it. This tool
does not change security policies or run an entitlement bypass. Any proposed
AMFI experiment requires its own reviewed commands and rollback plan.

An isolated ad-hoc signing experiment can use a copy of the binary:

```sh
mkdir -p .build/signed
cp .build/release/TouchInjector .build/signed/TouchInjector
codesign --force --sign - --entitlements TouchInjector.entitlements .build/signed/TouchInjector
codesign --verify --strict --verbose=2 .build/signed/TouchInjector
codesign --display --entitlements - .build/signed/TouchInjector
.build/signed/TouchInjector --check
```

On the tested macOS 27.2 / 26B123 host, debug tests, release build and the ten-point
`--encode` smoke check pass. An unentitled `--probe` returns nil from CoreHID;
the system log reports `IOServiceOpen:0xe00002c2` (`kIOReturnBadArgument`). An
entitled ad-hoc copy is initially killed at launch with amfid error `-424`.

An explicitly authorized, temporary CDHash allowlist allowed the helper to start
and create the touchscreen. A public IOHIDManager observer confirmed contact
count 10, contact IDs 1...10, and ten tip switches going down and up. The service
is recognized as Digitizers / Touch Screen with a 62-byte input report and the
requested display UUID. The security preference was removed after each trial;
global AMFI disabling was not used.

Native AppKit delivery is now verified on macOS 27.2: the existing injector and
the full Duo reference sender both delivered ten direct touches (event type 37)
to the observer, moving and releasing from 10 to 5 to 0 active contacts, with a
peak of 10. No extra HID properties or system feature switches were needed.

Earlier zero-count results came from an incomplete receiver: ordinary NSView
touch callbacks and NSApplication event observation missed this screen-touch
delivery path. The observer now attaches a direct-touch NSGestureRecognizer to
receive the raw events; it does not classify or synthesize gestures. Launch the
observer as an app through Launch Services, rather than executing its binary
directly. WindowServer logs independently confirm digitizer attachment, display
UUID binding, contact tracking and delivery to the test app. Duo's 27.3 version
check is its application policy, not evidence of a system minimum.

## Visual native-touch observer

```sh
./run-observer.sh --display DISPLAY_ID
./run-observer.sh --display DISPLAY_ID --simulate /absolute/path/to/authorized/helper
```

The script builds an ad-hoc signed test app with `NSIsTouchNative=true`, matching
Duo's application configuration, and launches it with `open`. It uses the selected Xcode SDK directly. The
observer needs no virtual HID entitlement and does not alter AMFI or input
permissions. Close its window to exit; it does not auto-close after a test.

Only actual AppKit `NSTouch.type == .direct` contacts create colored, numbered
circles. Numbers/colors remain stable while held, positions follow movement,
and ended/cancelled contacts disappear. Active and cumulative maximum counts
are displayed separately. Mouse handlers and indirect input do not add contacts.

`--simulate` launches the supplied existing helper with `--run --display ID`,
sends ten moving contacts, lifts five, then clears all contacts. The helper must
already have permission to run, including Accessibility access in the launching
app's context. If that context lacks permission, drive the injector separately
from an authorized terminal while the observer app runs. The sending stage is displayed separately and
does not populate received-contact circles or counters. A local mouse-handler
check verifies counts are unchanged without posting mouse events to the OS.
The observer remains open with the final native peak/active counts, including
zero when native input has not arrived. No iPad participation is required for
this automated test. No changes to the injector or RustDesk session are made.

## Current limits

- No RustDesk protocol, Flutter UI, iPad client or authenticated IPC integration.
- Local stdin only; there is no network listener or stalled-sender watchdog.
- Display changes during input and abrupt process termination still require
  device-level verification. Stop the tool before changing displays.
- Standalone ten-point native delivery is verified on the tested 27.2 build;
  RustDesk/iPad session integration and other builds remain unverified.
