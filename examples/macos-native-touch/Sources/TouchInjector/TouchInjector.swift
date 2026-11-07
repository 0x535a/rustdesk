import AppKit
import CoreHID
import Darwin
import IOKit.hid
import Security
import TouchFormat

@main
struct TouchInjector {
    static let help = """
    Usage: TouchInjector --check | --list-displays | --encode
           TouchInjector --probe --display ID
           TouchInjector --run --display ID

    --check          Read permissions and OS version; creates no device.
    --list-displays  List active display IDs and pixel sizes.
    --encode         Encode stdin JSON snapshots to hex HID reports without injection.
    --probe          Create and remove a ten-point HID device; sends no input reports.
    --run            Inject stdin snapshots; empty contacts, EOF, SIGINT or SIGTERM release all contacts.

    Stdin format: one full snapshot per line, e.g. {"contacts":[{"id":1,"x":0.5,"y":0.5}]}
    Up to ten distinct IDs (1...127); x/y are normalized to the selected display.
    """

    @MainActor
    static func main() async {
        let device = TouchDevice()
        do {
            try await execute(device)
        } catch {
            FileHandle.standardError.write(Data("TouchInjector: \(error)\n".utf8))
            do { try await device.stop() }
            catch { FileHandle.standardError.write(Data("TouchInjector cleanup: \(error)\n".utf8)) }
            exit(1)
        }
    }

    @MainActor
    static func execute(_ device: TouchDevice) async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args == ["--help"] {
            print(help)
            return
        }
        if args == ["--check"] {
            let task = SecTaskCreateFromSelf(nil)
            let entitlement = task.flatMap {
                SecTaskCopyValueForEntitlement($0, "com.apple.developer.hid.virtual.device" as CFString, nil)
            } as? Bool ?? false
            print("os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
            print("maximum_contacts=\(NativeTouchFrame.maximumContacts)")
            print("virtual_hid_entitlement=\(entitlement)")
            print("accessibility=\(AXIsProcessTrusted())")
            print("hid_post_event_access=\(IOHIDCheckAccess(kIOHIDRequestTypePostEvent).rawValue)")
            print("native_touch_consumption=unverified")
            return
        }
        if args == ["--list-displays"] {
            var count: UInt32 = 0
            guard CGGetActiveDisplayList(0, nil, &count) == .success else {
                throw InjectorError("Cannot count active displays.")
            }
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
            guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
                throw InjectorError("Cannot list active displays.")
            }
            for display in displays.prefix(Int(count)) {
                print("\(display) \(CGDisplayPixelsWide(display))x\(CGDisplayPixelsHigh(display)) main=\(display == CGMainDisplayID())")
            }
            return
        }
        let encodeOnly = args == ["--encode"]
        if !encodeOnly {
            guard args.count == 3, ["--probe", "--run"].contains(args[0]), args[1] == "--display",
                  let display = CGDirectDisplayID(args[2]) else { throw InjectorError(help) }
            try await device.start(displayID: display)
            if args[0] == "--probe" {
                // A probe must not dispatch even an empty input report.
                print("device_created=true; maximum_contacts=10; native_touch_consumption=unverified")
                return
            }
        }

        var signals: [DispatchSourceSignal] = []
        if !encodeOnly {
            for number in [SIGINT, SIGTERM] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler {
                    Task { @MainActor in
                        do { try await device.stop(); exit(0) }
                        catch {
                            FileHandle.standardError.write(Data("TouchInjector cleanup: \(error)\n".utf8))
                            exit(1)
                        }
                    }
                }
                source.resume()
                signals.append(source)
            }
        }
        defer { for source in signals { source.cancel() } }
        var previous = NativeTouchFrame(contacts: [])
        for try await line in FileHandle.standardInput.bytes.lines {
            guard line.utf8.count <= 4096 else { throw InjectorError("Input snapshot exceeds 4096 bytes.") }
            let frame = try JSONDecoder().decode(NativeTouchFrame.self, from: Data(line.utf8))
            if encodeOnly {
                for report in try frame.reports(after: previous) {
                    print(report.data.map { String(format: "%02x", $0) }.joined())
                }
                previous = frame
            } else {
                try await device.send(frame)
            }
        }
        if !encodeOnly { try await device.stop() }
    }
}
