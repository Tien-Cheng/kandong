import Foundation
import Testing
@testable import KandongKit

struct ChatGPTSettingsTests {
    @Test func replacesLegacyCodexWithDirectChatGPT() throws {
        let data = Data(#"{"backends":[{"id":"apple-intelligence","name":"Apple Intelligence","type":"appleIntelligence"},{"id":"codex","name":"Codex","type":"codex"}],"defaultBackendID":"codex","localBackendID":"apple-intelligence","codex":{"model":"saved-model","effort":"low"}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(settings.backends.map(\.id) == ["apple-intelligence", "chatgpt"])
        #expect(settings.defaultBackendID == "chatgpt")
        #expect(settings.localBackendID == "apple-intelligence")
        #expect(settings.chatGPT.accountID == nil)
        #expect(settings.chatGPT.model.isEmpty, "Codex model choices must not select a model from a different account catalog")
        let encoded = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["codex"] == nil)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("saved-model"))
    }

    @Test func freshInstallsRemainLocalAndChatGPTCannotBeLocal() {
        var settings = AppSettings()
        #expect(settings.defaultBackendID == "apple-intelligence")
        #expect(!settings.localCandidates.contains { $0.type == .chatGPT })
        settings.defaultBackendID = "chatgpt"
        settings.localBackendID = "chatgpt"
        #expect(settings.backend(local: false).type == .chatGPT)
        #expect(settings.backend(local: true).type == .appleIntelligence)
        settings.removeBackend(id: "chatgpt")
        #expect(settings.backend(id: "chatgpt") != nil)
    }

    @Test func migratesCodexWithoutLosingCustomBackendsOrChatGPTPreferences() throws {
        let data = Data(#"""
        {
          "backends": [
            {"id":"apple-intelligence","name":"Apple Intelligence","type":"appleIntelligence"},
            {"id":"codex","name":"Codex","type":"codex","readingModeSetting":"off"},
            {"id":"private-gateway","name":"Private gateway","type":"openAICompatible","preset":"other",
             "openAI":{"baseURL":"https://gateway.example.org/custom/v1","model":"private-model-revision","vision":"no",
                       "reasoning":{"translate":"medium","explain":"high"}},"readingModeSetting":"choose"},
            {"id":"lmstudio","name":"My local model","type":"openAICompatible","preset":"lmStudio",
             "openAI":{"baseURL":"http://localhost:1234/v1","model":"saved-local-model","vision":"yes"}}
          ],
          "defaultBackendID":"codex",
          "localBackendID":"lmstudio",
          "codex":{"executablePath":"/old/codex","model":"obsolete-codex-model","effort":"high"},
          "chatGPT":{"accountID":"oaiapp_saved","model":"saved-chatgpt-model","vision":"yes",
                     "reasoning":{"translate":"low","explain":"high"},"welcomedAccountIDs":["oaiapp_saved"]}
        }
        """#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(settings.backends.map(\.id) == ["apple-intelligence", "chatgpt", "private-gateway", "lmstudio"])
        #expect(settings.defaultBackendID == "chatgpt")
        #expect(settings.localBackendID == "lmstudio")
        #expect(settings.backend(id: "chatgpt")?.readingModeSetting == .off)
        let privateGateway = try #require(settings.backend(id: "private-gateway"))
        #expect(privateGateway.name == "Private gateway" && privateGateway.preset == .other)
        #expect(privateGateway.openAI?.baseURL == "https://gateway.example.org/custom/v1")
        #expect(privateGateway.openAI?.model == "private-model-revision")
        #expect(privateGateway.openAI?.vision == .no)
        #expect(privateGateway.reasoning == ReasoningSettings(translate: "medium", explain: "high"))
        #expect(privateGateway.readingModeSetting == .choose)
        #expect(privateGateway.keychainAccount == "api-key-private-gateway")
        #expect(settings.backend(id: "lmstudio")?.openAI?.model == "saved-local-model")
        #expect(settings.chatGPT.accountID == "oaiapp_saved" && settings.chatGPT.model == "saved-chatgpt-model")
        #expect(settings.chatGPT.vision == .yes && settings.chatGPT.reasoning.explain == "high")
        #expect(settings.chatGPT.welcomedAccountIDs == ["oaiapp_saved"])
        let encoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: encoded) == settings)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["codex"] == nil)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("obsolete-codex-model"))
    }

    @Test(arguments: [true, false]) func explicitChatGPTReadingChoiceWinsRegardlessOfListOrder(codexFirst: Bool) throws {
        let codex: [String: Any] = ["id": "codex", "name": "Codex", "type": "codex", "readingModeSetting": "off"]
        let chatGPT: [String: Any] = ["id": "chatgpt", "name": "ChatGPT", "type": "chatGPT", "readingModeSetting": "choose"]
        let object: [String: Any] = ["backends": codexFirst ? [codex, chatGPT] : [chatGPT, codex], "defaultBackendID": "chatgpt"]
        let settings = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(settings.backends.filter { $0.id == "chatgpt" }.count == 1)
        #expect(settings.backend(id: "chatgpt")?.readingModeSetting == .choose)
        #expect(settings.defaultBackendID == "chatgpt")
        #expect(settings.backend(id: "codex") == nil)
    }

    @Test func obsoleteRemoteLocalSelectionFallsBackToAppleIntelligence() throws {
        for json in [
            #"{"backends":[{"id":"codex","name":"Codex","type":"codex"}],"defaultBackendID":"codex","localBackendID":"codex"}"#,
            #"{"defaultBackend":"codex","localBackend":"codex"}"#,
        ] {
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            #expect(settings.defaultBackendID == "chatgpt")
            #expect(settings.localBackendID == "apple-intelligence")
            #expect(settings.backend(local: true).type == .appleIntelligence)
        }
    }

    @Test func preferencesRoundTripWithoutCredentials() throws {
        var settings = AppSettings()
        settings.chatGPT.accountID = "oaiapp_example"
        settings.chatGPT.model = "account-model"
        settings.chatGPT.reasoning.explain = "high"
        settings.chatGPT.vision = .yes
        settings.chatGPT.welcomedAccountIDs = ["oaiapp_example"]
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("accessToken"))
        #expect(!text.contains("refreshToken"))
        #expect(!text.contains("idToken"))
        #expect(try JSONDecoder().decode(ChatGPTSettings.self, from: Data("{}".utf8)) == ChatGPTSettings())
    }
}
