import XCTest
@testable import NeutronCore

final class SteamLibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("neutron-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testParsesVDF() throws {
        let vdf = try VDF.parse("""
        // comment
        "AppState"
        {
            "appid"     "548430"
            "name"      "Deep Rock \\"Galactic\\""
            "UserConfig" { "language" "english" }
            Unquoted    value [$WIN32]
        }
        """)
        let state = try XCTUnwrap(vdf["appstate"])
        XCTAssertEqual(state["AppID"]?.string, "548430")
        XCTAssertEqual(state["name"]?.string, #"Deep Rock "Galactic""#)
        XCTAssertEqual(state["UserConfig"]?["language"]?.string, "english")
        XCTAssertEqual(state["unquoted"]?.string, "value")
        XCTAssertThrowsError(try VDF.parse(#""a" { "b" "c""#))
    }

    func testMapsWindowsPaths() throws {
        let pfx = root.appendingPathComponent("pfx")
        XCTAssertEqual(SteamLibrary.hostURL(windowsPath: #"C:\Program Files (x86)\Steam"#, winePrefix: pfx)?.path,
                       pfx.appendingPathComponent("drive_c/Program Files (x86)/Steam").path)
        XCTAssertEqual(SteamLibrary.hostURL(windowsPath: #"Z:\Volumes\Games"#, winePrefix: pfx)?.path, "/Volumes/Games")
        XCTAssertNil(SteamLibrary.hostURL(windowsPath: "relative", winePrefix: pfx))
    }

    /// Steam's own library plus a second one on another drive, as libraryfolders.vdf lists them.
    func testFindsInstalledGames() throws {
        let pfx = root.appendingPathComponent("pfx")
        let steam = pfx.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        let other = root.appendingPathComponent("Games")
        try Fixtures.write(steam.appendingPathComponent("steamapps/libraryfolders.vdf"), Data("""
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" "apps" { "548430" "1" } }
            "1" { "path" "Z:\(other.path.replacingOccurrences(of: "/", with: "\\\\"))" }
        }
        """.utf8))
        func manifest(_ dir: URL, _ id: String, _ name: String, _ installdir: String, _ flags: Int) throws {
            try Fixtures.write(dir.appendingPathComponent("steamapps/appmanifest_\(id).acf"), Data("""
            "AppState" { "appid" "\(id)" "name" "\(name)" "installdir" "\(installdir)" "StateFlags" "\(flags)" }
            """.utf8))
        }
        try manifest(steam, "548430", "Deep Rock Galactic", "Deep Rock Galactic", 4)
        try manifest(other, "526870", "Satisfactory", "Satisfactory", 6)        // installed, update required
        try manifest(other, "1", "Half Downloaded", "Half", 1026)           // update started, not installed

        XCTAssertEqual(SteamLibrary.folders(steamRoot: steam, winePrefix: pfx).map(\.path), [steam.path, other.path])
        let games = SteamLibrary.games(steamRoot: steam, winePrefix: pfx)
        XCTAssertEqual(games.map(\.appID), ["548430", "1", "526870"])
        XCTAssertEqual(games.first?.directory.path, steam.appendingPathComponent("steamapps/common/Deep Rock Galactic").path)
        XCTAssertEqual(games.map(\.fullyInstalled), [true, false, true])
    }
}
