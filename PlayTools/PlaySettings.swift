import Foundation
import UIKit

let settings = PlaySettings.shared

enum ContentScaleCompensationMode: Int, Codable, Hashable {
    case disabled = 0
    case automatic = 1
    case custom = 2

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Accept temporary mode values written by earlier development builds.
        switch try container.decode(Int.self) {
        case Self.automatic.rawValue:
            self = .automatic
        case Self.custom.rawValue, 4:
            self = .custom
        case Self.disabled.rawValue, 3:
            self = .disabled
        default:
            self = .disabled
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

@objc public final class PlaySettings: NSObject {
    @objc public static let shared = PlaySettings()

    let bundleIdentifier = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
    let settingsUrl: URL
    var settingsData: AppSettingsData

    override init() {
        settingsUrl = URL(fileURLWithPath: "/Users/\(NSUserName())/Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("App Settings")
            .appendingPathComponent("\(bundleIdentifier).plist")
        do {
            let data = try Data(contentsOf: settingsUrl)
            settingsData = try PropertyListDecoder().decode(AppSettingsData.self, from: data)
        } catch {
            settingsData = AppSettingsData()
            print("[PlayTools] PlaySettings decode failed.\n%@")
        }
    }

    lazy var discordActivity = settingsData.discordActivity

    lazy var keymapping = settingsData.keymapping

    lazy var notch = settingsData.notch

    lazy var sensitivity = settingsData.sensitivity / 100

    @objc lazy var bypass = settingsData.bypass

    @objc lazy var windowSizeHeight = CGFloat(settingsData.compensatedWindowHeight)

    @objc lazy var windowSizeWidth = CGFloat(settingsData.compensatedWindowWidth)

    @objc lazy var inverseScreenValues = settingsData.inverseScreenValues

    @objc lazy var adaptiveDisplay = settingsData.resolution == 0 ? false : true

    @objc lazy var resizableWindow = settingsData.resolution == 6 ? true : false

    @objc lazy var deviceModel = settingsData.iosDeviceModel as NSString

    @objc lazy var oemID: NSString = {
        switch settingsData.iosDeviceModel {
        case "iPad6,7":
            return "J98aAP"
        case "iPad8,6":
            return "J320xAP"
        case "iPad13,8":
            return "J522AP"
        case "iPad14,5":
            return "A2436"
        case "iPad16,6":
            return "A2925"
        case "iPhone14,3":
            return "A2645"
        case "iPhone15,3":
            return "A2896"
        case "iPhone16,2":
            return "A2849"
        case "iPhone17,2":
            return "A3084"
        default:
            return "J320xAP"
        }
    }()

    @objc lazy var playChain = settingsData.playChain

    @objc lazy var playChainDebugging = settingsData.playChainDebugging

    @objc lazy var maaTools = settingsData.maaTools

    @objc lazy var maaToolsPort = settingsData.maaToolsPort

    @objc lazy var windowFixMethod = settingsData.windowFixMethod

    @objc lazy var macOSNativeScaling = settingsData.usesMacOSNativeScaling

    @objc lazy var customScaler = settingsData.effectiveCustomScaler

    @objc lazy var rootWorkDir = settingsData.rootWorkDir

    @objc lazy var noKMOnInput = settingsData.noKMOnInput

    @objc lazy var enableScrollWheel = settingsData.enableScrollWheel

    @objc lazy var hideTitleBar = settingsData.hideTitleBar

    @objc lazy var floatingWindow = settingsData.floatingWindow

    @objc lazy var displayRotation = settingsData.displayRotation

    @objc lazy var checkMicPermissionSync = settingsData.checkMicPermissionSync

    @objc lazy var limitMotionUpdateFrequency = settingsData.limitMotionUpdateFrequency

    @objc lazy var disableBuiltinMouse = settingsData.disableBuiltinMouse

    @objc lazy var blockSleepSpamming = settingsData.blockSleepSpamming

    @objc lazy var ignoreUnityKeyboardInitializationError = settingsData.ignoreUnityKeyboardInitializationError
}

struct AppSettingsData: Codable {
    var keymapping = true
    var sensitivity: Float = 50

    var disableTimeout = false
    var iosDeviceModel = "iPad13,8"
    var windowWidth = 1920
    var windowHeight = 1080
    var customScaler = 2.0
    var resolution = 2
    var targetWindowWidth: Int?
    var targetWindowHeight: Int?
    var contentScaleCompensationMode: ContentScaleCompensationMode?
    var contentScaleCompensationValue: Double?
    var macOSNativeScaling: Bool?
    var aspectRatio = 1
    var displayRotation = 0
    var notch = false
    var bypass = false
    var discordActivity = DiscordActivity()
    var version = "2.0.0"
    var playChain = false
    var playChainDebugging = false
    var inverseScreenValues = false
    var windowFixMethod = 0
    var maaTools = false
    var maaToolsPort = 1717
    var rootWorkDir = true
    var noKMOnInput = false
    var enableScrollWheel = true
    var hideTitleBar = false
    var floatingWindow = false
    var checkMicPermissionSync = false
    var limitMotionUpdateFrequency = false
    var disableBuiltinMouse = false
    var resizableAspectRatioType = 0
    var resizableAspectRatioWidth = 0
    var resizableAspectRatioHeight = 0
    var blockSleepSpamming = false
    var ignoreUnityKeyboardInitializationError = false

    var usesMacOSNativeScaling: Bool {
        macOSNativeScaling == true
    }

    var compensatedWindowWidth: Int {
        if usesMacOSNativeScaling {
            return targetWindowWidth ?? windowWidth
        }
        return compensatedResolution(targetWindowWidth ?? windowWidth)
    }

    var compensatedWindowHeight: Int {
        if usesMacOSNativeScaling {
            return targetWindowHeight ?? windowHeight
        }
        return compensatedResolution(targetWindowHeight ?? windowHeight)
    }

    var effectiveCustomScaler: Double {
        if usesMacOSNativeScaling {
            return 1.0
        }
        guard contentScaleCompensationActive else {
            return customScaler
        }

        let targetWidth = targetWindowWidth ?? windowWidth
        let internalWidth = compensatedWindowWidth
        guard internalWidth > 0 else {
            return customScaler
        }

        return Double(targetWidth) / Double(internalWidth)
    }

    private func compensatedResolution(_ value: Int) -> Int {
        let scale = contentScaleCompensationScale
        return max(1, Int((Double(value) / scale).rounded(.up)))
    }

    private var contentScaleCompensationActive: Bool {
        !usesMacOSNativeScaling &&
            resolution != 0 &&
            resolution != 6 &&
            (contentScaleCompensationMode ?? .disabled) != .disabled
    }

    private var contentScaleCompensationScale: Double {
        guard contentScaleCompensationActive else {
            return 1.0
        }

        switch contentScaleCompensationMode ?? .disabled {
        case .automatic:
            return 0.77
        case .custom:
            return max(contentScaleCompensationValue ?? 0.77, 0.01)
        case .disabled:
            return 1.0
        }
    }
}
