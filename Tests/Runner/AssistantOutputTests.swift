import Testing
import Foundation
import MacDubCore

@Suite struct ClaudeCodeOutputTests {
    // Trimmed from a real `claude -p … --output-format json` run (Claude Code CLI, 2026-09).
    static let real = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":1612,"result":"ok","total_cost_usd":0.0829716,"usage":{"input_tokens":2,"cache_creation_input_tokens":10063,"cache_read_input_tokens":11898,"output_tokens":4,"output_tokens_details":{"thinking_tokens":0}},"session_id":"8dc6ce11-c68f-4c46-9218-53996a1cd820"}"#

    @Test func parsesResultTokensAndCost() throws {
        let p = try #require(AssistantOutput.claudeCode(Self.real))
        #expect(p.text == "ok")
        #expect(p.inputTokens == 2 + 10063 + 11898)
        #expect(p.outputTokens == 4)
        #expect(p.costUSD == 0.0829716)
        #expect(!p.isError)
    }

    @Test func skipsNoiseBeforeTheJSON() throws {
        let p = try #require(AssistantOutput.claudeCode("Warning: something on stderr\n" + Self.real + "\n"))
        #expect(p.text == "ok")
    }

    @Test func flagsErrors() throws {
        let p = try #require(AssistantOutput.claudeCode(#"{"type":"result","is_error":true,"result":"Invalid API key"}"#))
        #expect(p.isError)
        #expect(p.text == "Invalid API key")
        #expect(p.inputTokens == nil)
    }

    @Test func plainTextIsNotParsed() {
        #expect(AssistantOutput.claudeCode("Just a summary in plain text.") == nil)
    }
}

@Suite struct CodexExecOutputTests {
    // Event shapes from codex-rs/exec/src/exec_events.rs (`codex exec --json`).
    static let run = """
    {"type":"thread.started","thread_id":"0199a213-81c0-7800-8aa1-bbab2a035a53"}
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"**Summarizing the transcript**"}}
    {"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Resumen: tres puntos clave."}}
    {"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"cache_write_input_tokens":0,"output_tokens":122,"reasoning_output_tokens":64}}
    """

    @Test func parsesAgentMessageAndUsage() throws {
        let p = try #require(AssistantOutput.codexExec(Self.run))
        #expect(p.text == "Resumen: tres puntos clave.")
        // input_tokens already includes the cached ones; output_tokens the reasoning ones.
        #expect(p.inputTokens == 24763)
        #expect(p.outputTokens == 122)
        #expect(p.costUSD == nil)
        #expect(!p.isError)
    }

    @Test func sumsUsageOverTurns() throws {
        let twoTurns = Self.run + "\n" + #"{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0}}"#
        let p = try #require(AssistantOutput.codexExec(twoTurns))
        #expect(p.inputTokens == 24863)
        #expect(p.outputTokens == 132)
    }

    @Test func turnFailedIsAnError() throws {
        let failed = """
        {"type":"thread.started","thread_id":"t"}
        {"type":"turn.failed","error":{"message":"You've hit your usage limit."}}
        """
        let p = try #require(AssistantOutput.codexExec(failed))
        #expect(p.isError)
        #expect(p.text == "You've hit your usage limit.")
    }

    @Test func plainOutputFromOldCLIsIsNotParsed() {
        #expect(AssistantOutput.codexExec("codex\nResumen en texto plano\ntokens used: 1234") == nil)
    }
}
