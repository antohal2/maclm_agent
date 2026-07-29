import Foundation
@testable import maclm_agent
import XCTest

final class MacLMAgentTests: XCTestCase {
    func testSSEParserParsesContentDeltaAcrossNetworkChunks() throws {
        var parser = SSEParser()
        let firstChunk = Data(#"data: {"choices":[{"delta":{"content":"Hel"#.utf8)
        let secondChunk = Data(#"lo"}}]}"#.utf8)
        let terminator = Data("\n\n".utf8)

        XCTAssertEqual(try parser.append(firstChunk), [])
        XCTAssertEqual(try parser.append(secondChunk), [])
        XCTAssertEqual(try parser.append(terminator), [.contentDelta("Hello")])
    }

    func testSSEParserParsesDone() throws {
        var parser = SSEParser()

        let events = try parser.append(Data("data: [DONE]\n\n".utf8))

        XCTAssertEqual(events, [.done])
    }

    func testSSEParserRejectsInvalidJSON() {
        var parser = SSEParser()

        XCTAssertThrowsError(try parser.append(Data("data: {invalid}\n\n".utf8))) { error in
            XCTAssertEqual(
                error as? LLMProviderError,
                .invalidSSEPayload("{invalid}")
            )
        }
    }
}
