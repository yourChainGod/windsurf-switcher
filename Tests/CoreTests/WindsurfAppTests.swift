//
//  WindsurfAppTests.swift
//  CoreTests
//

import XCTest
@testable import Core

final class WindsurfAppTests: XCTestCase {

    func testStablePathsAndScheme() {
        let s = WindsurfApp.stable
        XCTAssertEqual(s.appPath.path, "/Applications/Windsurf.app")
        XCTAssertEqual(s.lsBinaryPath.path,
                       "/Applications/Windsurf.app/Contents/Resources/app/extensions/windsurf/bin/language_server_macos_arm")
        XCTAssertEqual(s.lsBinaryRealBackupPath.path,
                       "/Applications/Windsurf.app/Contents/Resources/app/extensions/windsurf/bin/language_server_macos_arm.real")
        XCTAssertEqual(s.deepLinkSchemePrefix, "windsurf://")
        XCTAssertEqual(s.bundleIdentifier, "com.exafunction.windsurf")
    }

    func testNextPathsAndScheme() {
        let n = WindsurfApp.next
        XCTAssertEqual(n.appPath.path, "/Applications/Windsurf - Next.app")
        XCTAssertEqual(n.deepLinkSchemePrefix, "windsurf-next://")
        XCTAssertEqual(n.bundleIdentifier, "com.exafunction.windsurfNext")
    }

    func testSwitchURLStableEncodesOTT() throws {
        let url = WindsurfApp.stable.switchURL(ott: "/ott$abc-123_XYZ")
        XCTAssertNotNil(url)
        let s = url!.absoluteString
        // RFC 3986 unreserved 之外都要转义。`/`, `$` 都应被转义。
        XCTAssertTrue(s.hasPrefix("windsurf://codeium.windsurf#state=switch&access_token="))
        XCTAssertTrue(s.contains("%2Fott%24abc-123_XYZ"))
    }

    func testSwitchURLNextDifferentScheme() throws {
        let stable = WindsurfApp.stable.switchURL(ott: "abc")!
        let next = WindsurfApp.next.switchURL(ott: "abc")!
        XCTAssertTrue(stable.absoluteString.hasPrefix("windsurf://"))
        XCTAssertTrue(next.absoluteString.hasPrefix("windsurf-next://"))
    }
}
