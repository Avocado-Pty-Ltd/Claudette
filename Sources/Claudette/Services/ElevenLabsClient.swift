import Foundation

/// Small ElevenLabs client — only TTS, only what we need.
struct ElevenLabsClient {
    let apiKey: String
    let base = URL(string: "https://api.elevenlabs.io")!

    enum ElevenError: Error, LocalizedError {
        case notConfigured
        case http(Int, String)
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "ElevenLabs API key or voice ID is missing."
            case .http(_, let msg): return msg
            case .underlying(let e): return e.localizedDescription
            }
        }
    }

    /// Synthesize speech to MP3 bytes.
    ///
    /// Uses the non-streaming endpoint (`/v1/text-to-speech/{voice_id}`) because the
    /// `/stream` variant is tier-gated even when a user has quota; the non-streaming
    /// path works across Free/Creator/Pro. Voice settings are kept minimal so nothing
    /// gets rejected because the plan doesn't allow a specific style feature.
    func synthesize(text: String, voiceId: String, modelId: String) async throws -> Data {
        guard !apiKey.isEmpty, !voiceId.isEmpty else { throw ElevenError.notConfigured }

        // Percent-encode the voice ID so a pasted value with `?`, `#`, or path
        // separators can't reshape the request URL. `urlPathAllowed` is the correct
        // set for a path segment.
        let escapedVoiceId = voiceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? voiceId
        guard var comps = URLComponents(
            url: base.appendingPathComponent("v1/text-to-speech/\(escapedVoiceId)"),
            resolvingAgainstBaseURL: false
        ) else {
            throw ElevenError.notConfigured
        }
        comps.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        guard let url = comps.url else { throw ElevenError.notConfigured }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": modelId,
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw ElevenError.underlying(URLError(.badServerResponse))
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ElevenError.http(http.statusCode, Self.friendlyError(status: http.statusCode, body: data))
            }
            return data
        } catch let err as ElevenError {
            throw err
        } catch {
            throw ElevenError.underlying(error)
        }
    }

    /// Turn ElevenLabs' JSON error responses into a plain-English cause.
    /// ElevenLabs returns errors shaped like `{"detail": {"status": "...", "message": "..."}}`
    /// or sometimes just `{"detail": "reason string"}`.
    private static func friendlyError(status httpStatus: Int, body: Data) -> String {
        struct DetailObj: Decodable { let status: String?; let message: String? }
        struct EnvObj: Decodable { let detail: DetailObj? }
        struct EnvString: Decodable { let detail: String? }

        var apiStatus: String?
        var apiMessage: String?
        if let env = try? JSONDecoder().decode(EnvObj.self, from: body) {
            apiStatus = env.detail?.status
            apiMessage = env.detail?.message
        } else if let env = try? JSONDecoder().decode(EnvString.self, from: body) {
            apiMessage = env.detail
        }

        let statusKey = (apiStatus ?? "").lowercased()
        switch statusKey {
        case "quota_exceeded":
            return "ElevenLabs says: quota exceeded. If your dashboard shows credits, the specific voice or model may be gated on your plan — try one of the stock voices (Rachel / Adam / Bella) and the `eleven_multilingual_v2` model."
        case "voice_not_found", "voice_does_not_exist":
            return "That voice ID doesn't exist for your account. Copy an ID from elevenlabs.io → Voices."
        case "invalid_api_key":
            return "Your ElevenLabs API key isn't valid. Grab a fresh one from Profile → API Keys."
        case "missing_permissions", "insufficient_permissions":
            return "Your API key doesn't have the `text_to_speech` scope. Regenerate it and check that scope."
        case "invalid_voice_settings":
            return "ElevenLabs rejected the voice settings. Try switching the model to `eleven_multilingual_v2`."
        case "model_not_found":
            return "That model isn't available on your plan. Try `eleven_multilingual_v2`."
        case "too_many_concurrent_requests":
            return "ElevenLabs is throttling concurrent requests. Wait a second and retry."
        default:
            break
        }

        // Fall back to the HTTP status for common cases.
        switch httpStatus {
        case 401: return "ElevenLabs rejected the API key (HTTP 401). Check that it's active and has TTS permission."
        case 402: return "ElevenLabs says: payment required (HTTP 402). Even if you have credits, the specific voice or model may be tier-gated."
        case 403: return "ElevenLabs denied the request (HTTP 403). Usually the API key is missing scopes."
        case 404: return "Voice or model not found (HTTP 404)."
        case 422:
            let extra = apiMessage.map { ": \($0)" } ?? ""
            return "Invalid request to ElevenLabs (HTTP 422)\(extra)."
        case 429: return "ElevenLabs rate limit (HTTP 429). Wait a moment and retry."
        default:
            let base = "ElevenLabs HTTP \(httpStatus)"
            if let apiMessage { return "\(base): \(apiMessage)" }
            return base
        }
    }
}
