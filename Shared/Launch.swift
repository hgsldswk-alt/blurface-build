import Foundation

enum Launch {
    static let freePeriod = true
    static let batchLimit = freePeriod ? 50 : 3
    static var isUITesting: Bool { has("-ui-testing") }
    static func has(_ flag: String) -> Bool { ProcessInfo.processInfo.arguments.contains(flag) }
    static func value(_ flag: String, in args: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
