import Foundation

public enum NativeTouchError: Error, CustomStringConvertible {
    case invalidFrame

    public var description: String {
        "Expected at most 10 distinct contacts, IDs 1...127, and finite coordinates in [0,1]."
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
