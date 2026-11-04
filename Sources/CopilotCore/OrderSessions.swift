import BriefBarCore

/// The Copilot app's sessions as an order sees them (`OrderSession`), for Pull Request Order: which session opened each
/// pull request, and the sessions that started and coordinate it, which group pull requests no order names.
public enum OrderSessions {
    /// Each session that opened or works on a pull request the app recorded, with the session that started it
    /// (`SessionMeta.parentSessionId`) and the one that coordinates it (`coordinatorSessionId`).
    ///
    /// A pull request goes with the sessions the app records opened it. When none did, it goes with those the app's
    /// providers link it to without saying how, as they do Azure DevOps pull requests. Never with a session that only
    /// started from it, such as to review it or fix its comments, which would put it with that session's work. Only what
    /// was read counts: without its links (`SessionMeta.links`), a session has no pull requests.
    /// - Parameter sessions: as the app lists them. One BriefBar can't name is left out, and so are a parent or
    ///   coordinator it can't name.
    public static func sessions(_ sessions: [SessionMeta]) -> [OrderSession] {
        var opened: Set<ItemRef> = []
        for session in sessions {
            for recorded in session.links?.pullRequests ?? [] where recorded.role == .opened {
                if let ref = recorded.ref { opened.insert(ref) }
            }
        }
        var listed: Set<ItemRef> = []
        return sessions.compactMap { session in
            guard let ref = ItemRef.session(session.id), listed.insert(ref).inserted else { return nil }
            let links = session.links?.pullRequests ?? []
            // A provider's link to the pull request it started from, whichever the app lists first, says no more.
            let startedFrom = Set(links.filter { $0.role == .startedFrom }.compactMap(\.ref))
            var pullRequests: [ItemRef] = []
            for recorded in links {
                guard let pullRequest = recorded.ref, !pullRequests.contains(pullRequest) else { continue }
                switch recorded.role {
                case .opened:
                    pullRequests.append(pullRequest)
                case nil:
                    if !opened.contains(pullRequest), !startedFrom.contains(pullRequest) { pullRequests.append(pullRequest) }
                case .startedFrom:
                    continue
                }
            }
            guard !pullRequests.isEmpty else { return nil }
            return OrderSession(
                ref: ref, parent: other(session.parentSessionId, than: ref),
                coordinator: other(session.coordinatorSessionId, than: ref), pullRequests: pullRequests
            )
        }
    }

    /// The session an ID names, unless it's the session itself.
    private static func other(_ id: String?, than ref: ItemRef) -> ItemRef? {
        guard let other = id.flatMap(ItemRef.session), other != ref else { return nil }
        return other
    }
}
