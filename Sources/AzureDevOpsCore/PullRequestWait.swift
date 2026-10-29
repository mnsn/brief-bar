import BriefBarCore
import Foundation

/// Who a pull request waits on, and for what: you, other people or nobody. For one of your lists', by why it's where it
/// is; for one that isn't, from what it says itself, since BriefBar reads neither its policies nor its checks.
public enum PullRequestWait {
    /// "you, to complete !4091", "you, to fix !4088's build", "Priya Shah, to review your !4093": what waits on you
    /// always says what to do. Nil when it waits on nobody, such as once it's merged.
    public static func waiting(on snapshot: PRSnapshot, record: PRRecord?) -> ItemStory.Wait? {
        let number = "!\(snapshot.key.number)"
        let yours = snapshot.role == .author
        let whose = yours ? "your \(number)" : "\(snapshot.author)'s \(number)"
        func author(_ what: String) -> ItemStory.Wait {
            yours ? ItemStory.Wait(.you, "you, \(what)") : ItemStory.Wait(.people, "\(snapshot.author), \(what)")
        }
        switch snapshot.reason {
        case .mentioned, .replied, .commented: return ItemStory.Wait(.you, "you, to answer on \(number)")
        case .sentInChat: return ItemStory.Wait(.you, "you, to look at \(number)")
        case .reviewRequested, .reviewPending: return ItemStory.Wait(.you, "you, to review \(whose)")
        case .newCommits: return ItemStory.Wait(.you, "you, to review \(number)'s new commits")
        case .changesRequested: return author("to make the changes asked for on \(number)")
        case .rejected: return author("to look at \(number), which was rejected")
        case .buildFailed: return author("to fix \(number)'s build")
        case .checkFailed: return author("to fix \(number)'s checks")
        case .conflicts: return author("to resolve \(number)'s conflicts")
        case .buildExpired: return author("to queue \(number)'s build again")
        case .failedAfterMerge: return author("to fix the pipeline that failed after \(number) merged")
        case .readyToComplete: return author("to complete \(number)")
        case .requirementsPending: return author("to meet \(number)'s policies")
        case .waitingForReviewers:
            let waiting = (record?.pullRequest.reviewers ?? []).filter { !$0.isGroup && !$0.hasDeclined && $0.vote == .none }
            return ItemStory.Wait(
                .people, waiting.isEmpty ? "reviewers of \(whose)" : "\(PullRequestStory.names(waiting.map(\.person.name))), to review \(whose)"
            )
        case .checksRunning: return ItemStory.Wait(.people, "the checks on \(number)")
        case .waitingForAuthor: return ItemStory.Wait(.people, "\(snapshot.author), to update \(number)")
        case .waitingForApproval: return ItemStory.Wait(.people, "an approval for the pipeline after \(number) merged")
        case .answered, .autoComplete, .completed, .abandoned, .draft, .inactive, .youApproved, .declined: return nil
        }
    }

    /// Its author's while it's a draft, has conflicts or has changes asked for, and once every required reviewer
    /// approved, people and groups alike, without saying it's ready to complete; otherwise whoever hasn't voted. Nil once
    /// it's closed.
    /// - Parameter me: your identity in its organization, to say "you".
    public static func waiting(on pullRequest: PullRequest, me: String?) -> ItemStory.Wait? {
        guard pullRequest.status == .active else { return nil }
        let number = "!\(pullRequest.key.number)"
        let yours = PullRequestStory.isMe(pullRequest.author, me)
        let whose = yours ? "your \(number)" : "\(pullRequest.author.name)'s \(number)"
        func author(_ what: String) -> ItemStory.Wait {
            yours ? ItemStory.Wait(.you, "you, \(what)") : ItemStory.Wait(.people, "\(pullRequest.author.name), \(what)")
        }
        if pullRequest.isDraft { return author("to publish \(number), a draft") }
        if pullRequest.hasConflicts { return author("to resolve \(number)'s conflicts") }
        let reviewers = pullRequest.reviewers.filter { !$0.hasDeclined }
        let people = reviewers.filter { !$0.isGroup }
        if people.contains(where: \.vote.wantsChanges) { return author("to make the changes asked for on \(number)") }
        // Every required reviewer, even one who declined, as `PullRequestStory.standing` has it.
        if people.contains(where: \.vote.isApproval), pullRequest.reviewers.allSatisfy({ !$0.isRequired || $0.vote.isApproval }) {
            // Set to complete by itself, it waits on nobody, as in your lists.
            if pullRequest.autoComplete { return nil }
            return yours
                ? ItemStory.Wait(.you, "you, to complete \(number) once its checks pass")
                : ItemStory.Wait(.people, "\(pullRequest.author.name), author of \(number) (approved; its checks aren't read)")
        }
        let notVoted = people.filter { $0.vote == .none }
        if notVoted.contains(where: { PullRequestStory.isMe($0.person, me) }) { return ItemStory.Wait(.you, "you, to review \(whose)") }
        return ItemStory.Wait(
            .people, notVoted.isEmpty ? "reviewers of \(whose)" : "\(PullRequestStory.names(notVoted.map(\.person.name))), to review \(whose)"
        )
    }
}
