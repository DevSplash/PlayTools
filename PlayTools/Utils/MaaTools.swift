//
//  MaaTools.swift
//  PlayTools
//
//  Created by hguandl on 21/3/2023.
//

import Accelerate
import Network
import OSLog

private let MAA_TOOLS_VERSION = 5
private let TOUCH_SYNC_TIMEOUT: TimeInterval = 3
// One shared allowance for delivery/scheduling overhead, not one allowance per event.
private let TOUCH_SEQUENCE_DELIVERY_SLACK: TimeInterval = 3
// TSEQ event: u32 delay-after-previous-event (microseconds), u8 phase, u16 x, u16 y; all big-endian.
private let TOUCH_SEQUENCE_HEADER_LENGTH = 6
private let TOUCH_SEQUENCE_EVENT_LENGTH = 9
private let MAX_TOUCH_SEQUENCE_EVENTS = 1024
private let MAX_TOUCH_SEQUENCE_EVENT_DELAY_US: UInt32 = 30_000_000
private let MAX_TOUCH_SEQUENCE_DURATION_US: UInt64 = 120_000_000
private let MIN_MAA_TOOLS_PAYLOAD_LENGTH = 4
private let MAX_MAA_TOOLS_PAYLOAD_LENGTH = TOUCH_SEQUENCE_HEADER_LENGTH
    + MAX_TOUCH_SEQUENCE_EVENTS * TOUCH_SEQUENCE_EVENT_LENGTH
// Bounds queued payload bytes to roughly 2.25 MiB in the worst case, excluding Data overhead.
private let MAX_BUFFERED_MAA_TOOLS_MESSAGES = 256

@MainActor final class MaaTools {
    public static let shared = MaaTools()

    private let logger = Logger(subsystem: "PlayTools", category: "MaaTools")
    private let queue = DispatchQueue(label: "MaaTools", qos: .default)
    private var listener: NWListener?

    private var windowTitle: String?

    private var scale = 1.0
    private var width = 0
    private var height = 0
    private var lastWindowMetrics: String?
    private var lastScrnResampleWarning: String?

    // ['M', 'A', 'A', 0x00]
    private let connectionMagic = Data([0x4d, 0x41, 0x41, 0x00])
    // ['S', 'C', 'R', 'N']
    private let screencapMagic = Data([0x53, 0x43, 0x52, 0x4e])
    // ['S', 'I', 'Z', 'E']
    private let sizeMagic = Data([0x53, 0x49, 0x5a, 0x45])
    // ['T', 'E', 'R', 'M']
    private let terminateMagic = Data([0x54, 0x45, 0x52, 0x4d])
    // ['T', 'U', 'C', 'H']
    private let toucherMagic = Data([0x54, 0x55, 0x43, 0x48])
    // ['T', 'S', 'Y', 'N']
    private let toucherSyncMagic = Data([0x54, 0x53, 0x59, 0x4e])
    // ['T', 'S', 'E', 'Q']
    private let touchSequenceMagic = Data([0x54, 0x53, 0x45, 0x51])
    // ['V', 'E', 'R', 'N']
    private let versionMagic = Data([0x56, 0x45, 0x52, 0x4e])
    // ['B', 'N', 'D', 'L']
    private let bundleMagic = Data([0x42, 0x4e, 0x44, 0x4c])
    // ['R', 'E', 'C', 'T']
    private let rectMagic = Data([0x52, 0x45, 0x43, 0x54])
    // ['B', 'G', 'R', 0x01]
    private let bgrMagic = Data([0x42, 0x47, 0x52, 0x01])
    // ['N', 'A', 'T', 'V']
    private let nativeScreencapMagic = Data([0x4e, 0x41, 0x54, 0x56])

    func initialize() {
        guard PlaySettings.shared.maaTools else { return }

        Task {
            // Wait for window
            while width == 0 || height == 0 || windowTitle == nil {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                setupWindow()
            }

            startServer()
        }
    }

    private func setupWindow() {
        let window = UIApplication.shared.connectedScenes
            .flatMap { ($0 as? UIWindowScene)?.windows ?? [] }
            .first { $0.isKeyWindow }

        if let screen = window?.windowScene?.screen {
            scale = screen.nativeScale
            width = Int(screen.nativeBounds.width.rounded())
            height = Int(screen.nativeBounds.height.rounded())
            logWindowMetrics(for: screen)
        }

        if windowTitle == nil {
            windowTitle = AKInterface.shared?.windowTitle
        }
    }

    private func logWindowMetrics(for screen: UIScreen) {
        let bounds = format(screen.bounds)
        let nativeBounds = format(screen.nativeBounds)
        let frame = format(AKInterface.shared?.windowFrame ?? CGRect())
        let content = format(AKInterface.shared?.windowContentRect ?? CGRect())
        let metrics = "\(bounds)|\(nativeBounds)|\(screen.nativeScale)|\(frame)|\(content)"
        guard lastWindowMetrics != metrics else { return }

        lastWindowMetrics = metrics
        let backing = PlayScreen.shared.nsWindow?
            .value(forKey: "backingScaleFactor") as? NSNumber
        logger.debug("UIScreen.bounds \(bounds, privacy: .public)")
        logger.debug("UIScreen.nativeBounds \(nativeBounds, privacy: .public)")
        logger.debug("UIScreen.nativeScale \(screen.nativeScale, privacy: .public)")
        logger.debug("NSWindow frame \(frame, privacy: .public), contentRect \(content, privacy: .public)")
        logger.debug("NSWindow.backingScaleFactor \(backing?.doubleValue ?? 0, privacy: .public)")
        logger.debug("macOSNativeScaling \(PlaySettings.shared.macOSNativeScaling)")
    }

    private func startServer() {
        let port = NWEndpoint.Port(rawValue: UInt16(PlaySettings.shared.maaToolsPort & 0xffff)) ?? .any
        let tcpOptions = NWProtocolTCP.Options()
        // Release per-connection touch state when a peer disappears without closing its socket.
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 10
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        listener = try? NWListener(using: parameters, on: port)

        listener?.newConnectionHandler = { [weak self] newConnection in
            guard let strongSelf = self else { return }
            newConnection.start(queue: strongSelf.queue)

            Task {
                await strongSelf.handleConnection(newConnection)
            }
        }

        listener?.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .ready:
                DispatchQueue.main.async { [weak self] in
                    if let port = self?.listener?.port?.rawValue {
                        self?.logger.log("Server started and listening on port \(port, privacy: .public)")
                        AKInterface.shared?.windowTitle = "\(self?.windowTitle ?? "") [localhost:\(port)]"
                    }
                }
            case .cancelled:
                self?.logger.log("Server closed")
            case let .failed(error):
                self?.logger.error("Server failed to start: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: queue)
    }

    // swiftlint:disable cyclomatic_complexity

    private func handleConnection(_ connection: NWConnection) async {
        let touchState = MaaToolsTouchState()
        defer {
            resetTouch(in: touchState)
            connection.cancel()
        }

        do {
            let (handshake, _, _) = try await connection.receive(
                minimumIncompleteLength: 4,
                maximumLength: 4
            )
            guard handshake == connectionMagic else {
                throw MaaToolsError.invalidMessage
            }

            try await connection.send(content: "OKAY".data(using: .ascii))
            try await handleMessages(on: connection, touchState: touchState)
        } catch MaaToolsError.connectionClosed {
            logger.debug("Client disconnected")
        } catch {
            logger.error("Receive failed: \(error)")
        }
    }

    private func handleMessages(on connection: NWConnection, touchState: MaaToolsTouchState) async throws {
        for try await payload in readPayload(from: connection, touchState: touchState) {
            guard !touchState.connectionClosed else { throw MaaToolsError.connectionClosed }
            switch payload.prefix(4) {
            case screencapMagic:
                try await screencap(to: connection)
            case sizeMagic:
                try await screensize(to: connection)
            case terminateMagic:
                AKInterface.shared?.terminateApplication()
            case toucherMagic:
                toucherDispatch(payload, touchState: touchState)
            case toucherSyncMagic:
                try await toucherSync(to: connection)
            case touchSequenceMagic:
                try await touchSequence(payload, to: connection, touchState: touchState)
            case versionMagic:
                try await version(to: connection)
            case bundleMagic:
                try await bundleID(to: connection)
            case rectMagic:
                try await rectangle(to: connection)
            case bgrMagic:
                try await bgrScreencap(to: connection)
            case nativeScreencapMagic:
                try await nativeScreencap(to: connection)
            default:
                break
            }
        }
    }

    // swiftlint:enable cyclomatic_complexity

    // swiftlint:disable line_length

    private func readPayload(from connection: NWConnection,
                             touchState: MaaToolsTouchState) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(MAX_BUFFERED_MAA_TOOLS_MESSAGES)) { continuation in
            let receiver = Task { [weak self] in
                while true {
                    do {
                        try Task.checkCancellation()
                        let (header, _, _) = try await connection.receive(minimumIncompleteLength: 2, maximumLength: 2)
                        guard header.count == 2 else { throw MaaToolsError.invalidFrameLength }
                        let length = header.u16(at: 0)
                        guard (MIN_MAA_TOOLS_PAYLOAD_LENGTH ... MAX_MAA_TOOLS_PAYLOAD_LENGTH).contains(length) else {
                            throw MaaToolsError.invalidFrameLength
                        }

                        try Task.checkCancellation()
                        let (payload, _, _) = try await connection.receive(minimumIncompleteLength: length, maximumLength: length)
                        guard payload.count == length else { throw MaaToolsError.invalidFrameLength }
                        switch continuation.yield(payload) {
                        case .enqueued:
                            break
                        case .dropped:
                            throw MaaToolsError.receiveBufferOverflow
                        case .terminated:
                            throw MaaToolsError.connectionClosed
                        @unknown default:
                            throw MaaToolsError.invalidMessage
                        }
                    } catch {
                        self?.connectionDidClose(touchState)
                        connection.cancel()
                        continuation.finish(throwing: error)
                        break
                    }
                }
            }

            continuation.onTermination = { _ in
                receiver.cancel()
            }
        }
    }

    // swiftlint:enable line_length

    private func screencap(to connection: NWConnection) async throws {
        setupWindow()
        let data = screenshot() ?? Data()
        try await connection.send(content: data.count.u32Bytes + data)
    }

    private func screenshot() -> Data? {
        guard let image = AKInterface.shared?.windowImage else {
            logger.error("Failed to fetch CGImage")
            return nil
        }

        // Crop the title bar
        let expectedHeight = image.width * height / width
        let titleBarHeight = max(0, image.height - expectedHeight)
        let sourceWidth = image.width
        let sourceHeight = image.height - titleBarHeight
        if sourceWidth != width || sourceHeight != height {
            let key = "\(sourceWidth)x\(sourceHeight)->\(width)x\(height)"
            if lastScrnResampleWarning != key {
                lastScrnResampleWarning = key
                logger.warning("SCRN resampling \(key, privacy: .public)")
            }
        }
        let contentRect = CGRect(x: 0, y: titleBarHeight, width: image.width,
                                 height: image.height - titleBarHeight)
        guard let image = image.cropping(to: contentRect) else {
            logger.error("Failed to crop image")
            return nil
        }

        let length = 4 * height * width
        let bytesPerRow = 4 * width
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrderDefault.rawValue
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: buffer, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: colorSpace, bitmapInfo: bitmapInfo)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let data = Data(bytesNoCopy: buffer, count: length, deallocator: .free)

        return data
    }

    private func screensize(to connection: NWConnection) async throws {
        setupWindow()
        try await connection.send(content: width.u16Bytes + height.u16Bytes)
    }

    private func toucherDispatch(_ content: Data, touchState: MaaToolsTouchState) {
        guard let event = touchEvent(in: content, at: 4, delayMicroseconds: 0) else { return }
        setupWindow()
        dispatchTouch(event, touchState: touchState)
    }

    private func touchSequence(_ content: Data,
                               to connection: NWConnection,
                               touchState: MaaToolsTouchState) async throws {
        guard let events = touchSequenceEvents(from: content) else {
            resetTouch(in: touchState)
            _ = await syncPendingTouchEvents()
            try await sendTouchResponse(false, to: connection)
            return
        }

        let sequenceTask = Task { @MainActor in
            try await self.executeTouchSequence(events, touchState: touchState)
        }
        touchState.beginSequence(sequenceTask)
        defer { touchState.endSequence() }

        do {
            try await withTaskCancellationHandler {
                try await sequenceTask.value
            } onCancel: {
                sequenceTask.cancel()
            }
            try Task.checkCancellation()
        } catch {
            resetTouch(in: touchState)
            if touchState.connectionClosed {
                throw MaaToolsError.connectionClosed
            }
            _ = await syncPendingTouchEvents()
            try await sendTouchResponse(false, to: connection)
            return
        }

        guard !touchState.connectionClosed else {
            throw MaaToolsError.connectionClosed
        }
        // The final event's delivery barrier has already synchronized the entire sequence.
        try await sendTouchResponse(true, to: connection)
    }

    private func executeTouchSequence(_ events: [MaaToolsTouchEvent],
                                      touchState: MaaToolsTouchState) async throws {
        let delayNanoseconds = events.reduce(UInt64(0)) { $0 + UInt64($1.delayMicroseconds) * 1_000 }
        var previousDispatchTime = DispatchTime.now().uptimeNanoseconds
        let deadline = previousDispatchTime + delayNanoseconds
            + UInt64(TOUCH_SEQUENCE_DELIVERY_SLACK * 1_000_000_000)

        for event in events {
            try Task.checkCancellation()
            let due = previousDispatchTime + UInt64(event.delayMicroseconds) * 1_000
            let now = DispatchTime.now().uptimeNanoseconds
            guard due < deadline, now < deadline else { throw MaaToolsError.touchSequenceTimedOut }
            // Delivery wait time counts toward the next relative delay, rather than being added to it.
            if due > now {
                try await Task.sleep(nanoseconds: due - now)
            }
            try Task.checkCancellation()
            let dispatchedAt = DispatchTime.now().uptimeNanoseconds
            guard dispatchedAt < deadline else { throw MaaToolsError.touchSequenceTimedOut }
            previousDispatchTime = dispatchedAt
            dispatchTouch(event, touchState: touchState)

            // PTFakeMetaTouch stores mutable UITouch state. Do not overwrite it until sendEvent returns.
            let delivered = await syncPendingTouchEvents(until: deadline)
            try Task.checkCancellation()
            guard delivered else { throw MaaToolsError.touchDeliveryFailed }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw MaaToolsError.touchSequenceTimedOut
            }
        }
    }

    private func touchSequenceEvents(from content: Data) -> [MaaToolsTouchEvent]? {
        setupWindow()
        guard content.count >= TOUCH_SEQUENCE_HEADER_LENGTH else { return nil }

        let eventCount = content.u16(at: 4)
        guard (1 ... MAX_TOUCH_SEQUENCE_EVENTS).contains(eventCount),
              content.count == TOUCH_SEQUENCE_HEADER_LENGTH + eventCount * TOUCH_SEQUENCE_EVENT_LENGTH,
              width > 0, height > 0 else {
            return nil
        }

        var events = [MaaToolsTouchEvent]()
        events.reserveCapacity(eventCount)
        var totalDuration: UInt64 = 0
        var sequenceTouchIsActive = false

        for eventIndex in 0..<eventCount {
            let eventOffset = TOUCH_SEQUENCE_HEADER_LENGTH + eventIndex * TOUCH_SEQUENCE_EVENT_LENGTH
            let delayMicroseconds = content.u32(at: eventOffset)
            let nextDuration = totalDuration + UInt64(delayMicroseconds)
            guard delayMicroseconds <= MAX_TOUCH_SEQUENCE_EVENT_DELAY_US,
                  nextDuration <= MAX_TOUCH_SEQUENCE_DURATION_US,
                  let event = touchEvent(in: content, at: eventOffset + 4,
                                         delayMicroseconds: delayMicroseconds),
                  (0..<width).contains(event.x),
                  (0..<height).contains(event.y) else {
                return nil
            }

            switch (sequenceTouchIsActive, event.phase) {
            case (false, .down):
                sequenceTouchIsActive = true
            case (true, .move):
                break
            case (true, .up):
                sequenceTouchIsActive = false
            default:
                return nil
            }

            events.append(event)
            totalDuration = nextDuration
        }

        guard !sequenceTouchIsActive else { return nil }
        return events
    }

    private func touchEvent(in content: Data,
                            at offset: Int,
                            delayMicroseconds: UInt32) -> MaaToolsTouchEvent? {
        guard offset >= 0, offset + 5 <= content.count,
              let phase = MaaToolsTouchPhase(rawValue: content[offset]) else {
            return nil
        }
        return MaaToolsTouchEvent(delayMicroseconds: delayMicroseconds,
                                  phase: phase,
                                  x: content.u16(at: offset + 1),
                                  y: content.u16(at: offset + 3))
    }

    private func dispatchTouch(_ event: MaaToolsTouchEvent, touchState: MaaToolsTouchState) {
        if event.phase == .down {
            resetTouch(in: touchState)
        }

        let point = CGPoint(x: event.x.divRound(by: scale),
                            y: event.y.divRound(by: scale))
        touchState.lastTouchPoint = point
        Toucher.touchcam(point: point, phase: event.phase.uiPhase, context: touchState.context,
                         actionName: event.phase.actionName, keyName: "touch")
        if event.phase == .up {
            touchState.lastTouchPoint = nil
        }
    }

    private func resetTouch(in touchState: MaaToolsTouchState) {
        guard touchState.context.isActive else {
            touchState.lastTouchPoint = nil
            return
        }

        Toucher.touchcam(point: touchState.lastTouchPoint ?? .zero, phase: .cancelled,
                         context: touchState.context,
                         actionName: "cancel", keyName: "touch")
        touchState.lastTouchPoint = nil
    }

    private func connectionDidClose(_ touchState: MaaToolsTouchState) {
        touchState.connectionDidClose()
        resetTouch(in: touchState)
    }

    nonisolated private func toucherSync(to connection: NWConnection) async throws {
        let delivered = await syncPendingTouchEvents()
        try await sendTouchResponse(delivered, to: connection)
    }

    nonisolated private func syncPendingTouchEvents(until deadline: UInt64? = nil) async -> Bool {
        var timeout = TOUCH_SYNC_TIMEOUT
        if let deadline {
            // Recompute on this executor immediately before registering the barrier.
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            let remaining = Double(deadline - now) / 1_000_000_000
            timeout = min(timeout, remaining)
        }
        return await withCheckedContinuation { continuation in
            PTFakeMetaTouch.syncPendingEvents(timeout: timeout) { delivered in
                continuation.resume(returning: delivered)
            }
        }
    }

    nonisolated private func sendTouchResponse(_ delivered: Bool,
                                               to connection: NWConnection) async throws {
        let response = delivered ? "OKAY" : "FAIL"
        try await connection.send(content: response.data(using: .ascii))
    }

    private func version(to connection: NWConnection) async throws {
        try await connection.send(content: MAA_TOOLS_VERSION.u32Bytes)
    }

    private func bundleID(to connection: NWConnection) async throws {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let data = Data(bundleID.utf8)
        try await connection.send(content: data.count.u32Bytes + data)
    }

    private func rectangle(to connection: NWConnection) async throws {
        let frame = AKInterface.shared?.windowFrame ?? CGRect()
        let content = AKInterface.shared?.windowContentRect ?? CGRect()

        let flatten = { (rect: CGRect) in
            [rect.origin.x, rect.origin.y,
             rect.size.width, rect.size.height]
        }

        let data = [frame, content].flatMap(flatten)
            .map { Int($0.rounded()).u16Bytes }
            .reduce(into: Data()) { partialResult, value in
                partialResult.append(value)
            }

        try await connection.send(content: data)
    }

    private func bgrScreenshot() -> (Int, Int, Data)? {
        setupWindow()
        guard let image = AKInterface.shared?.windowImage else {
            logger.error("Failed to fetch CGImage")
            return nil
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(alpha: .noneSkipLast, byteOrder: .orderDefault)

        let format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32,
                                          colorSpace: colorSpace, bitmapInfo: bitmapInfo)

        let buffer: vImage_Buffer
        do {
            buffer = try vImage_Buffer(cgImage: image, format: format!)
            logger.debug("Got buffer: \(buffer.width)x\(buffer.height)")
        } catch {
            logger.error("Failed to create buffer: \(error.localizedDescription)")
            return nil
        }
        defer { buffer.free() }

        // Crop the title bar
        let expectedHeight = buffer.width * UInt(height) / UInt(width)
        let contentHeight = min(buffer.height, expectedHeight)
        let titleBarHeight = buffer.height - contentHeight
        logger.debug("Cropping \(titleBarHeight) rows, expecting \(buffer.width)x\(contentHeight)")
        logger.debug("NATV/BGR \(buffer.width)x\(contentHeight)")
        logCaptureMetrics(imageWidth: image.width, imageHeight: image.height,
                          contentWidth: Int(buffer.width), contentHeight: Int(contentHeight),
                          titleBarHeight: Int(titleBarHeight))

        let offset = Int(titleBarHeight) * buffer.rowBytes
        var src = vImage_Buffer(data: buffer.data + offset,
                                height: contentHeight, width: buffer.width,
                                rowBytes: buffer.rowBytes)

        let bgrLength = Int(3 * contentHeight * buffer.width)
        let bgrBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bgrLength)
        var dst = vImage_Buffer(data: bgrBuffer,
                                height: contentHeight, width: buffer.width,
                                rowBytes: 3 * Int(buffer.width))

        vImagePermuteChannels_ARGB8888(&src, &src, [2, 1, 0, 3], vImage_Flags(kvImageNoFlags))
        vImageConvert_RGBA8888toRGB888(&src, &dst, vImage_Flags(kvImageNoFlags))

        let data = Data(bytesNoCopy: bgrBuffer, count: bgrLength, deallocator: .custom { pointer, _ in
            pointer.deallocate()
        })

        return (Int(buffer.width), Int(contentHeight), data)
    }

    private func bgrScreencap(to connection: NWConnection) async throws {
        let (width, height, data) = bgrScreenshot() ?? (0, 0, Data())
        let payload = width.u32Bytes + height.u32Bytes + data.count.u32Bytes + data
        try await connection.send(content: payload)
    }

    private func nativeScreencap(to connection: NWConnection) async throws {
        let (width, height, data) = bgrScreenshot() ?? (0, 0, Data())
        var payload = Data()
        payload.append(width.u32Bytes)
        payload.append(height.u32Bytes)
        payload.append(Data("BGR3".utf8))
        payload.append(data.count.u32Bytes)
        payload.append(data)
        try await connection.send(content: payload)
    }

    private func logCaptureMetrics(imageWidth: Int,
                                   imageHeight: Int,
                                   contentWidth: Int,
                                   contentHeight: Int,
                                   titleBarHeight: Int) {
        let frame = format(AKInterface.shared?.windowFrame ?? CGRect())
        let content = format(AKInterface.shared?.windowContentRect ?? CGRect())
        logger.debug("NSWindow frame \(frame, privacy: .public), contentRect \(content, privacy: .public)")
        logger.debug(
            "CGWindow \(imageWidth)x\(imageHeight), content \(contentWidth)x\(contentHeight), title \(titleBarHeight)"
        )
    }

    private func format(_ rect: CGRect) -> String {
        let x = Int(rect.origin.x.rounded())
        let y = Int(rect.origin.y.rounded())
        let width = Int(rect.size.width.rounded())
        let height = Int(rect.size.height.rounded())
        return "\(x),\(y) \(width)x\(height)"
    }
}

private struct MaaToolsTouchEvent {
    let delayMicroseconds: UInt32
    let phase: MaaToolsTouchPhase
    let x: Int
    let y: Int
}

private enum MaaToolsTouchPhase: UInt8 {
    case down = 0
    case move = 1
    case up = 3

    var uiPhase: UITouch.Phase {
        switch self {
        case .down:
            return .began
        case .move:
            return .moved
        case .up:
            return .ended
        }
    }

    var actionName: String {
        switch self {
        case .down:
            return "down"
        case .move:
            return "move"
        case .up:
            return "up"
        }
    }
}

@MainActor private final class MaaToolsTouchState {
    let context = Toucher.TouchContext()
    var lastTouchPoint: CGPoint?
    private var activeSequenceTask: Task<Void, Error>?
    private(set) var connectionClosed = false

    func beginSequence(_ task: Task<Void, Error>) {
        activeSequenceTask = task
        if connectionClosed {
            task.cancel()
        }
    }

    func endSequence() {
        activeSequenceTask = nil
    }

    func connectionDidClose() {
        connectionClosed = true
        activeSequenceTask?.cancel()
    }
}

private enum MaaToolsError: Error {
    case connectionClosed
    case emptyContent
    case invalidFrameLength
    case invalidMessage
    case receiveBufferOverflow
    case touchDeliveryFailed
    case touchSequenceTimedOut
}

private extension Int {
    var u16Bytes: Data {
        let bytes = [UInt8(self >> 8 & 0xff), UInt8(self & 0xff)]
        return Data(bytes)
    }

    var u32Bytes: Data {
        let bytes = [UInt8(self >> 24 & 0xff), UInt8(self >> 16 & 0xff), UInt8(self >> 8 & 0xff), UInt8(self & 0xff)]
        return Data(bytes)
    }

    func divRound(by div: Double) -> Int {
        let value = Double(self) / div
        return Int(value.rounded())
    }
}

private extension Data {
    func u16(at offset: Int) -> Int {
        guard offset < count - 1 else { return 0 }
        return Int(self[offset]) * 256 + Int(self[offset + 1])
    }

    func u32(at offset: Int) -> UInt32 {
        guard offset < count - 3 else { return 0 }
        return UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }
}

// swiftlint:disable large_tuple line_length

private extension NWConnection {
    func receive(minimumIncompleteLength: Int, maximumLength: Int) async throws -> (Data, NWConnection.ContentContext, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength) { content, contentContext, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if isComplete && (content?.isEmpty ?? true) {
                    continuation.resume(throwing: MaaToolsError.connectionClosed)
                    return
                }

                guard let content, let contentContext else {
                    continuation.resume(throwing: MaaToolsError.emptyContent)
                    return
                }

                continuation.resume(returning: (content, contentContext, isComplete))
            }
        }
    }

    func send(content: Data?, contentContext: NWConnection.ContentContext = .defaultMessage, isComplete: Bool = true) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            send(content: content, contentContext: contentContext, isComplete: isComplete, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }
}

// swiftlint:enable large_tuple line_length
