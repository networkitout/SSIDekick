import Testing
import WiFiSystem

@Suite struct LaunchOptionsTests {
    @Test func noFlagIsRealMode() {
        #expect(demoScenario(arguments: ["/path/WiFiUtil"]) == nil)
        #expect(demoScenario(arguments: ["/path/WiFiUtil", "planeTwin"]) == nil)
    }
    @Test func knownScenario() {
        #expect(demoScenario(arguments: ["/path/WiFiUtil", "--demo", "planeTwin"]) == .planeTwin)
        #expect(demoScenario(arguments: ["/path/WiFiUtil", "-NSFoo", "1", "--demo", "wifiOff"]) == .wifiOff)
    }
    @Test func everyScenarioParses() {
        for scenario in DemoScenario.allCases {
            #expect(demoScenario(arguments: ["x", "--demo", scenario.rawValue]) == scenario)
        }
    }
    @Test func unknownNameFallsBackToOffice() {
        #expect(demoScenario(arguments: ["x", "--demo", "nope"]) == .office)
    }
    @Test func missingNameFallsBackToOffice() {
        #expect(demoScenario(arguments: ["x", "--demo"]) == .office)
    }
}
