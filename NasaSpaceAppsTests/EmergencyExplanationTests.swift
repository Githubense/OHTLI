import Testing
@testable import NasaSpaceApps

struct EmergencyExplanationTests {
    @Test func fallbackUsesPlannerValuesAndLabelsThemAsSimulated() {
        let input = EmergencyExplanationInput(routeFound: true, distanceMeters: 123, durationMinutes: 4.5,
                                              reservePercent: 62, limitingResource: "oxygen", warning: "Dust is simulated.")
        let text = input.deterministicExplanation
        #expect(text.contains("123 meters"))
        #expect(text.contains("4.5 minutes"))
        #expect(text.contains("62% (oxygen)"))
        #expect(text.contains("not live conditions"))
    }

    @Test func noRouteFallbackDoesNotInventRouteMetrics() {
        let input = EmergencyExplanationInput(routeFound: false, distanceMeters: 999, durationMinutes: 999,
                                              reservePercent: 999, limitingResource: "oxygen", warning: "Terrain is blocked.")
        let text = input.deterministicExplanation
        #expect(text.contains("no demo return route"))
        #expect(text.contains("Terrain is blocked"))
        #expect(!text.contains("999"))
    }
}
