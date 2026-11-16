import Foundation
import AVFoundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Immutable values from the deterministic emergency planner. All values are
/// scenario estimates, not telemetry or validated EVA advice.
nonisolated struct EmergencyExplanationInput: Sendable {
    var routeFound: Bool
    var distanceMeters: Double
    var durationMinutes: Double
    var reservePercent: Double
    var limitingResource: String
    var warning: String?

    var deterministicExplanation: String {
        guard routeFound else {
            return "Simulated emergency: no demo return route was found. \(warning ?? "Review the route and terrain assumptions.")"
        }
        let distance = distanceMeters.isFinite ? max(0, distanceMeters) : 0
        let duration = durationMinutes.isFinite ? max(0, durationMinutes) : 0
        let reserve = reservePercent.isFinite ? reservePercent : 0
        let details = String(format: "Simulated return: %.0f meters, %.1f minutes. Limiting modeled reserve: %.0f%% (%@).", distance, duration, reserve, limitingResource)
        return details + (warning.map { " " + $0 } ?? "") + " These are demo assumptions, not live conditions or operational guidance."
    }
}

nonisolated struct EmergencyExplanation: Sendable {
    var text: String
    var isModelGenerated: Bool
}

@MainActor
final class EmergencyExplanationService {
    private let synthesizer = AVSpeechSynthesizer()

    /// Returns a deterministic explanation if the system model isn't available,
    /// errors, fails to call the read-only tool, or takes longer than eight seconds.
    func explain(_ input: EmergencyExplanationInput) async -> EmergencyExplanation {
        let fallback = EmergencyExplanation(text: input.deterministicExplanation, isModelGenerated: false)
        #if canImport(FoundationModels)
        guard #available(visionOS 26.0, *), SystemLanguageModel.default.availability == .available else { return fallback }
        return await withCheckedContinuation { continuation in
            let finish = ExplanationCompletion(continuation: continuation)
            let generation = Task { @MainActor in
                let generated = await Self.modelExplanation(input)
                finish.resume(generated ?? fallback)
            }
            Task {
                try? await Task.sleep(for: .seconds(8))
                finish.resume(fallback)
                generation.cancel()
            }
        }
        #else
        return fallback
        #endif
    }

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(AVSpeechUtterance(string: text))
    }

    func stopSpeaking() { synthesizer.stopSpeaking(at: .immediate) }

    #if canImport(FoundationModels)
    @available(visionOS 26.0, *)
    private static func modelExplanation(_ input: EmergencyExplanationInput) async -> EmergencyExplanation? {
        let invocation = ExplanationToolInvocation()
        let tool = EmergencyReturnReadTool(input: input, invocation: invocation)
        let session = LanguageModelSession(tools: [tool], instructions: "You explain a fictional Marswalk planner. Call the emergency return tool before answering. In one short sentence, describe the simulated planning context. Do not provide numbers, advice, assurances, weather forecasts, or facts beyond the tool result. Never say the route is safe.")
        do {
            let response = try await session.respond(to: "Use the emergency return tool, then briefly explain this demonstration.")
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = text.lowercased()
            let forbidden = ["safe", "guarantee", "shelter", "real-time", "live weather", "confirmed", "recommended"]
            guard await invocation.wasCalled, !text.isEmpty, text.count <= 240,
                  !text.contains(where: { $0.isNumber }),
                  !forbidden.contains(where: lower.contains) else { return nil }
            // The numbers and caveat are always rendered from the planner itself.
            return EmergencyExplanation(text: text + "\n\n" + input.deterministicExplanation, isModelGenerated: true)
        } catch {
            return nil
        }
    }
    #endif
}

/// Single completion prevents a late model result from replacing the timeout fallback.
private final class ExplanationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<EmergencyExplanation, Never>?
    init(continuation: CheckedContinuation<EmergencyExplanation, Never>) { self.continuation = continuation }
    func resume(_ result: EmergencyExplanation) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}

#if canImport(FoundationModels)
@available(visionOS 26.0, *)
private actor ExplanationToolInvocation {
    private(set) var wasCalled = false
    func markCalled() { wasCalled = true }
}

@available(visionOS 26.0, *)
private struct EmergencyReturnReadTool: Tool {
    @Generable struct Arguments {
        @Guide(description: "Request the current simulated emergency return summary.")
        var request: String
    }
    let description = "Read the simulated return route and budget. This tool does not modify mission state."
    let input: EmergencyExplanationInput
    let invocation: ExplanationToolInvocation

    func call(arguments: Arguments) async throws -> String {
        await invocation.markCalled()
        return input.deterministicExplanation
    }
}
#endif
