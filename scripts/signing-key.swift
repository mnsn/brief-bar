// Imports and checks the private key of the certificate that builds are signed with, for
// scripts/make-signing-identity.sh and scripts/build-app.sh. macOS ties BriefBar's Full Disk Access
// to that certificate, so any app that may use the key without asking could sign itself as BriefBar
// and get the access. That's why the key trusts no app, not even codesign: codesign asks for your
// login password each time it signs.
//
//   swift scripts/signing-key.swift import <keychain> <name> [--trust <app>]
//       Imports a PKCS #12 identity: its password on the first line of standard input, then the
//       file in base64. --trust lets that app use the key without asking, for a keychain of its own
//       (CI) only.
//   swift scripts/signing-key.swift check <name> [keychain]
//       Fails with status 3 if any app may use the key of the certificate named <name> without
//       asking, and names them; with status 1 if there's no such certificate. It reads only the key's
//       access list, with user interaction off, so macOS never asks anything.
import Foundation
import Security

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("signing-key: \(message)\n".utf8))
    exit(status)
}

func openKeychain(_ path: String) -> SecKeychain {
    var keychain: SecKeychain?
    guard SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain else { fail("can't open \(path)") }
    return keychain
}

func importIdentity(into path: String, name: String, trusting apps: [String]) -> Never {
    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    let lines = input.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    guard lines.count == 2, !lines[0].isEmpty,
          let data = Data(base64Encoded: String(lines[1]), options: .ignoreUnknownCharacters), !data.isEmpty
    else { fail("expected a password line, then a base64 PKCS #12, on standard input") }
    let passphrase = String(lines[0]) as CFString

    let trusted = apps.map { app -> SecTrustedApplication in
        var trustedApp: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(app, &trustedApp) == errSecSuccess, let trustedApp else {
            fail("can't trust \(app)")
        }
        return trustedApp
    }
    // An empty list trusts no app at all. Without an access object, the key would trust the app that
    // imports it.
    var access: SecAccess?
    guard SecAccessCreate(name as CFString, trusted as CFArray, &access) == errSecSuccess, let access else {
        fail("can't create the key's access list")
    }

    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    parameters.passphrase = Unmanaged<AnyObject>.passUnretained(passphrase)
    parameters.accessRef = Unmanaged.passUnretained(access)
    var format = SecExternalFormat.formatPKCS12
    var type = SecExternalItemType.itemTypeAggregate
    let keychain = openKeychain(path)
    let status = withExtendedLifetime((passphrase, access)) {
        SecItemImport(data as CFData, nil, &format, &type, [], &parameters, keychain, nil)
    }
    guard status == errSecSuccess else { fail("the import failed (\(status))") }
    exit(0)
}

func checkKey(named name: String, in path: String?) -> Never {
    // Anything that would need a prompt fails instead.
    SecKeychainSetUserInteractionAllowed(false)
    var query: [String: Any] = [
        kSecClass as String: kSecClassIdentity,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnRef as String: true,
    ]
    if let path {
        query[kSecMatchSearchList as String] = [openKeychain(path)]
    }
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    let identities = status == errSecSuccess ? (result as? [SecIdentity] ?? []) : []

    var found = false
    var openTo: Set<String> = []
    for identity in identities {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate,
              SecCertificateCopySubjectSummary(certificate) as String? == name
        else { continue }
        found = true
        var key: SecKey?
        var access: SecAccess?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key,
              SecKeychainItemCopyAccess(unsafeBitCast(key, to: SecKeychainItem.self), &access) == errSecSuccess,
              let access
        else { fail("can't read who may use the key of \"\(name)\"", status: 2) }
        let entries = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationSign) as? [SecACL] ?? []
        for entry in entries {
            var apps: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(entry, &apps, &description, &prompt) == errSecSuccess else {
                fail("can't read who may use the key of \"\(name)\"", status: 2)
            }
            // No list at all means any app.
            guard let apps = apps as? [SecTrustedApplication] else {
                openTo.insert("any app")
                continue
            }
            for app in apps {
                var data: CFData?
                SecTrustedApplicationCopyData(app, &data)
                let path = data.map { String(decoding: $0 as Data, as: UTF8.self) }?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                openTo.insert(path ?? "an app")
            }
        }
    }
    guard found else { fail("there's no certificate named \"\(name)\"") }
    guard openTo.isEmpty else {
        fail("these may use the key of \"\(name)\" without asking: \(openTo.sorted().joined(separator: ", "))", status: 3)
    }
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "import" where arguments.count == 3:
    importIdentity(into: arguments[1], name: arguments[2], trusting: [])
case "import" where arguments.count == 5 && arguments[3] == "--trust":
    importIdentity(into: arguments[1], name: arguments[2], trusting: [arguments[4]])
case "check" where arguments.count == 2 || arguments.count == 3:
    checkKey(named: arguments[1], in: arguments.count == 3 ? arguments[2] : nil)
default:
    fail("usage: signing-key.swift import <keychain> <name> [--trust <app>] | check <name> [keychain]", status: 64)
}
