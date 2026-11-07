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
    private var lifecycle = NativeTouchLifecycle()
    private var task: Task<Void, Never>?
    private var failure: Error?
    var hasContacts: Bool { lifecycle.hasContacts }

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
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.tick()
                    try await Task.sleep(for: .milliseconds(16))
                } catch is CancellationError { return }
                catch {
                    self.lifecycle.releaseAll()
                    self.failure = error
                    return
                }
            }
        }
    }

    func send(_ next: NativeTouchFrame) async throws {
        if let failure { throw failure }
        guard device != nil else { throw InjectorError("Touch device has stopped.") }
        try lifecycle.enqueue(next)
    }

    private func tick() async throws {
        guard let device else { return }
        guard AXIsProcessTrusted(), IOHIDCheckAccess(kIOHIDRequestTypePostEvent).rawValue == 0 else {
            throw InjectorError("Input permission is unavailable; Accessibility and HID post-event access are required.")
        }
        if let report = lifecycle.nextReport(at: ProcessInfo.processInfo.systemUptime) {
            try await device.dispatchInputReport(data: report, timestamp: .now)
        }
    }

    func waitForLift() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while failure == nil && lifecycle.hasContacts && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if let failure { throw failure }
    }

    func stop() async throws {
        guard let previous = device else { return }
        device = nil
        task?.cancel(); await task?.value; task = nil
        defer { lifecycle = NativeTouchLifecycle() }
        let remaining = lifecycle.nextTransitionTime - ProcessInfo.processInfo.systemUptime
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
        lifecycle.releaseAll()
        try await previous.dispatchInputReport(data: lifecycle.currentReport, timestamp: .now)
        try await Task.sleep(for: .milliseconds(70))
        lifecycle = NativeTouchLifecycle()
        try await previous.dispatchInputReport(data: lifecycle.currentReport, timestamp: .now)
    }
}
