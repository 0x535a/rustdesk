import Foundation
import Testing
@testable import TouchFormat

struct NativeTouchTests {
    let fingers = (1...10).map { NativeTouchContact(id: UInt8($0), x: Double($0) / 10, y: 0.5) }

    @Test func queuedQuickTapPublishesPressAndRetainedLift() throws {
        var input = NativeTouchLifecycle()
        func receive(_ time: TimeInterval) -> Data? { input.nextReport(at: time) }
        try input.enqueue(.init(contacts: [.init(id: 95, x: 0.5, y: 0.5)]))
        try input.enqueue(.init(contacts: []))
        let down = try #require(receive(0))
        #expect(down[1] == 1 && down[2] == 1 && down.last == 1)
        #expect(receive(0.03) == nil)
        let lift = try #require(receive(0.061))
        #expect(lift[1] == 0 && lift[2] == 1 && lift.last == 1)
        #expect(receive(0.09) == nil)
        #expect(receive(0.122) == Data([1] + Array(repeating: UInt8(0), count: 61)))
    }

    @Test func retainedFingerKeepsHIDIdentityWhenAnotherSlotIsReused() throws {
        var input = NativeTouchLifecycle()
        func receive(_ time: TimeInterval) -> Data? { input.nextReport(at: time) }
        let first = NativeTouchContact(id: 31, x: 0.1, y: 0.5)
        let held = NativeTouchContact(id: 99, x: 0.7, y: 0.5)
        try input.enqueue(.init(contacts: [first, held]))
        let down = try #require(receive(0))
        #expect(down[2] == 1 && down[8] == 2)
        try input.enqueue(.init(contacts: [held]))
        let lift = try #require(receive(0.061))
        #expect(lift[1] == 0 && lift[7] == 1 && lift[8] == 2)
        try input.enqueue(.init(contacts: [held, .init(id: 88, x: 0.2, y: 0.5)]))
        #expect(receive(0.09) == nil)
        let replacement = try #require(receive(0.122))
        #expect(replacement[1] == 1 && replacement[2] == 1)
        #expect(replacement[7] == 1 && replacement[8] == 2)
        #expect(replacement[9..<13] == down[9..<13])
    }

    @Test func allTenSlotsCanLiftAndBeReused() throws {
        var input = NativeTouchLifecycle()
        func receive(_ time: TimeInterval) -> Data? { input.nextReport(at: time) }
        try input.enqueue(.init(contacts: fingers))
        #expect(receive(0)?.last == 10)
        try input.enqueue(.init(contacts: []))
        try input.enqueue(.init(contacts: fingers.map { .init(id: $0.id + 10, x: $0.x, y: $0.y) }))
        let lifts = try #require(receive(0.061))
        for index in 0..<10 { #expect(lifts[1 + index * 6] == 0) }
        let next = try #require(receive(0.122))
        for index in 0..<10 {
            #expect(next[1 + index * 6] == 1 && next[2 + index * 6] == UInt8(index + 1))
        }
        #expect(next.last == 10)
    }

    @Test func tenContactsRoundTripAndInvalidFramesFail() throws {
        let frame = NativeTouchFrame(contacts: fingers)
        try frame.validate()
        #expect(try JSONDecoder().decode(NativeTouchFrame.self, from: JSONEncoder().encode(frame)) == frame)
        #expect(throws: NativeTouchError.self) {
            try NativeTouchFrame(contacts: fingers + [.init(id: 11, x: 0, y: 0)]).validate()
        }
        #expect(throws: NativeTouchError.self) {
            try NativeTouchFrame(contacts: [fingers[0], fingers[0]]).validate()
        }
        #expect(throws: NativeTouchError.self) {
            try NativeTouchFrame(contacts: [.init(id: 1, x: .nan, y: 0)]).validate()
        }
    }

    @Test func reportsCarryAllTenContactsAndExplicitLifts() throws {
        let frame = NativeTouchFrame(contacts: fingers)
        let empty = NativeTouchFrame(contacts: [])
        let down = try #require(frame.reports(after: empty).first)
        #expect(down.data.count == 62 && down.data.first == 1 && down.data.last == 10)
        for index in 0..<10 {
            #expect(down.data[1 + index * 6] == 1)
            #expect(down.data[2 + index * 6] == UInt8(index + 1))
        }
        #expect(Array(down.data[57..<61]) == [255, 127, 0, 64])
        let up = try empty.reports(after: frame)
        #expect(up.count == 2 && up[0].data.last == 10)
        for index in 0..<10 { #expect(up[0].data[1 + index * 6] == 0) }
        #expect(up[1].data == Data([1] + Array(repeating: UInt8(0), count: 61)))
    }

    @Test func descriptorAdvertisesTenContactsAndMatchesReportLength() {
        let descriptor = Array(NativeTouchDescriptor.data)
        var offset = 0, reportID = 0, size = 0, count = 0
        var inputBits: [Int: Int] = [:], featureBits: [Int: Int] = [:]
        var contactMaximum: Int?
        while offset < descriptor.count {
            let prefix = descriptor[offset]
            let length = [0, 1, 2, 4][Int(prefix & 3)]
            let value = descriptor[(offset + 1)..<(offset + 1 + length)].enumerated()
                .reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            switch prefix & 0xfc {
            case 0x74: size = value
            case 0x94: count = value
            case 0x84: reportID = value
            case 0x80: inputBits[reportID, default: 0] += size * count
            case 0xb0: featureBits[reportID, default: 0] += size * count
            case 0x24: contactMaximum = value
            default: break
            }
            offset += length + 1
        }
        #expect(inputBits == [1: 488])
        #expect(featureBits == [2: 8])
        #expect(contactMaximum == 10)
    }
}
