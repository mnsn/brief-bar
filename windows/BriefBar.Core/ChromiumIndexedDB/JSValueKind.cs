namespace BriefBar.Core.ChromiumIndexedDB;

/// What a JavaScript value is, as V8 serialized it.
public enum JSValueKind
{
    Undefined,
    Null,
    Bool,
    Number,
    BigInt,
    Text,
    Date,
    Array,
    PlainObject,
    Map,
    Set,
    RegExp,
    Bytes,
    Error,
}
