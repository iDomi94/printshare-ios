import XCTest

/// App Store Connect rejects uploads whose app or extension still carries XcodeGen's default "1.0" / "1".
final class BundleVersionTests: XCTestCase {
    private func versions(_ bundle: Bundle) -> (String?, String?) {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    func testAppAndShareExtensionUseTheBuildSettings() throws {
        let (appVersion, appBuild) = versions(.main)
        XCTAssertNotEqual(appVersion, "1.0")
        XCTAssertNotEqual(appBuild, "1")
        XCTAssertGreaterThanOrEqual(Int(appBuild ?? "") ?? 0, 100, "CURRENT_PROJECT_VERSION starts at 100")

        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let appex = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "appex" })
        let (extVersion, extBuild) = versions(try XCTUnwrap(Bundle(url: appex)))
        XCTAssertEqual(extVersion, appVersion)
        XCTAssertEqual(extBuild, appBuild)
    }
}
