import CoreGraphics

public struct TouchObservation {
    public enum Phase { case began, moved, stationary, ended, cancelled }

    public struct Update {
        public let identity: AnyHashable
        public let position: CGPoint
        public let phase: Phase
        public let isDirect: Bool

        public init(identity: AnyHashable, position: CGPoint, phase: Phase, isDirect: Bool) {
            self.identity = identity
            self.position = position
            self.phase = phase
            self.isDirect = isDirect
        }
    }

    public struct Contact {
        public let number: Int
        public let position: CGPoint
    }

    private var contacts: [AnyHashable: Contact] = [:]
    private var nextNumber = 1
    public private(set) var maximumCount = 0
    public var activeCount: Int { contacts.count }
    public var activeContacts: [Contact] { contacts.values.sorted { $0.number < $1.number } }

    public init() {}

    public mutating func apply(_ updates: [Update]) {
        // Remove ended contacts first so a replacement in one event cannot inflate the peak.
        for update in updates where update.isDirect && [.ended, .cancelled].contains(update.phase) {
            contacts.removeValue(forKey: update.identity)
        }
        for update in updates where update.isDirect && ![.ended, .cancelled].contains(update.phase) {
            let number: Int
            if let existing = contacts[update.identity] { number = existing.number }
            else { number = nextNumber; nextNumber += 1 }
            contacts[update.identity] = Contact(number: number, position: update.position)
        }
        maximumCount = max(maximumCount, activeCount)
    }

    public mutating func cancelAll() { contacts.removeAll() }
}
