using System.Security.Cryptography;
using System.Text;

namespace CcSessionsCoord.Worker.Infrastructure;

public static class EventIdHelper
{
    private static readonly Guid Namespace = new("8a4f6c2e-5e21-4d0c-9f1e-2026050700cc");

    public static Guid Compute(string source, string? sessionId, string? messageId, string memoryPath, string content)
    {
        var contentHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(content)));
        var name = string.Join('|', source, sessionId ?? string.Empty, messageId ?? string.Empty, memoryPath, contentHash);
        return UuidV5(Namespace, name);
    }

    private static Guid UuidV5(Guid ns, string name)
    {
        var nsBytes = ToBigEndianBytes(ns);
        var nameBytes = Encoding.UTF8.GetBytes(name);
        var input = new byte[nsBytes.Length + nameBytes.Length];
        Buffer.BlockCopy(nsBytes, 0, input, 0, nsBytes.Length);
        Buffer.BlockCopy(nameBytes, 0, input, nsBytes.Length, nameBytes.Length);

        var hash = SHA1.HashData(input);
        var bytes = new byte[16];
        Buffer.BlockCopy(hash, 0, bytes, 0, 16);

        bytes[6] = (byte)((bytes[6] & 0x0F) | 0x50);
        bytes[8] = (byte)((bytes[8] & 0x3F) | 0x80);

        return FromBigEndianBytes(bytes);
    }

    private static byte[] ToBigEndianBytes(Guid g)
    {
        var bytes = g.ToByteArray();
        if (BitConverter.IsLittleEndian)
        {
            Array.Reverse(bytes, 0, 4);
            Array.Reverse(bytes, 4, 2);
            Array.Reverse(bytes, 6, 2);
        }
        return bytes;
    }

    private static Guid FromBigEndianBytes(byte[] bytes)
    {
        if (BitConverter.IsLittleEndian)
        {
            Array.Reverse(bytes, 0, 4);
            Array.Reverse(bytes, 4, 2);
            Array.Reverse(bytes, 6, 2);
        }
        return new Guid(bytes);
    }
}
