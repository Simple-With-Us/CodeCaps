import Foundation
import QuotaCore

/// One alert occurrence on its way to a delivery channel.
///
/// Every event carries its stable `UsageAlertKind` identifier, so channels
/// select by kind — never by which producer emitted the event — and a
/// future per-kind channel opt-in needs no producer changes.
public struct CodeCapsAlertEvent: Equatable, Sendable {
    public let kind: UsageAlertKind
    public let title: String
    public let body: String
    public let identifier: String
    public let occurredAt: Date

    public init(kind: UsageAlertKind, title: String, body: String,
                identifier: String, occurredAt: Date) {
        self.kind = kind
        self.title = title
        self.body = body
        self.identifier = identifier
        self.occurredAt = occurredAt
    }
}

/// A delivery channel for app-level alert events.
///
/// The seam is deliberately at the app level, not inside any plugin: a new
/// channel registers once with the dispatcher and receives every producer's
/// events.  The planned Twilio SMS channel is the expected second channel —
/// app-level, selecting a deliberately small set of kinds — and it slots in
/// here without reworking any monitor.
@MainActor
public protocol CodeCapsAlertChannel: AnyObject {
    func deliver(_ event: CodeCapsAlertEvent)
}

/// App-level fan-out for alert events.  Producers emit here, never to a
/// channel directly.
@MainActor
public final class CodeCapsAlertDispatcher {
    private var channels: [CodeCapsAlertChannel] = []

    public init() {}

    public func register(_ channel: CodeCapsAlertChannel) {
        channels.append(channel)
    }

    public func emit(_ event: CodeCapsAlertEvent) {
        for channel in channels { channel.deliver(event) }
    }
}

/// The only channel today: CodeCaps' own alert surface, through the same
/// per-kind preferences and delivery path as every other usage alert.
@MainActor
public final class LocalAlertChannel: CodeCapsAlertChannel {
    private weak var manager: ResetAlarmManager?

    public init(manager: ResetAlarmManager) {
        self.manager = manager
    }

    public func deliver(_ event: CodeCapsAlertEvent) {
        manager?.deliverUsageAlert(kind: event.kind, title: event.title,
                                   body: event.body, identifier: event.identifier)
    }
}
