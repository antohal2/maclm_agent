import Foundation
@testable import maclm_agent
import XCTest

@MainActor final class SkillDraftPolicyTests: XCTestCase {
    func testPetExclusionAndMemoryFlagAreRestrictedToDraftTool() {
        XCTAssertTrue(ToolApprovalPolicy.neverRemember("create_skill_draft"))
        XCTAssertFalse(ToolApprovalPolicy.neverRemember("write_file"))
        XCTAssertFalse(PetApprovalPolicy.allows(
            risk: .caution, source: .pet, hidden: false, toolName: "create_skill_draft"
        ))
        XCTAssertTrue(PetApprovalPolicy.allows(
            risk: .caution, source: .feed, hidden: true, toolName: "create_skill_draft"
        ))
        XCTAssertTrue(PetApprovalPolicy.allows(
            risk: .caution, source: .pet, hidden: false, toolName: "write_file"
        ))
        XCTAssertFalse(PetApprovalPolicy.allows(
            risk: .dangerous, source: .pet, hidden: false, toolName: "run_shell"
        ))
        XCTAssertFalse(PetApprovalPolicy.allows(
            risk: .caution, source: .pet, hidden: true, toolName: "write_file"
        ))
    }

    func testModelFileToolsCannotAccessStagingEvenWithAllowRule() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = home.appendingPathComponent(
            "Library/Application Support/local.test/skill-staging/random/SKILL.md"
        ).path
        var rules = ApplicationProtection.rules(
            storeURL: home.appendingPathComponent("store"), bundleID: "local.test", home: home
        )
        rules.append(.init(pattern: path, action: .allow, order: -1000))
        let policy = SecurityPolicyEngine(rules: rules)
        for tool: any Tool in [
            ReadFileTool(), WriteFileTool(), ListDirectoryTool(), SearchFilesTool(), DeleteFileTool(), MoveFileTool(),
        ] {
            XCTAssertEqual(policy.decision(
                for: tool, arguments: ["path": path, "root": path, "from": path, "to": path]
            ).disposition, .blocked)
        }
    }

    func testStableToolRegistryContainsDraftAndNoEnableToolOrEnableParameter() throws {
        let registry = ToolRegistry.all
        let tool = try XCTUnwrap(registry.tool(named: "create_skill_draft"))
        XCTAssertEqual(type(of: tool).baseRiskLevel, .caution)
        XCTAssertTrue(type(of: tool).isPolicyEnforceable)
        XCTAssertFalse(registry.definitions.contains { $0.function.name.contains("enable") })
        guard case let .object(properties, required, _) = tool.parametersSchema else {
            return XCTFail("missing schema")
        }
        XCTAssertEqual(Set(properties.keys), Set(["name", "description", "instructions", "files"]))
        XCTAssertEqual(Set(required), Set(properties.keys))
    }
}
