import NIO
import NIOIMAP

/// One message's worth of FETCH data, assembled from swift-nio-imap's streamed parts.
public struct FetchRecord: Sendable, Hashable {
    public var sequence: Int?
    public var uid: UInt32?
    public var flags: [String] = []
    public var internalDate: ServerMessageDate?
    public var size: Int?
    public var body: ByteBuffer?
}

/// Everything the server said in response to one tagged command.
struct CommandResult: Sendable {
    var untagged: [ResponsePayload] = []
    var fetches: [FetchRecord] = []
    var state: TaggedResponse.State = .ok(.init(text: ""))
}

/// What the client asks the collector to do. Written into the channel as an outbound message.
enum CollectorRequest: Sendable {
    /// Resolve once the server greeting has arrived.
    case greeting(EventLoopPromise<UntaggedStatus>)
    /// Send `parts`, then resolve when the tagged response for `tag` arrives.
    case command(tag: String, parts: [CommandStreamPart], timeout: TimeAmount, promise: EventLoopPromise<CommandResult>)
}

/// Sits on top of `IMAPClientHandler`. Matches responses to the one command in flight and
/// assembles streamed FETCH bodies. The client never pipelines, so one slot is enough.
final class ResponseCollector: ChannelDuplexHandler {
    typealias InboundIn = Response
    typealias OutboundIn = CollectorRequest
    typealias OutboundOut = IMAPClientHandler.Message

    private struct InFlight {
        var tag: String
        var promise: EventLoopPromise<CommandResult>
        var result = CommandResult()
        var currentFetch: FetchRecord?
        var timeout: Scheduled<Void>?
    }

    private var greeting: UntaggedStatus?
    private var greetingPromise: EventLoopPromise<UntaggedStatus>?
    private var inFlight: InFlight?
    private var closedError: Error?

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch self.unwrapOutboundIn(data) {
        case .greeting(let p):
            if let greeting { p.succeed(greeting) } else if let closedError { p.fail(closedError) } else { greetingPromise = p }
            promise?.succeed()
        case .command(let tag, let parts, let timeout, let p):
            if let closedError {
                p.fail(closedError)
                promise?.fail(closedError)
                return
            }
            guard inFlight == nil else {
                let err = IMAPError.unexpected("a second command was sent while one was in flight")
                p.fail(err)
                promise?.fail(err)
                return
            }
            var slot = InFlight(tag: tag, promise: p)
            slot.timeout = context.eventLoop.assumeIsolated().scheduleTask(in: timeout) { [weak self] in
                self?.timedOut(tag: tag, context: context)
            }
            inFlight = slot
            for (i, part) in parts.enumerated() {
                let isLast = i == parts.count - 1
                context.write(self.wrapOutboundOut(.part(part)), promise: isLast ? promise : nil)
            }
            context.flush()
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        switch response {
        case .untagged(let payload):
            if greeting == nil, inFlight == nil, case .conditionalState(let status) = payload {
                greeting = status
                greetingPromise?.succeed(status)
                greetingPromise = nil
                return
            }
            inFlight?.result.untagged.append(payload)
        case .fetch(let part):
            handleFetch(part)
        case .tagged(let tagged):
            guard var slot = inFlight, slot.tag == tagged.tag else { return }
            inFlight = nil
            slot.timeout?.cancel()
            slot.result.state = tagged.state
            slot.promise.succeed(slot.result)
        case .fatal(let text):
            fail(IMAPError.bye(text.text), context: context)
        case .authenticationChallenge, .idleStarted:
            break
        }
    }

    private func handleFetch(_ part: FetchResponse) {
        guard inFlight != nil else { return }
        switch part {
        case .start(let seq):
            inFlight!.currentFetch = FetchRecord(sequence: Int(seq.rawValue))
        case .startUID(let uid):
            inFlight!.currentFetch = FetchRecord(uid: uid.rawValue)
        case .simpleAttribute(let attr):
            switch attr {
            case .uid(let uid): inFlight!.currentFetch?.uid = uid.rawValue
            case .flags(let flags): inFlight!.currentFetch?.flags = flags.map { String($0) }
            case .internalDate(let date): inFlight!.currentFetch?.internalDate = date
            case .rfc822Size(let size): inFlight!.currentFetch?.size = size
            default: break
            }
        case .streamingBegin(_, let byteCount):
            inFlight!.currentFetch?.body = ByteBuffer()
            inFlight!.currentFetch?.body?.reserveCapacity(byteCount)
        case .streamingBytes(var bytes):
            inFlight!.currentFetch?.body?.writeBuffer(&bytes)
        case .streamingEnd:
            break
        case .finish:
            if let record = inFlight!.currentFetch { inFlight!.result.fetches.append(record) }
            inFlight!.currentFetch = nil
        }
    }

    private func timedOut(tag: String, context: ChannelHandlerContext) {
        guard inFlight?.tag == tag else { return }
        fail(IMAPError.timeout, context: context)
    }

    private func fail(_ error: Error, context: ChannelHandlerContext) {
        if closedError == nil { closedError = error }
        greetingPromise?.fail(error)
        greetingPromise = nil
        if let slot = inFlight {
            inFlight = nil
            slot.timeout?.cancel()
            slot.promise.fail(error)
        }
        context.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error, context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if closedError == nil { closedError = IMAPError.connectionClosed }
        let err = closedError!
        greetingPromise?.fail(err)
        greetingPromise = nil
        if let slot = inFlight {
            inFlight = nil
            slot.timeout?.cancel()
            slot.promise.fail(err)
        }
        context.fireChannelInactive()
    }
}
