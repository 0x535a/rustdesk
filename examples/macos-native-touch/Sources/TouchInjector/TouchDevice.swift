import AppKit
import CoreHID
import IOKit.hid
import TouchFormat

struct InjectorError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

actor TouchDeviceDelegate: HIDVirtualDeviceDelegate {
    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedSetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, data: Data) async throws {
        throw InjectorError("SetReport is unsupported.")
    }

    func hidVirtualDevice(_ device: HIDVirtualDevice, receivedGetReportRequestOfType type: HIDReportType,
                          id: HIDReportID?, maxSize: Int) async throws -> Data {
        guard type == .feature, id?.rawValue == 2, maxSize >= 1 else {
            throw InjectorError("Only the Contact Count Maximum feature report is supported.")
        }
        let maximum = UInt8(NativeTouchFrame.maximumContacts)
        return maxSize == 1 ? Data([maximum]) : Data([2, maximum])
    }
}

@MainActor
final class TouchDevice {
    private var device: HIDVirtualDevice?
    private let delegate = TouchDeviceDelegate()
    private var frame = NativeTouchFrame(contacts: [])
    var hasContacts: Bool { !frame.contacts.isEmpty }

    func start(displayID: CGDirectDisplayID) async throws {
        guard CGDisplayIsOnline(displayID) != 0,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            throw InjectorError("Display \(displayID) is offline or has no UUID.")
        }
        let displayUUID = CFUUIDCreateString(nil, uuid) as String
        guard let next = HIDVirtualDevice(properties: .init(
            descriptor: NativeTouchDescriptor.data, vendorID: 0x1209, productID: 0xD006,
            transport: .virtual, product: "RustDesk experimental ten-point touchscreen",
            manufacturer: "RustDesk", uniqueID: UUID().uuidString,
            extraProperties: [kIOHIDDisplayIntegratedKey: NSNumber(value: true),
                              "displayUUID": displayUUID as NSString])) else {
            throw InjectorError("HIDVirtualDevice initialization returned nil; CoreHID supplies no error code. Check entitlement, signature and system logs.")
        }
        device = next
        await next.activate(delegate: delegate)
    }

    func send(_ next: NativeTouchFrame) async throws {
        let reports = try next.reports(after: frame)
        for report in reports {
            guard AXIsProcessTrusted(), IOHIDCheckAccess(kIOHIDRequestTypePostEvent).rawValue == 0 else {
                throw InjectorError("Input permission is unavailable; Accessibility and HID post-event access are required.")
            }
            guard let device else { throw InjectorError("Touch device has stopped.") }
            let previousIDs = Set(frame.contacts.map(\.id))
            try await device.dispatchInputReport(data: report.data, timestamp: .now)
            frame = NativeTouchFrame(contacts: report.activeContacts)
            if previousIDs != Set(frame.contacts.map(\.id)) {
                // Duo reports that AppKit needs time to consume contact transitions.
                try await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    func stop() async throws {
        guard let previous = device else { return }
        device = nil
        let reports = try NativeTouchFrame(contacts: []).reports(after: frame)
        frame = NativeTouchFrame(contacts: [])
        for report in reports {
            try await previous.dispatchInputReport(data: report.data, timestamp: .now)
            try await Task.sleep(for: .milliseconds(70))
        }
    }
}
