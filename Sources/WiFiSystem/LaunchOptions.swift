import Foundation

/// The demo scenario asked for with `--demo <name>`, or nil when the flag is absent (real mode).
/// A missing or unknown name still means demo mode and falls back to `.office`, never to real data.
public func demoScenario(arguments: [String]) -> DemoScenario? {
    guard let index = arguments.firstIndex(of: "--demo") else { return nil }
    let next = arguments.index(after: index)
    guard next < arguments.endIndex else { return .office }
    return DemoScenario(rawValue: arguments[next]) ?? .office
}
