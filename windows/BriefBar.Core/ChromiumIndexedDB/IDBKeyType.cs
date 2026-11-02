namespace BriefBar.Core.ChromiumIndexedDB;

/// What an IndexedDB key is, in the order Chromium sorts them: a null key, the smallest key, then numbers, dates, strings
/// (`Text`), binary keys and arrays.
public enum IDBKeyType
{
    Null,
    MinKey,
    Number,
    Date,
    Text,
    Binary,
    Array,
}
