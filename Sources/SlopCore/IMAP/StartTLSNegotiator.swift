import Foundation
import NIO

/// Handles the plaintext part of a STARTTLS connection by hand: read the greeting, send
/// `STARTTLS`, wait for the tagged `OK`. It then hands over to TLS with nothing left over.
///
/// It does not go through `IMAPClientHandler` on purpose. That handler buffers whatever arrives
/// after the `OK`, and cannot be removed from the pipeline, so plaintext an attacker injected
/// there would be parsed as if it came over TLS. Here, any byte after the `OK` line is an error.
final class StartTLSNegotiator: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    static let tag = "S00000"
    private enum State { case awaitingGreeting, awaitingOK, done }

    private var state = State.awaitingGreeting
    private var buffer = ByteBuffer()
    private let promise: EventLoopPromise<Void>
    private let maxLine = 8192

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        if state == .done {
            // Anything after the OK, even in a later packet, arrived unencrypted.
            fail(IMAPError.tls("the server sent unencrypted data after agreeing to STARTTLS; refusing to continue"),
                 context: context, alreadyResolved: true)
            return
        }
        buffer.writeBuffer(&incoming)
        do {
            while state != .done, let line = try nextLine() {
                try handle(line: line, context: context)
            }
            if state == .done {
                guard buffer.readableBytes == 0 else {
                    throw IMAPError.tls("the server sent unencrypted data after agreeing to STARTTLS; refusing to continue")
                }
                promise.succeed()
            }
        } catch {
            fail(error, context: context, alreadyResolved: false)
        }
    }

    private func fail(_ error: Error, context: ChannelHandlerContext, alreadyResolved: Bool) {
        if !alreadyResolved { promise.fail(error) }
        state = .done
        context.close(promise: nil)
    }

    private func nextLine() throws -> String? {
        let view = buffer.readableBytesView
        guard let lf = view.firstIndex(of: UInt8(ascii: "\n")) else {
            if buffer.readableBytes > maxLine { throw IMAPError.unexpected("over-long line before STARTTLS") }
            return nil
        }
        let length = lf - view.startIndex + 1
        let line = buffer.readString(length: length) ?? ""
        return line.trimmingCharacters(in: .newlines)
    }

    private func handle(line: String, context: ChannelHandlerContext) throws {
        let upper = line.uppercased()
        switch state {
        case .awaitingGreeting:
            guard upper.hasPrefix("* OK") else {
                throw IMAPError.bye("unexpected greeting: \(line.prefix(200))")
            }
            state = .awaitingOK
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: "\(Self.tag) STARTTLS\r\n")), promise: nil)
        case .awaitingOK:
            if upper.hasPrefix("* ") { return }  // e.g. an untagged CAPABILITY; ignored, refreshed after TLS
            guard upper.hasPrefix(Self.tag + " ") else {
                throw IMAPError.unexpected("unexpected line before STARTTLS completed: \(line.prefix(200))")
            }
            guard upper.hasPrefix(Self.tag + " OK") else {
                throw IMAPError.tls("the server refused STARTTLS: \(line.prefix(200))")
            }
            state = .done  // the caller resolves the promise once it has checked for trailing bytes
        case .done:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if state != .done {
            state = .done
            promise.fail(IMAPError.connectionClosed)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if state != .done {
            state = .done
            promise.fail(error)
        }
        context.close(promise: nil)
    }
}
