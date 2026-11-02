namespace BriefBar.Core;

/// Seals data so that only you can open it, as Windows' DPAPI does for your Windows account, for what BriefBar keeps
/// about your data, such as which Teams chats you marked read. The app's is Windows' own; tests use a stand-in.
public interface ISecretProtector
{
    byte[] Protect(byte[] data);

    /// The data `sealedData` holds; throws `System.Security.Cryptography.CryptographicException` when it can't be opened,
    /// as when it was sealed for someone else, or damaged.
    byte[] Unprotect(byte[] sealedData);
}
