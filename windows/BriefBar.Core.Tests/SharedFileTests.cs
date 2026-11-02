using BriefBar.Core.Tests.Copilot;

namespace BriefBar.Core.Tests;

public sealed class SharedFileTests
{
    /// The whole file when it's no larger than the limit, and nothing when it's larger, missing, or a folder.
    [Fact]
    public void ReadsAWholeFileUpToItsLimit()
    {
        using var folder = new TemporaryFolder();
        var path = folder.Combine("workspace.yaml");
        File.WriteAllBytes(path: path, bytes: [1, 2, 3, 4, 5]);

        Assert.Equal(expected: [1, 2, 3, 4, 5], actual: SharedFile.ReadAll(path: path, maxBytes: 5));
        Assert.Null(@object: SharedFile.ReadAll(path: path, maxBytes: 4));
        Assert.Null(@object: SharedFile.ReadAll(path: folder.Combine("missing.yaml"), maxBytes: 5));
        Assert.Null(@object: SharedFile.ReadAll(path: folder.Path, maxBytes: 5));
    }

    /// A file that another app writes to as it's read, which sharing allows, can be longer each time its length is asked:
    /// it's asked once, so what's read is never past the limit.
    [Fact]
    public void AsksForTheLengthOnce()
    {
        using var stream = new GrowingStream(data: [1, 2, 3, 4, 5, 6, 7, 8], firstLength: 4);

        Assert.Equal(expected: [1, 2, 3, 4], actual: SharedFile.ReadAll(stream: stream, maxBytes: 4));
    }

    /// A stream that's longer after its length is first asked, as a file being written to is.
    sealed class GrowingStream(byte[] data, long firstLength) : MemoryStream(buffer: data)
    {
        bool asked;

        public override long Length
        {
            get
            {
                var length = asked ? base.Length : firstLength;
                asked = true;
                return length;
            }
        }
    }
}
