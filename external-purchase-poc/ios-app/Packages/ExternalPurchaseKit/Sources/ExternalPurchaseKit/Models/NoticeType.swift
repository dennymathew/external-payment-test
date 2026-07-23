import Foundation

/// Which flavor of Apple's mandated external-purchase disclosure to show.
/// Apple's real sheet copy differs slightly depending on whether this is the
/// app's first external link tap (acquisition) or a repeat purchase
/// (services) — the mock mirrors that distinction for visual fidelity.
public enum NoticeType: Equatable, Sendable {
    case acquisition
    case services
}

public enum NoticeResult: Equatable, Sendable {
    case `continue`
    case cancel
}
