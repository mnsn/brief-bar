namespace BriefBar.Core;

/// What something a source shows means for you, the same for every source: a chat, a pull request, a Copilot session or
/// a pipeline. Each source maps its own groups onto these, so that an item in the bar can add up its sections' counts by
/// state: 2 unread chats and 3 pull requests that need you make 5. What a source doesn't count in the bar, such as a
/// pull request waiting on others or an idle session, has no state.
public enum ItemState
{
    /// Waits for you: an unread chat, a pull request with something new for you, a Copilot session's question, plan or
    /// permission prompt.
    NeedsYou,

    /// Something's wrong: a failing pull request, a failed pipeline, a Copilot session that stopped.
    Failing,

    /// At work: a Copilot session that's running, a pipeline that's running or queued.
    Running,

    /// Done or ready: a pull request that's ready to complete, a Copilot session that finished.
    Done,
}
