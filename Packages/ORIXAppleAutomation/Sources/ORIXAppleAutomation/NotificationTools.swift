// ORIX OS Automation
// File: Packages/ORIXAppleAutomation/Sources/ORIXAppleAutomation/NotificationTools.swift
// Description: notifications.post through UNUserNotificationCenter, and the bridge the app uses to register the Approve / Deny / Open category and receive the user's answer.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import Foundation
import ORIXCore
@preconcurrency import UserNotifications

/// What the user did with an ORIX notification.
public struct NotificationResponse: Sendable, Hashable {
    public enum Action: String, Sendable, Codable { case approve, deny, open, dismissed, other }
    public var action: Action
    public var actionIdentifier: String
    public var notificationID: String
    public var runID: String?
    public var approvalID: String?

    public init(action: Action, actionIdentifier: String, notificationID: String, runID: String? = nil, approvalID: String? = nil) {
        self.action = action; self.actionIdentifier = actionIdentifier; self.notificationID = notificationID; self.runID = runID; self.approvalID = approvalID
    }
}

/// Registers the approval category and forwards notification responses to the app.
/// An approval given from a notification is still only an *answer to the app*: the app's `ApprovalBroker` decides what it means.
public final class NotificationCenterBridge: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let approvalCategoryID = "orix.approval"
    public static let infoCategoryID = "orix.info"
    public static let approveActionID = "orix.approve"
    public static let denyActionID = "orix.deny"
    public static let openActionID = "orix.open"
    public static let runIDKey = "runID"
    public static let approvalIDKey = "approvalID"

    private let onResponse: @Sendable (NotificationResponse) -> Void

    public init(onResponse: @escaping @Sendable (NotificationResponse) -> Void) {
        self.onResponse = onResponse
    }

    /// Category definitions. Approve asks for device authentication; Open brings the app forward.
    public static func categories(approveTitle: String = "Approve", denyTitle: String = "Deny", openTitle: String = "Open") -> Set<UNNotificationCategory> {
        let approve = UNNotificationAction(identifier: approveActionID, title: approveTitle, options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: denyActionID, title: denyTitle, options: [.destructive])
        let open = UNNotificationAction(identifier: openActionID, title: openTitle, options: [.foreground])
        return [
            UNNotificationCategory(identifier: approvalCategoryID, actions: [approve, deny, open], intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: infoCategoryID, actions: [open], intentIdentifiers: [], options: []),
        ]
    }

    /// Installs the categories and becomes the notification centre's delegate. Throws `ToolError.unsupported` without an app bundle.
    public func register(approveTitle: String = "Approve", denyTitle: String = "Deny", openTitle: String = "Open") throws {
        guard MacPermissions.hasAppBundle else { throw ToolError.unsupported(NotificationsPostTool.noBundleReason) }
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories(Self.categories(approveTitle: approveTitle, denyTitle: denyTitle, openTitle: openTitle))
        center.delegate = self
    }

    /// Pure mapping from an action identifier and userInfo to a response (used by the delegate, testable without a bundle).
    public static func interpret(actionIdentifier: String, notificationID: String, userInfo: [AnyHashable: Any]) -> NotificationResponse {
        let action: NotificationResponse.Action
        switch actionIdentifier {
        case approveActionID: action = .approve
        case denyActionID: action = .deny
        case openActionID, UNNotificationDefaultActionIdentifier: action = .open
        case UNNotificationDismissActionIdentifier: action = .dismissed
        default: action = .other
        }
        return NotificationResponse(action: action, actionIdentifier: actionIdentifier, notificationID: notificationID,
                                    runID: userInfo[runIDKey] as? String, approvalID: userInfo[approvalIDKey] as? String)
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        onResponse(Self.interpret(actionIdentifier: response.actionIdentifier, notificationID: request.identifier, userInfo: request.content.userInfo))
        completionHandler()
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

public struct NotificationsPostTool: ORIXTool {
    /// The exact reason returned when the process is not an application bundle (command-line tools, `swift test`).
    public static let noBundleReason = "Notifications need an application bundle: this process has no bundle identifier."

    public init() {}

    public var manifest: ToolManifest {
        ToolManifest(identifier: "notifications.post", name: "Post a notification",
                     summary: "Shows a local notification from ORIX OS Automation. With an approvalID it carries Approve / Deny / Open buttons; the answer goes to the app, not to the agent.",
                     family: "notifications",
                     inputSchema: .object(["title": .string("Notification title."), "body": .string("Notification text."),
                                           "subtitle": .string(), "runID": .string("Run the notification belongs to."),
                                           "approvalID": .string("Approval request the notification asks about."),
                                           "sound": .boolean("Play the default sound (default true).")], required: ["title", "body"]),
                     outputSchema: outputObject(["posted": .boolean(), "id": .string()], required: ["posted", "id"]),
                     sideEffect: .write, defaultTier: .reversibleWrite, macPermissions: [.notifications], defaultTimeoutSeconds: 15, supportsDryRun: true)
    }

    public func requirements(for input: ToolInput, context: ToolExecutionContext) throws -> ToolRequirements {
        let title = try input.nonEmptyString("title")
        _ = try input.string("body")
        return ToolRequirements(capabilities: [.notify], tier: .reversibleWrite, summary: "Show the notification \"\(title.prefix(80))\"")
    }

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolResult {
        let title = try input.nonEmptyString("title"), body = try input.string("body")
        guard MacPermissions.hasAppBundle else { throw ToolError.unsupported(Self.noBundleReason) }
        let id = "orix-\(context.callID)"
        if input.dryRun { return .simulated(["posted": false, "id": .string(id)], summary: "Would show the notification \"\(title.prefix(80))\"") }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else {
            throw ToolError.tccBlocked(.notifications, (status == .notDetermined ? "Notifications have not been authorised for this app yet. " : "Notifications are turned off for this app. ")
                                       + MacPermissions.howToEnable(.notifications))
        }
        let content = UNMutableNotificationContent()
        content.title = String(title.prefix(200))
        content.body = String(body.prefix(2000))
        if let subtitle = input.optionalString("subtitle") { content.subtitle = String(subtitle.prefix(200)) }
        if input.bool("sound", default: true) { content.sound = .default }
        var info: [String: String] = [NotificationCenterBridge.runIDKey: input.optionalString("runID") ?? context.runID]
        if let approval = input.optionalString("approvalID") {
            info[NotificationCenterBridge.approvalIDKey] = approval
            content.categoryIdentifier = NotificationCenterBridge.approvalCategoryID
            content.interruptionLevel = .timeSensitive
        } else {
            content.categoryIdentifier = NotificationCenterBridge.infoCategoryID
        }
        content.userInfo = info
        do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) }
        catch { throw ToolError.io("macOS refused the notification: \(error.localizedDescription)") }
        return .success(["posted": true, "id": .string(id), "category": .string(content.categoryIdentifier)], summary: "Posted the notification \"\(title.prefix(80))\"")
    }
}
