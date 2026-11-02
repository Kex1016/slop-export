import NIO
import NIOEmbedded
import XCTest
@testable import SlopCore

final class StartTLSNegotiatorTests: XCTestCase {
    private func makeChannel() throws -> (EmbeddedChannel, EventLoopFuture<Void>) {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: Void.self)
        try channel.pipeline.syncOperations.addHandler(StartTLSNegotiator(promise: promise))
        return (channel, promise.futureResult)
    }

    func testHappyPath() throws {
        let (channel, done) = try makeChannel()
        try channel.writeInbound(ByteBuffer(string: "* OK [CAPABILITY IMAP4rev1 STARTTLS] ready\r\n"))
        let sent = try channel.readOutbound(as: ByteBuffer.self)
        XCTAssertEqual(sent.map { String(buffer: $0) }, "S00000 STARTTLS\r\n")
        try channel.writeInbound(ByteBuffer(string: "S00000 OK Begin TLS\r\n"))
        XCTAssertNoThrow(try done.wait())
    }

    func testRejectsDataInjectedAfterOK() throws {
        let (channel, done) = try makeChannel()
        try channel.writeInbound(ByteBuffer(string: "* OK ready\r\n"))
        _ = try channel.readOutbound(as: ByteBuffer.self)
        _ = try? channel.writeInbound(ByteBuffer(string: "S00000 OK Begin TLS\r\n* CAPABILITY IMAP4rev1 X-EVIL\r\n"))
        XCTAssertThrowsError(try done.wait())
    }

    func testClosesWhenDataArrivesInALaterPacket() throws {
        let (channel, done) = try makeChannel()
        try channel.writeInbound(ByteBuffer(string: "* OK ready\r\n"))
        _ = try channel.readOutbound(as: ByteBuffer.self)
        try channel.writeInbound(ByteBuffer(string: "S00000 OK Begin TLS\r\n"))
        XCTAssertNoThrow(try done.wait())
        _ = try? channel.writeInbound(ByteBuffer(string: "* CAPABILITY X-EVIL\r\n"))
        XCTAssertFalse(channel.isActive)
    }

    func testRefusedStartTLS() throws {
        let (channel, done) = try makeChannel()
        try channel.writeInbound(ByteBuffer(string: "* OK ready\r\n"))
        _ = try channel.readOutbound(as: ByteBuffer.self)
        _ = try? channel.writeInbound(ByteBuffer(string: "S00000 BAD STARTTLS not supported\r\n"))
        XCTAssertThrowsError(try done.wait()) { error in
            guard case IMAPError.tls = error else { return XCTFail("\(error)") }
        }
    }
}
