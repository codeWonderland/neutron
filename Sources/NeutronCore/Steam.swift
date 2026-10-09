import Foundation

/// Steam for Windows inside a prefix (Phase 3). Its UI is Chromium, which renders through
/// ANGLE on D3D11 from a separate GPU process into the browser's window, so it needs DXMT plus
/// the cross-process presentation patches from `tools/wine-dxmt` and `tools/dxmt-patch`.
public enum SteamClient {
    public static let installerURL = URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!
    public static let backend: GraphicsBackend = .dxmt
    /// Chromium's sandbox doesn't work under Wine.
    public static let clientArguments = ["-no-cef-sandbox"]
    /// Steam starts itself at login through this Run value; `wineboot` would then start it without
    /// the backend's environment (a black window), and later launches just hand off to that copy.
    public static let autostartKey = #"HKCU\Software\Microsoft\Windows\CurrentVersion\Run"#

    /// Where `SteamSetup.exe` installs the client.
    public static func executable(in prefix: Prefix) -> URL {
        prefix.winePrefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/Steam.exe")
    }

    public static func isInstalled(in prefix: Prefix) -> Bool {
        FileManager.default.fileExists(atPath: executable(in: prefix).path)
    }
}

extension Launcher {
    /// Runs Steam's installer silently.
    public func steamInstallPlan(prefix: Prefix, installer: URL) throws -> LaunchPlan {
        try winePlan(prefix: prefix, arguments: [installer.path, "/S"], options: LaunchOptions())
    }

    /// Deletes Steam's autostart value (fails harmlessly when it's not there).
    public func steamRemoveAutostartPlan(prefix: Prefix) throws -> LaunchPlan {
        try winePlan(prefix: prefix, arguments: ["reg", "delete", SteamClient.autostartKey, "/v", "Steam", "/f"],
                     options: LaunchOptions())
    }

    /// Launches the Steam client on DXMT.
    public func steamClientPlan(prefix: Prefix, arguments: [String] = [], options: LaunchOptions = LaunchOptions()) throws -> LaunchPlan {
        var options = options
        options.backend = options.backend ?? SteamClient.backend
        options.engineArguments = false
        var plan = try gamePlan(prefix: prefix, program: SteamClient.executable(in: prefix),
                                arguments: SteamClient.clientArguments + arguments, options: options)
        // Steam.exe ships Steamworks itself; the steam_appid.txt advice is for games.
        plan.notes.removeAll { $0.contains("steam_appid.txt") }
        return plan
    }
}
