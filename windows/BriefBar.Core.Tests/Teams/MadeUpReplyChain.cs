using BriefBar.Core.ChromiumIndexedDB;
using BriefBar.Core.Tests.ChromiumIndexedDB;

namespace BriefBar.Core.Tests.Teams;

/// A made-up reply chain in Teams' message cache, keyed `[conversation, reply chain]`: in a chat, each message is one.
internal sealed record MadeUpReplyChain(string ConversationId, IReadOnlyList<MadeUpMessage> Messages)
{
    public IDBKey Key => IDBKey.FromArray(items:
    [
        IDBKey.FromString(text: ConversationId),
        IDBKey.FromString(text: TeamsData.Digits(value: Messages[0].Id)),
    ]);

    public void Write(V8Writer writer)
    {
        ArgumentNullException.ThrowIfNull(argument: writer);
        writer.Members(properties:
        [
            ("conversationId", value => value.Text(text: ConversationId)),
            ("replyChainId", value => value.Text(text: TeamsData.Digits(value: Messages[0].Id))),
            ("messageMap", value => value.Members(properties:
            [
                .. Messages.Select(selector: message =>
                    (TeamsData.Digits(value: message.Id), (Action<V8Writer>)(each => message.WriteInReplyChain(writer: each, conversationId: ConversationId)))),
            ])),
        ]);
    }
}
