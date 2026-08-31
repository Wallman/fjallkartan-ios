import Testing

@testable import fjallkartan

struct AppVersionTests {
    @Test(arguments: [
        ("1.0", "1.1", true),
        ("1.1", "1.0", false),
        ("1.0", "1.0", false),
        ("1.9", "1.10", true),
        ("1.2", "1.2.1", true),
        ("1.2.1", "1.2", false),
        ("1.2.0", "1.2", false),
        ("2.0", "1.9", false),
        ("1.0.0", "1.0.0", false),
    ])
    func comparesDottedVersions(version: String, minimum: String, expectedIsOlder: Bool) {
        #expect(AppVersion.isOlder(version, than: minimum) == expectedIsOlder)
    }
}
