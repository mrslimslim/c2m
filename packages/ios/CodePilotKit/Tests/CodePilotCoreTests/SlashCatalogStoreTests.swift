import XCTest
@testable import CodePilotCore
import CodePilotProtocol

final class SlashCatalogStoreTests: XCTestCase {
    func testStoreReplacesCatalogPerConnection() {
        let store = SlashCatalogStore()
        let original = makeCatalog(
            catalogVersion: "codex-0.115.0",
            defaults: .init(model: "gpt-5.3-codex", modelReasoningEffort: "medium"),
            commands: [makeCommand(id: "model")]
        )
        let replacement = makeCatalog(
            catalogVersion: "codex-0.116.0",
            defaults: .init(model: "gpt-5.4", modelReasoningEffort: "xhigh"),
            commands: [makeCommand(id: "model"), makeCommand(id: "review", kind: .bridgeAction)]
        )
        let otherConnectionCatalog = makeCatalog(
            catalogVersion: "codex-0.116.0",
            defaults: .init(model: "gpt-5.2"),
            commands: [makeCommand(id: "new", kind: .clientAction)]
        )

        store.replaceCatalog(original, for: "connection-1")
        store.replaceCatalog(otherConnectionCatalog, for: "connection-2")
        store.replaceCatalog(replacement, for: "connection-1")

        XCTAssertEqual(store.catalog(for: "connection-1"), replacement)
        XCTAssertEqual(store.catalog(for: "connection-2"), otherConnectionCatalog)
        XCTAssertEqual(store.catalogsByConnectionID.count, 2)
    }

    func testRouterStoresDecodedSlashCatalogForConnection() throws {
        let store = SlashCatalogStore()
        let router = SessionMessageRouter(
            sessionStore: SessionStore(),
            timelineStore: TimelineStore(),
            fileStore: FileStore(),
            diagnostics: DiagnosticsStore(),
            slashCatalogStore: store,
            connectionID: "connection-1"
        )

        router.handle(
            try decodeBridgeMessage(
                #"""
                {
                  "type": "slash_catalog",
                  "capability": "slash_catalog_v1",
                  "adapter": "codex",
                  "adapterVersion": "0.116.0",
                  "catalogVersion": "codex-0.116.0",
                  "defaults": {
                    "model": "gpt-5.4",
                    "modelReasoningEffort": "xhigh"
                  },
                  "commands": [
                    {
                      "id": "model",
                      "label": "/model",
                      "description": "Choose what model and reasoning effort to use",
                      "kind": "workflow",
                      "availability": "enabled",
                      "menu": {
                        "title": "Select Model and Effort",
                        "presentation": "list",
                        "options": [
                          {
                            "id": "gpt-5.4",
                            "label": "gpt-5.4",
                            "description": "Latest frontier agentic coding model.",
                            "next": {
                              "title": "Select Reasoning Level for gpt-5.4",
                              "presentation": "list",
                              "options": [
                                {
                                  "id": "xhigh",
                                  "label": "Extra high",
                                  "description": "Extra high reasoning depth for complex problems",
                                  "effects": [
                                    {
                                      "type": "set_session_config",
                                      "field": "model",
                                      "value": "gpt-5.4"
                                    },
                                    {
                                      "type": "set_session_config",
                                      "field": "modelReasoningEffort",
                                      "value": "xhigh"
                                    }
                                  ]
                                }
                              ]
                            }
                          }
                        ]
                      }
                    }
                  ]
                }
                """#
            )
        )

        XCTAssertEqual(store.catalog(for: "connection-1")?.catalogVersion, "codex-0.116.0")
        XCTAssertEqual(store.catalog(for: "connection-1")?.defaults.model, "gpt-5.4")
        XCTAssertEqual(store.catalog(for: "connection-1")?.defaults.modelReasoningEffort, "xhigh")
        XCTAssertEqual(store.catalog(for: "connection-1")?.commands.map { $0.id }, ["model"])
        XCTAssertNil(store.catalog(for: "connection-2"))
    }

    func testRouterStoresSlashActionResultForConnection() throws {
        let store = SlashCatalogStore()
        let router = SessionMessageRouter(
            sessionStore: SessionStore(),
            timelineStore: TimelineStore(),
            fileStore: FileStore(),
            diagnostics: DiagnosticsStore(),
            slashCatalogStore: store,
            connectionID: "connection-1"
        )

        router.handle(
            try decodeBridgeMessage(
                #"""
                {
                  "type": "slash_action_result",
                  "commandId": "review",
                  "ok": false,
                  "message": "Command is disabled"
                }
                """#
            )
        )

        let expectedResult = SlashActionResultMessage(
            commandId: "review",
            ok: false,
            message: "Command is disabled"
        )
        XCTAssertEqual(
            store.latestActionResult(for: "connection-1"),
            expectedResult
        )
        XCTAssertNil(store.latestActionResult(for: "connection-2"))
    }

    private func decodeBridgeMessage(_ json: String) throws -> BridgeMessage {
        try JSONDecoder().decode(BridgeMessage.self, from: Data(json.utf8))
    }

    private func makeCatalog(
        catalogVersion: String,
        defaults: SessionConfig,
        commands: [SlashCommandMeta]
    ) -> SlashCatalogMessage {
        .init(
            adapter: .codex,
            adapterVersion: catalogVersion.replacingOccurrences(of: "codex-", with: ""),
            catalogVersion: catalogVersion,
            defaults: defaults,
            commands: commands
        )
    }

    private func makeCommand(
        id: String,
        kind: SlashCommandKind = .workflow
    ) -> SlashCommandMeta {
        .init(
            id: id,
            label: "/\(id)",
            description: "Test command \(id)",
            kind: kind,
            availability: .enabled
        )
    }
}
