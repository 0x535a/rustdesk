import CoreGraphics
import Testing
import TouchObserverState

struct TouchObservationTests {
    @Test func tenContactsKeepTheirNumbersWhileMoving() throws {
        var state = TouchObservation()
        state.apply((1...10).map { .init(identity: $0, position: .zero, phase: .began, isDirect: true) })
        let numbers = state.activeContacts.map(\.number)
        state.apply((1...10).map { .init(identity: $0, position: CGPoint(x: 20, y: 30), phase: .moved, isDirect: true) })
        #expect(state.activeCount == 10 && state.maximumCount == 10)
        #expect(state.activeContacts.map(\.number) == numbers)
        #expect(state.activeContacts.allSatisfy { $0.position == CGPoint(x: 20, y: 30) })
    }

    @Test func liftsAndCancellationRemoveCirclesWithoutInflatingPeak() {
        var state = TouchObservation()
        state.apply([.init(identity: 1, position: .zero, phase: .began, isDirect: true)])
        state.apply([.init(identity: 2, position: .zero, phase: .began, isDirect: true),
                     .init(identity: 1, position: .zero, phase: .ended, isDirect: true)])
        #expect(state.activeCount == 1 && state.maximumCount == 1)
        state.apply([.init(identity: 2, position: .zero, phase: .cancelled, isDirect: true)])
        #expect(state.activeCount == 0 && state.maximumCount == 1)
        state.apply([.init(identity: 3, position: .zero, phase: .began, isDirect: true)])
        state.cancelAll()
        #expect(state.activeContacts.isEmpty && state.maximumCount == 1)
    }

    @Test func nonDirectInputNeverCreatesContacts() {
        var state = TouchObservation()
        state.apply([.init(identity: "mouse", position: CGPoint(x: 100, y: 100), phase: .began, isDirect: false),
                     .init(identity: "trackpad", position: .zero, phase: .moved, isDirect: false)])
        #expect(state.activeCount == 0 && state.maximumCount == 0 && state.activeContacts.isEmpty)
    }
}
