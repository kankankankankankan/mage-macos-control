import Foundation

/// Sends shortcut playback requests from the HID helper to the foreground app.
///
/// The helper must seize the MAGE HID device, but macOS Accessibility permission
/// is granted per process. Keeping CGEvent playback in the app avoids requiring
/// a separate permission entry for the nested helper executable.
public enum ShortcutRelay {
    public static let notificationName =
        Notification.Name("com.fiio.mage-controller.shortcut-request")

    public struct Request: Equatable {
        public let key: String
        public let modifiers: [String]

        public init(key: String, modifiers: [String]) {
            self.key = key
            self.modifiers = modifiers
        }

        public init?(notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let key = userInfo["key"] as? String else {
                return nil
            }
            let modifiers: [String]
            if let values = userInfo["modifiers"] as? [String] {
                modifiers = values
            } else if let values = userInfo["modifiers"] as? [NSString] {
                modifiers = values.map(String.init)
            } else {
                return nil
            }
            self.init(key: key, modifiers: modifiers)
        }

        public var userInfo: [String: Any] {
            ["key": key, "modifiers": modifiers]
        }
    }

    public static func post(key: String, modifiers: [String]) {
        let request = Request(key: key, modifiers: modifiers)
        DistributedNotificationCenter.default().post(
            name: notificationName,
            object: nil,
            userInfo: request.userInfo
        )
    }
}
