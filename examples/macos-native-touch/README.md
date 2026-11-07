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
the system log reports `IOServiceOpen:0xe00002c2` (`kIOReturnBadArgument`). The
entitled copy passes on-disk signature verification but is killed at launch;
amfid reports `-424`, "The file is adhoc signed but contains restricted
entitlements". No AMFI bypass has been applied, so native consumption and OS
compatibility remain unverified.

## Current limits

- No RustDesk protocol, Flutter UI, iPad client or authenticated IPC integration.
- Local stdin only; there is no network listener or stalled-sender watchdog.
- Display changes during input and abrupt process termination still require
  device-level verification. Stop the tool before changing displays.
- Report-layout tests and device creation do not establish that native touch
  consumption or ten simultaneous touches work on the current OS.
