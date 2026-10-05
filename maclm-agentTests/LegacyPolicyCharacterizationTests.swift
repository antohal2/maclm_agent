@testable import maclm_agent
import XCTest

final class LegacyPolicyCharacterizationTests: XCTestCase {
    func testLegacyDecisionMatrix() {
        let policy = SecurityPolicyEngine(rules: [
            .init(pattern: "/workspace/**", action: .allow),
            .init(pattern: "/workspace/secret/**", action: .block),
        ])
        let context = ToolRiskContext(allowedDirectories: ["/workspace"])
        for (path, level, disposition) in [
            ("/workspace/file", RiskLevel.caution, PolicyDisposition.allowed),
            ("/workspace/../outside/file", .dangerous, .noDecision),
            ("/workspace-evil/file", .dangerous, .noDecision),
            ("/workspace/secret/file", .caution, .blocked),
        ] {
            XCTAssertEqual(
                ToolRiskEvaluator.evaluate(WriteFileTool(), arguments: ["path": path], context: context).level,
                level
            )
            XCTAssertEqual(policy.decision(for: path, dimension: .path).disposition, disposition)
            XCTAssertEqual(
                ToolRiskEvaluator.evaluate(ReadFileTool(), arguments: ["path": path], context: context).level,
                .safe
            )
        }
        XCTAssertEqual(
            ToolRiskEvaluator
                .evaluate(MoveFileTool(), arguments: ["from": "/workspace/a", "to": "/outside/b"], context: context)
                .level,
            .dangerous
        )
        XCTAssertEqual(
            policy.decision(for: RunShellTool(), arguments: ["command": "cat /workspace/secret/file"]),
            .noDecision
        )
        XCTAssertEqual(ToolRiskEvaluator.evaluate(RunShellTool(), arguments: [:], context: context).level, .dangerous)
    }
}
