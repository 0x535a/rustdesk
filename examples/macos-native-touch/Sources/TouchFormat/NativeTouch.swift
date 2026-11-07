import Foundation

public enum NativeTouchError: Error, CustomStringConvertible {
    case invalidFrame
    case queueOverflow

    public var description: String {
        switch self {
        case .invalidFrame: "Expected at most 10 distinct contacts, IDs 1...127, and finite coordinates in [0,1]."
        case .queueOverflow: "Native touch input queue overflow; lift all fingers."
        }
    }
}

// Adapted from Duo's SystemNativeTouchDevice; HID IDs belong to retained slots,
// not to the remote pointer IDs. AppKit must consume a lift before a slot is reused.
public struct NativeTouchLifecycle {
    private struct Slot {
        var contact: NativeTouchContact
        let hidID: UInt8
        var down = true
        var published = false
        var liftedAt: TimeInterval?
    }

    private var slots: [Slot?] = Array(repeating: nil, count: NativeTouchFrame.maximumContacts)
    private var pending: [[NativeTouchContact]] = []
    private var hadReport = false
    private var lastReport: Data?
    private var lastDownIDs = Set<UInt8>()
    public private(set) var nextTransitionTime: TimeInterval = 0

    public init() {}

    public var hasContacts: Bool {
        slots.contains { $0?.down == true } || pending.contains { !$0.isEmpty }
    }

    public mutating func enqueue(_ frame: NativeTouchFrame) throws {
        try frame.validate()
        if let last = pending.last, Set(last.map(\.id)) == Set(frame.contacts.map(\.id)) {
            pending[pending.count - 1] = frame.contacts
        } else {
            pending.append(frame.contacts)
        }
        if pending.count > 64 {
            releaseAll()
            throw NativeTouchError.queueOverflow
        }
    }

    public mutating func releaseAll() {
        pending.removeAll()
        for index in slots.indices {
            guard var slot = slots[index] else { continue }
            if !slot.published { slots[index] = nil; continue }
            if slot.down { slot.down = false; slot.liftedAt = nil; slots[index] = slot }
        }
    }

    public var currentReport: Data {
        NativeTouchReport(samples: slots.compactMap { slot in
            guard let slot else { return nil }
            return .init(contact: .init(id: slot.hidID, x: slot.contact.x, y: slot.contact.y), down: slot.down)
        }).data
    }

    public mutating func nextReport(at now: TimeInterval) -> Data? {
        guard now >= nextTransitionTime else { return nil }
        for index in slots.indices {
            if let slot = slots[index], !slot.down, let lifted = slot.liftedAt, now - lifted >= 0.06 {
                slots[index] = nil
            }
        }
        if let desired = pending.first {
            let new = desired.filter { contact in !slots.contains { $0?.contact.id == contact.id } }
            if new.count <= slots.filter({ $0 == nil }).count {
                pending.removeFirst()
                for index in slots.indices {
                    guard var slot = slots[index] else { continue }
                    if let contact = desired.first(where: { $0.id == slot.contact.id }), slot.down {
                        slot.contact = contact
                    } else if slot.down {
                        slot.down = false; slot.liftedAt = nil
                    }
                    slots[index] = slot
                }
                for contact in new {
                    if let free = slots.firstIndex(where: { $0 == nil }) {
                        slots[free] = Slot(contact: contact, hidID: UInt8(free + 1))
                    }
                }
            }
        }
        let occupied = slots.contains { $0 != nil }
        guard occupied || hadReport else { return nil }
        let data = currentReport
        guard data != lastReport else { return nil }
        let downIDs = Set(slots.compactMap { $0 }.filter(\.down).map { $0.contact.id })
        for index in slots.indices where slots[index]?.down == true { slots[index]?.published = true }
        for index in slots.indices where slots[index]?.down == false && slots[index]?.liftedAt == nil {
            slots[index]?.liftedAt = now
        }
        if downIDs != lastDownIDs { nextTransitionTime = now + 0.06 }
        lastDownIDs = downIDs; lastReport = data; hadReport = occupied
        return data
    }
}

public struct NativeTouchContact: Codable, Equatable, Sendable {
    public let id: UInt8
    public let x: Double
    public let y: Double

    public init(id: UInt8, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

public struct NativeTouchFrame: Codable, Equatable, Sendable {
    public static let maximumContacts = 10
    public let contacts: [NativeTouchContact]

    public init(contacts: [NativeTouchContact]) {
        self.contacts = contacts
    }

    public func validate() throws {
        guard contacts.count <= Self.maximumContacts,
              Set(contacts.map(\.id)).count == contacts.count,
              contacts.allSatisfy({ (1...127).contains($0.id) && $0.x.isFinite && $0.y.isFinite
                  && (0...1).contains($0.x) && (0...1).contains($0.y) }) else {
            throw NativeTouchError.invalidFrame
        }
    }

    public func reports(after previous: NativeTouchFrame) throws -> [NativeTouchReport] {
        try validate()
        try previous.validate()
        let next = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
        var reports: [NativeTouchReport] = []
        if previous.contacts.contains(where: { next[$0.id] == nil }) {
            // Publish explicit lifts before compacting or reusing the ten HID slots.
            reports.append(NativeTouchReport(samples: previous.contacts.map {
                .init(contact: next[$0.id] ?? $0, down: next[$0.id] != nil)
            }))
        }
        reports.append(NativeTouchReport(samples: contacts.map { .init(contact: $0, down: true) }))
        return reports
    }
}

public struct NativeTouchReport: Sendable {
    struct Sample: Sendable {
        let contact: NativeTouchContact
        let down: Bool
    }
    let samples: [Sample]

    public var activeContacts: [NativeTouchContact] {
        samples.filter(\.down).map(\.contact)
    }

    public var data: Data {
        var bytes: [UInt8] = [1]
        // Occupied slots must be contiguous, including contacts being lifted.
        for sample in samples {
            let x = UInt16((sample.contact.x * 32767).rounded())
            let y = UInt16((sample.contact.y * 32767).rounded())
            bytes += [sample.down ? 1 : 0, sample.contact.id,
                      UInt8(x & 255), UInt8(x >> 8), UInt8(y & 255), UInt8(y >> 8)]
        }
        bytes += Array(repeating: 0, count: (NativeTouchFrame.maximumContacts - samples.count) * 6)
        bytes.append(UInt8(samples.count))
        return Data(bytes)
    }
}

public enum NativeTouchDescriptor {
    // Adapted from kesku/duo-workspace; see THIRD_PARTY_NOTICES.
    public static var data: Data {
        let maximum = NativeTouchFrame.maximumContacts
        let finger: [UInt8] = [
            0x05, 0x0D, 0x09, 0x22, 0xA1, 0x02,
            0x09, 0x42, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01, 0x81, 0x02,
            0x75, 0x07, 0x95, 0x01, 0x81, 0x03,
            0x09, 0x51, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02,
            0x05, 0x01, 0x09, 0x30, 0x09, 0x31,
            0x16, 0x00, 0x00, 0x26, 0xFF, 0x7F,
            0x75, 0x10, 0x95, 0x02, 0x81, 0x02, 0xC0,
        ]
        return Data([0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01, 0x85, 0x01]
            + Array(repeating: finger, count: maximum).flatMap { $0 }
            + [0x05, 0x0D, 0x09, 0x54, 0x15, 0x00, 0x25, UInt8(maximum),
               0x75, 0x08, 0x95, 0x01, 0x81, 0x02,
               0x85, 0x02, 0x09, 0x55, 0x75, 0x08, 0x95, 0x01, 0xB1, 0x02, 0xC0])
    }
}
