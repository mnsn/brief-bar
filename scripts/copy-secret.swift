// Puts standard input on the clipboard for scripts/make-release-keys.sh, for this Mac only, so that
// Universal Clipboard doesn't offer it to your other Apple devices, and marked as concealed and
// transient (nspasteboard.org) so that clipboard managers leave it out of their history. With --clear,
// it empties the clipboard instead.
//   … | swift scripts/copy-secret.swift
//   swift scripts/copy-secret.swift --clear
import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("copy-secret: \(message)\n".utf8))
    exit(1)
}

let pasteboard = NSPasteboard.general
if CommandLine.arguments.dropFirst().first == "--clear" {
    pasteboard.clearContents()
    exit(0)
}
let secret = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard !secret.isEmpty else { fail("nothing to copy") }

let item = NSPasteboardItem()
item.setString(secret, forType: .string)
for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
    item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
}
// Clears the clipboard like clearContents(), and keeps what's written next off Universal Clipboard.
_ = pasteboard.prepareForNewContents(with: .currentHostOnly)
guard pasteboard.writeObjects([item]) else { fail("couldn't write to the clipboard") }
