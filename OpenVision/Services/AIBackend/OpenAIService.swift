// OpenVision - OpenAIService.swift
// Cloud backend for the OpenAI Chat Completions API (and any OpenAI-compatible endpoint).
//
// Streams by default (`stream: true`): text deltas are forwarded through `onPartialResponse` as
// they arrive, so the UI fills in and TTS starts speaking the first sentence while the model is
// still writing. A buffered request/response path remains and is used automatically when the
// endpoint can't serve SSE (or when the user turns streaming off in Settings → OpenAI).
//
// Supports text and images (base64 data URL). The final reply is delivered via `onAgentMessage`,
// matching the other backends so VoiceAgentView can wire it up the same way.

import Foundation
import UIKit

@MainActor
final class OpenAIService: ObservableObject {

    static let shared = OpenAIService()

    /// Called with the assistant's reply text (spoken via TTS by VoiceAgentView).
    var onAgentMessage: ((String) -> Void)?
    /// Called when processing starts/stops (drives the thinking/listening state).
    var onProcessingChanged: ((Bool) -> Void)?
    /// Called with the reply built so far while it streams — CUMULATIVE text, not a delta, to
    /// match `GemmaLocalService.onPartialResponse` so the view model's sentence-pipelining TTS
    /// (`feedStreamingSpeech`) works identically for both. Only fired for plain text answers;
    /// a response that turns out to be a tool call never emits partials.
    var onPartialResponse: ((String) -> Void)?

    @Published private(set) var isConnected = false

    /// Base URL that was found not to serve SSE. Remembered so a gateway without streaming
    /// degrades to the (still correct) buffered path instead of failing every turn — and so
    /// pointing the app at a different endpoint re-tests streaming rather than inheriting the
    /// verdict from the old one.
    private var streamingUnsupportedForBaseURL: String?

    private var settings: AppSettings { SettingsManager.shared.settings }

    private init() {}

    /// Lightweight "connect": OpenAI is stateless HTTP, so just validate config.
    func connect() async throws {
        guard settings.isOpenAIConfigured else { throw OpenAIError.notConfigured }
        isConnected = true
    }

    /// Send a prompt (optionally with an image) and deliver the reply via `onAgentMessage`.
    func sendMessage(_ text: String, imageData: Data? = nil) async throws {
        guard settings.isOpenAIConfigured else { throw OpenAIError.notConfigured }
        // Record the utterance for the tool registry's relative-time guard.
        NativeToolContext.shared.set(text)
        guard let url = URL(string: "\(settings.openAIBaseURL)/chat/completions") else {
            throw OpenAIError.badURL
        }

        onProcessingChanged?(true)
        defer { onProcessingChanged?(false) }

        // Build the user content: plain string for text-only, or the multimodal array with an
        // image_url data URL when a photo is attached.
        let userContent: Any
        if let imageData {
            let dataURL = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
            userContent = [
                ["type": "text", "text": text.isEmpty ? "Describe what you see." : text],
                ["type": "image_url", "image_url": ["url": dataURL]]
            ]
        } else {
            userContent = text
        }

        var messages: [[String: Any]] = []
        let system = systemPrompt()
        if !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        // Document-focus mode: while the user is working with a document, its most relevant
        // excerpts ride along on EVERY request — deterministic grounding, no tool-call judgment.
        if let docContext = DocumentFocus.shared.contextForQuery(text) {
            messages.append(["role": "system", "content": docContext])
        }
        // Prior turns so follow-up questions work ("what's its population?").
        for turn in ConversationContext.shared.turns {
            messages.append(["role": turn.role, "content": turn.content])
        }
        messages.append(["role": "user", "content": userContent])

        // Agentic web-search tool: the model calls it for current info, we run it, feed the result
        // back, and it can refine or answer — an iterative loop (OpenGlasses' cloud pattern).
        let webSearchTool: [String: Any] = [
            "type": "function",
            "function": [
                "name": "web_search",
                "description": "Search the web for current, real-time information — news, weather, prices, sports scores, recent events, or anything you're not certain of. Use it whenever the user asks about something current.",
                "parameters": [
                    "type": "object",
                    "properties": ["query": ["type": "string", "description": "The search query"]],
                    "required": ["query"]
                ]
            ]
        ]

        // Web search + on-device productivity tools (timers, reminders, calendar, notes, clipboard…).
        let tools = [webSearchTool] + NativeToolRegistry.shared.openAISpecs

        let maxIterations = 4
        for _ in 0..<maxIterations {
            // Stream when enabled and the endpoint supports it: the reply renders (and starts
            // being spoken) token-by-token instead of after the whole generation. The buffered
            // path stays as the fallback, and both produce the same assistant-message dict so the
            // tool-calling loop below is untouched by the choice.
            let useStreaming = settings.openAIStreamResponses
                && streamingUnsupportedForBaseURL != settings.openAIBaseURL
            var body: [String: Any] = [
                "model": settings.openAIModel,
                "messages": messages,
                "tools": tools,
                "max_tokens": 400
            ]
            if useStreaming { body["stream"] = true }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(settings.openAIAPIKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 60

            var message: [String: Any]
            if useStreaming {
                do {
                    message = try await streamAssistantMessage(request: request)
                } catch OpenAIError.streamingUnavailable(let why) {
                    // Endpoint answered but not with SSE (older gateway, proxy that buffers).
                    // Retry this same turn buffered and stop asking for streams this run.
                    NSLog("[OpenAI] streaming unavailable (%@) — falling back to buffered", why)
                    streamingUnsupportedForBaseURL = settings.openAIBaseURL
                    body.removeValue(forKey: "stream")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    message = try await bufferedAssistantMessage(request: request)
                }
            } else {
                message = try await bufferedAssistantMessage(request: request)
            }

            // Tool calls → execute (web_search or a native tool), feed results back, loop.
            if let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                messages.append(message)   // the assistant turn carrying tool_calls
                for call in toolCalls {
                    let id = call["id"] as? String ?? ""
                    let fn = call["function"] as? [String: Any]
                    let toolName = fn?["name"] as? String ?? ""
                    let argsStr = fn?["arguments"] as? String ?? "{}"
                    let args = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8))) as? [String: Any] ?? [:]

                    let result: String
                    if toolName == "web_search" {
                        let query = (args["query"] as? String) ?? ""
                        NSLog("[OpenAI] web_search: \"%@\"", query)
                        let r = await WebSearchService.search(query)
                        result = r.isEmpty ? "No results found for \"\(query)\"." : r
                    } else {
                        NSLog("[OpenAI] native tool: %@", toolName)
                        result = await NativeToolRegistry.shared.execute(name: toolName, args: args)
                    }
                    messages.append(["role": "tool", "tool_call_id": id, "content": result])
                }
                continue
            }

            // No tool call → final spoken answer.
            guard let reply = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else {
                throw OpenAIError.emptyReply
            }
            ConversationContext.shared.record(user: text, assistant: reply)
            onAgentMessage?(reply)
            return
        }
        throw OpenAIError.api("search loop didn't converge")
    }

    // MARK: - Prompt

    private func systemPrompt() -> String {
        // Keep replies short — they're spoken aloud. Append the user's custom instructions.
        let today = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        var parts = ["You are OpenVision, a helpful voice assistant for smart glasses. Answer conversationally and briefly (1-3 short sentences) since your reply is spoken aloud. If the user asks about current or real-time information, or anything you're not certain of, call the web_search tool and answer from its results — never say you can't access real-time data.",
                     "You can also handle productivity hands-free by calling the matching tool: set_timer, start_pomodoro, create_reminder, calendar (read/add events), note (save/search notes auto-tagged with place and time), copy_to_clipboard, and search_docs (search the user's imported manuals/recipes/guides — use it whenever they ask about their documents, and answer only from what it returns). For a specific time of day (e.g. '6pm', '9:30am') pass the tool's hour (24-hour) and minute, plus day_offset (0=today, 1=tomorrow) — let the tool do the date math. Use minutes_from_now only for 'in N minutes'. The current time is \(today).",
                     "After a tool runs, briefly confirm what you did in one sentence."]
        let custom = settings.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { parts.append(custom) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - One round trip (buffered)

    /// Classic request/response: read the whole body, return the assistant message dict.
    private func bufferedAssistantMessage(request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await Self.dataWithRetry(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.noResponse }
        guard (200...299).contains(http.statusCode) else {
            let detail = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            NSLog("[OpenAI] request failed: %@", detail)
            throw OpenAIError.api(detail)
        }
        guard let message = Self.firstMessage(from: data) else { throw OpenAIError.emptyReply }
        return message
    }

    // MARK: - One round trip (streamed)

    /// Read an SSE stream (`stream: true`) and reassemble it into the same assistant-message dict
    /// the buffered path returns, so the caller's tool-calling loop can't tell the difference.
    ///
    /// Two kinds of delta arrive on `choices[0].delta`:
    /// - `content` — plain text, appended and forwarded to `onPartialResponse` as it grows.
    /// - `tool_calls` — an array of partial calls keyed by `index`; `id`/`function.name` arrive
    ///   once and `function.arguments` arrives as a JSON string in fragments that must be
    ///   concatenated in order before they parse.
    ///
    /// Partial text is only forwarded when the response is NOT a tool call. OpenAI commits to one
    /// or the other in the first delta, so checking whether a tool-call delta has been seen is
    /// enough to keep the app from speaking a preamble that gets discarded a moment later.
    private func streamAssistantMessage(request: URLRequest) async throws -> [String: Any] {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.noResponse }

        guard (200...299).contains(http.statusCode) else {
            // Drain the (small) error body so the message is as useful as the buffered path's.
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            let detail = Self.errorMessage(from: raw) ?? "HTTP \(http.statusCode)"
            // 400s naming the parameter mean "this endpoint has no streaming", not "bad request".
            if http.statusCode == 400 && detail.lowercased().contains("stream") {
                throw OpenAIError.streamingUnavailable(detail)
            }
            NSLog("[OpenAI] stream request failed: %@", detail)
            throw OpenAIError.api(detail)
        }

        // A server that answers 200 with plain JSON ignored `stream: true`. Salvage it as a
        // buffered reply rather than failing the turn.
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard contentType.contains("event-stream") else {
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            if let message = Self.firstMessage(from: raw) { return message }
            throw OpenAIError.streamingUnavailable("content-type \(contentType.isEmpty ? "missing" : contentType)")
        }

        var content = ""
        var toolCalls: [Int: ToolCallAccumulator] = [:]
        var sawToolCallDelta = false
        var sawAnyFrame = false

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }   // skip ":" comments and blank lines
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { sawAnyFrame = true; break }
            guard let frame = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            sawAnyFrame = true

            // An error can arrive mid-stream (rate limit, context overflow) with a 200 header.
            if let error = frame["error"] as? [String: Any], let msg = error["message"] as? String {
                throw OpenAIError.api(msg)
            }

            guard let delta = (frame["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { continue }

            if let calls = delta["tool_calls"] as? [[String: Any]] {
                sawToolCallDelta = true
                for call in calls {
                    let index = call["index"] as? Int ?? 0
                    var accumulator = toolCalls[index] ?? ToolCallAccumulator()
                    if let id = call["id"] as? String, !id.isEmpty { accumulator.id = id }
                    if let function = call["function"] as? [String: Any] {
                        if let name = function["name"] as? String, !name.isEmpty { accumulator.name = name }
                        if let arguments = function["arguments"] as? String { accumulator.arguments += arguments }
                    }
                    toolCalls[index] = accumulator
                }
            }

            if let chunk = delta["content"] as? String, !chunk.isEmpty {
                content += chunk
                if !sawToolCallDelta { onPartialResponse?(content) }
            }
        }

        guard sawAnyFrame else { throw OpenAIError.streamingUnavailable("no SSE frames") }

        var message: [String: Any] = ["role": "assistant"]
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls.keys.sorted().map { toolCalls[$0]!.asDictionary() }
            // The API requires `content` present (null is fine) alongside tool_calls on the turn
            // that gets echoed back; an empty string keeps JSONSerialization simple and is accepted.
            message["content"] = content
        } else {
            message["content"] = content
        }
        return message
    }

    /// Partial tool call being reassembled from stream deltas.
    private struct ToolCallAccumulator {
        var id: String = ""
        var name: String = ""
        var arguments: String = ""

        func asDictionary() -> [String: Any] {
            [
                "id": id,
                "type": "function",
                "function": ["name": name, "arguments": arguments.isEmpty ? "{}" : arguments]
            ]
        }
    }

    // MARK: - Response parsing

    /// Chat Completions can drop a keep-alive connection between the multiple round-trips of a
    /// tool-calling loop (URLError -1005 "network connection lost", or a transient timeout). These
    /// are almost always recoverable, so retry once on a fresh connection before surfacing an error.
    private static func dataWithRetry(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where
            [.networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost].contains(error.code) {
            NSLog("[OpenAI] transient network error (%d) — retrying once", error.errorCode)
            try? await Task.sleep(nanoseconds: 600_000_000)
            return try await URLSession.shared.data(for: request)
        }
    }

    /// The full assistant message dict (content and/or tool_calls) from a Chat Completions response.
    private static func firstMessage(from data: Data) -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        return message
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = obj["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }
        return message
    }

    enum OpenAIError: LocalizedError {
        case notConfigured, badURL, noResponse, emptyReply, api(String)
        /// The endpoint accepted the request but didn't stream — internal signal to retry
        /// buffered, never surfaced to the user.
        case streamingUnavailable(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "OpenAI isn't configured. Add your API key in Settings → OpenAI."
            case .badURL: return "The OpenAI base URL is invalid."
            case .noResponse: return "No response from OpenAI."
            case .emptyReply: return "OpenAI returned an empty reply."
            case .api(let detail): return "OpenAI error: \(detail)"
            case .streamingUnavailable(let why): return "Streaming unavailable (\(why))."
            }
        }
    }
}
