import Combine
import Foundation
import UserNotifications

/// 额度提醒的出口：把规则算出来的事件变成系统通知，并维护通知权限状态。
@MainActor final class AlertCenter: ObservableObject {
    static let shared = AlertCenter()

    @Published private(set) var permissionState: UNAuthorizationStatus = .notDetermined
    @Published private(set) var failureText: String?

    private let postbox = UNUserNotificationCenter.current()
    private let preferences = Preferences.shared
    private var rules = AlertRulebook()

    private init() {}

    func readPermissionState() async {
        let status = await postbox.notificationSettings()
        permissionState = status.authorizationStatus

        let blocked = status.authorizationStatus == .denied
        if blocked, preferences.alertsEnabled {
            preferences.alertsEnabled = false
            rules.rearm()
            failureText = Localization.text(.notifyPermissionOff)
        }
    }

    func requestPermission(_ enabled: Bool) async {
        guard enabled else {
            preferences.alertsEnabled = false
            rules.rearm()
            failureText = nil
            await readPermissionState()
            return
        }

        // 先清掉上一次的失败提示，避免系统授权弹窗还开着时界面先报错；
        // 开关状态要等授权真正通过才置真，失败时不能停在「已开启」。
        failureText = nil

        do {
            let granted = try await postbox.requestAuthorization(options: [.alert, .sound])
            preferences.alertsEnabled = granted
            rules.rearm()
            if granted {
                failureText = nil
            } else {
                failureText = Localization.text(.notifyNotGranted)
            }
            await readPermissionState()
        } catch {
            preferences.alertsEnabled = false
            rules.rearm()
            await readPermissionState()
            failureText = Self.explain(error)
        }
    }

    func ingest(report: QuotaReport, isPreviewing: Bool) {
        guard preferences.alertsEnabled, !isPreviewing else {
            rules.rearm()
            return
        }

        let events = rules.evaluate(
            report: report,
            warnBelowPercent: preferences.warnBelowPercent,
            announceResets: preferences.announceResets
        )

        for notice in events {
            let payload = UNMutableNotificationContent()
            payload.sound = .default

            switch notice {
            case let .runningLow(caption, availablePercent, resetsOn):
                payload.title = Localization.format(.notifyLowTitle, caption)
                payload.body = Localization.format(
                    .notifyLowBody, availablePercent, Self.clockLabel(for: resetsOn)
                )
            case let .cycleRenewed(caption, availablePercent):
                payload.title = Localization.format(.notifyResetTitle, caption)
                payload.body = Localization.format(.notifyResetBody, availablePercent)
            }

            let request = UNNotificationRequest(
                identifier: "quotadock-" + UUID().uuidString,
                content: payload,
                trigger: nil
            )
            postbox.add(request)
        }
    }

    func forgetBaseline() {
        rules.rearm()
    }

    /// 只要时分（例如「14:35」），按当前界面语言的习惯写
    private static func clockLabel(for date: Date) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened)
            .locale(Locale(identifier: Localization.current.localeID))
        return date.formatted(style)
    }

    /// 把授权失败翻成一句用户能照做的话
    private static func explain(_ error: Error) -> String {
        let failure = error as NSError
        let refusedByPolicy = failure.domain == UNErrorDomain
            && failure.code == UNError.Code.notificationsNotAllowed.rawValue
        if refusedByPolicy {
            return Localization.text(.notifyFailedByPolicy)
        }
        return Localization.text(.notifyFailed)
    }
}
