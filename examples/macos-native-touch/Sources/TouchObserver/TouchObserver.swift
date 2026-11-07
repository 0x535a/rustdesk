import AppKit
import Darwin
import TouchObserverState

@MainActor
final class DirectTouchCapture: NSGestureRecognizer {
    override func touchesBegan(with event: NSEvent) { (view as? TouchCanvas)?.observe(event) }
    override func touchesMoved(with event: NSEvent) { (view as? TouchCanvas)?.observe(event) }
    override func touchesEnded(with event: NSEvent) { (view as? TouchCanvas)?.observe(event) }
    override func touchesCancelled(with event: NSEvent) { (view as? TouchCanvas)?.observe(event) }
}

@MainActor
final class TouchCanvas: NSView {
    private var observation = TouchObservation()
    private var eventText = "等待原生 direct touch"
    private var eventIsDirect: Bool?
    private var simulationText = "观察模式；鼠标点击不计入触点"
    private static let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemTeal, .systemCyan, .systemBlue, .systemIndigo, .systemPurple, .systemPink]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var peak: Int { observation.maximumCount }
    var active: Int { observation.activeCount }

    func showSimulation(_ text: String) { simulationText = text; needsDisplay = true }
    func cancelContacts() { observation.cancelAll(); needsDisplay = true }

    override func touchesBegan(with event: NSEvent) { observe(event) }
    override func touchesMoved(with event: NSEvent) { observe(event) }
    override func touchesEnded(with event: NSEvent) { observe(event) }
    override func touchesCancelled(with event: NSEvent) {
        if event.touches(matching: .any, in: self).isEmpty { cancelContacts() }
        observe(event)
    }

    func observe(_ event: NSEvent) {
        let touches = event.touches(matching: .any, in: self).filter { $0.type == .direct }
        var updates: [TouchObservation.Update] = []
        for touch in touches {
            guard let identity = touch.identity as? AnyHashable else {
                eventText = "无法读取触点 identity"; eventIsDirect = nil; needsDisplay = true
                return
            }
            let phase: TouchObservation.Phase
            if touch.phase.contains(.ended) { phase = .ended }
            else if touch.phase.contains(.cancelled) { phase = .cancelled }
            else if touch.phase.contains(.began) { phase = .began }
            else if touch.phase.contains(.moved) { phase = .moved }
            else { phase = .stationary }
            updates.append(.init(identity: identity, position: touch.location(in: self), phase: phase, isDirect: true))
        }
        let previousCount = observation.activeCount
        observation.apply(updates)
        if previousCount != observation.activeCount {
            print("native_touch_received type=\(event.type.rawValue) active=\(observation.activeCount) peak=\(observation.maximumCount)")
            fflush(stdout)
        }
        eventIsDirect = !updates.isEmpty || event.type == .directTouch
        eventText = "原生 direct touch：\(eventIsDirect == true ? "是" : "否") · 事件类型 \(event.type.rawValue)"
        needsDisplay = true
    }

    private func mouse(_ event: NSEvent) {
        eventIsDirect = false
        eventText = "原生 direct touch：否 · 鼠标事件 \(event.type.rawValue)（不计数）"
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) { mouse(event) }
    override func mouseUp(with event: NSEvent) { mouse(event) }
    override func mouseDragged(with event: NSEvent) { mouse(event) }
    override func rightMouseDown(with event: NSEvent) { mouse(event) }
    override func otherMouseDown(with event: NSEvent) { mouse(event) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.035, green: 0.055, blue: 0.09, alpha: 1).setFill()
        bounds.fill()
        NSColor.white.withAlphaComponent(0.055).setStroke()
        let grid = NSBezierPath()
        for x in stride(from: CGFloat(0), through: bounds.width, by: 40) {
            grid.move(to: NSPoint(x: x, y: 174)); grid.line(to: NSPoint(x: x, y: bounds.height))
        }
        for y in stride(from: CGFloat(174), through: bounds.height, by: 40) {
            grid.move(to: NSPoint(x: 0, y: y)); grid.line(to: NSPoint(x: bounds.width, y: y))
        }
        grid.lineWidth = 1; grid.stroke()
        text("原生触控 · 十点测试", at: NSPoint(x: 24, y: 20), size: 24, color: .white, bold: true)
        text("当前活跃：\(observation.activeCount) / 10", at: NSPoint(x: 24, y: 62), size: 22, color: .white, bold: true)
        text("累计最大同时：\(observation.maximumCount)", at: NSPoint(x: 310, y: 62), size: 22, color: .white, bold: true)
        let statusColor: NSColor = eventIsDirect == true ? .systemGreen : eventIsDirect == false ? .systemOrange : .lightGray
        text(eventText, at: NSPoint(x: 24, y: 103), size: 16, color: statusColor)
        text(simulationText, at: NSPoint(x: 24, y: 133), size: 15, color: .lightGray)
        if observation.activeCount == 0 {
            text("等待 macOS 实际交付的原生触点", at: NSPoint(x: 24, y: 210), size: 20, color: .lightGray)
            text("圆圈编号和颜色在接触期间保持不变；抬起或取消后消失。",
                 at: NSPoint(x: 24, y: 244), size: 15, color: .lightGray)
        }
        for contact in observation.activeContacts {
            let index = (contact.number - 1) % Self.colors.count
            let circle = NSBezierPath(ovalIn: NSRect(x: contact.position.x - 28, y: contact.position.y - 28, width: 56, height: 56))
            Self.colors[index].withAlphaComponent(0.85).setFill(); circle.fill()
            NSColor.white.setStroke(); circle.lineWidth = 2; circle.stroke()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .bold),
                .foregroundColor: [1, 2, 5].contains(index) ? NSColor.black : NSColor.white,
            ]
            let label = NSAttributedString(string: "\(contact.number)", attributes: attributes)
            let size = label.size()
            label.draw(at: NSPoint(x: contact.position.x - size.width / 2, y: contact.position.y - size.height / 2))
        }
    }

    private func text(_ value: String, at point: NSPoint, size: CGFloat, color: NSColor, bold: Bool = false) {
        (value as NSString).draw(at: point, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: color,
        ])
    }
}

@MainActor
final class ObserverDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var displayID: CGDirectDisplayID = CGMainDisplayID()
    var helperPath: String?
    private var window: NSWindow?
    private var canvas: TouchCanvas?
    private var simulation: Task<Void, Never>?
    private var child: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) else { fputs("Display is not active.\n", stderr); NSApp.terminate(nil); return }
        let area = screen.visibleFrame
        let size = NSSize(width: min(1100, area.width * 0.8), height: min(760, area.height * 0.8))
        let rect = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        let next = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false, screen: screen)
        next.title = "RustDesk · 原生十点触控可视化"
        next.minSize = NSSize(width: 780, height: 500)
        next.delegate = self
        let view = TouchCanvas(frame: NSRect(origin: .zero, size: size))
        view.allowedTouchTypes = [.direct]
        view.wantsRestingTouches = true
        // Screen touches arrive through AppKit's gesture event delivery path.
        let capture = DirectTouchCapture(target: nil, action: nil)
        capture.allowedTouchTypes = [.direct]
        view.addGestureRecognizer(capture)
        next.contentView = view
        next.makeKeyAndOrderFront(nil); next.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        window = next; canvas = view
        let native = Bundle.main.object(forInfoDictionaryKey: "NSIsTouchNative") as? Bool ?? false
        print("observer_ready=true display=\(displayID) window=\(next.windowNumber) NSIsTouchNative=\(native)")
        fflush(stdout)
        if !native { view.showSimulation("测试 App 未声明 NSIsTouchNative；请使用 run-observer.sh 启动") }
        else if let helperPath {
            simulation = Task { @MainActor in await self.simulate(helper: helperPath, screen: screen, window: next, view: view) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowDidResignKey(_ notification: Notification) { canvas?.cancelContacts() }
    func applicationWillTerminate(_ notification: Notification) {
        simulation?.cancel()
        if let child, child.isRunning { child.terminate() }
    }

    private func simulate(helper: String, screen: NSScreen, window: NSWindow, view: TouchCanvas) async {
        let process = Process(), input = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["--run", "--display", "\(displayID)"]
        process.standardInput = input; process.standardError = errors
        let (exits, completion) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { result in completion.yield(result.terminationStatus); completion.finish() }
        child = process
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            child = nil
        }
        do {
            view.showSimulation("模拟器：准备十点序列（不计入接收计数）")
            try await Task.sleep(for: .seconds(1))
            let before = (view.active, view.peak)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else {
                    throw NSError(domain: "TouchObserver", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create mouse-handler test event."])
                }
                if type == .leftMouseDown { view.mouseDown(with: event) }
                else { view.mouseUp(with: event) }
            }
            guard view.active == before.0, view.peak == before.1 else {
                throw NSError(domain: "TouchObserver", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mouse handler changed native contact counts."])
            }
            print("mouse_handler_exclusion_verified=true native_active=\(view.active) native_peak=\(view.peak)")
            fflush(stdout)
            try process.run()
            try await Task.sleep(for: .milliseconds(400))
            for step in 0..<40 {
                try Task.checkCancellation()
                let count = step < 25 ? 10 : step < 35 ? 5 : 0
                var contacts: [[String: Any]] = []
                for index in 0..<count {
                    let phase = Double(step) * 0.15 + Double(index) * 0.3
                    let column = CGFloat(index % 5)
                    let row = CGFloat(index / 5)
                    let x = view.bounds.width * (0.28 + column * 0.11) + CGFloat(sin(phase)) * 18
                    let y: CGFloat = 240 + row * 130 + CGFloat(cos(phase)) * 18
                    let point = NSPoint(x: x, y: y)
                    let local = view.convert(point, to: nil)
                    let global = window.convertToScreen(NSRect(origin: local, size: .zero)).origin
                    let normalizedX = (global.x - screen.frame.minX) / screen.frame.width
                    let normalizedY = (screen.frame.maxY - global.y) / screen.frame.height
                    contacts.append(["id": index + 1, "x": normalizedX, "y": normalizedY])
                }
                view.showSimulation("模拟器发送：\(count) 点 · macOS 原生实收：\(view.active) 点")
                var data = try JSONSerialization.data(withJSONObject: ["contacts": contacts]); data.append(10)
                try input.fileHandleForWriting.write(contentsOf: data)
                try await Task.sleep(for: .milliseconds(200))
            }
            try input.fileHandleForWriting.close()
            for await status in exits {
                let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                view.showSimulation("发送结束 · helper 退出 \(status) · 原生峰值 \(view.peak)，当前 \(view.active)" + (detail.isEmpty ? "" : " · \(detail.prefix(100))"))
                print("simulation_finished=true helper_exit=\(status) native_peak=\(view.peak) native_active=\(view.active)")
                fflush(stdout)
            }
        } catch {
            view.showSimulation("模拟未完成：\(error.localizedDescription) · 原生实收计数保持独立")
            print("simulation_error=\(error)"); fflush(stdout)
        }
    }
}

@main
struct TouchObserver {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let delegate = ObserverDelegate()
        var args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] {
            print("TouchObserver [--display ID] [--simulate /absolute/path/to/helper]\nOnly actual native direct touches are counted.")
            return
        }
        while !args.isEmpty {
            if args.count >= 2, args[0] == "--display", let id = UInt32(args[1]) {
                delegate.displayID = id; args.removeFirst(2)
            } else if args.count >= 2, args[0] == "--simulate" {
                delegate.helperPath = args[1]; args.removeFirst(2)
            } else { fputs("Expected --display ID or --simulate helper-path.\n", stderr); exit(1) }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular); app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
