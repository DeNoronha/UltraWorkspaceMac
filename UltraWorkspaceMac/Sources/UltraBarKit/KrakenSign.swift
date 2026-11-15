import Foundation
import CryptoKit

/// Kraken's REST signature for private calls: `API-Sign` = base64(HMAC-SHA512(path + SHA256(nonce + postData),
/// base64-decoded secret)). Pure, so kitcheck can test it against the example in Kraken's documentation.
public enum KrakenSign {
    public static func sign(path: String, nonce: String, postData: String, secretBase64: String) -> String? {
        guard let secret = Data(base64Encoded: secretBase64.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let inner = Data(SHA256.hash(data: Data((nonce + postData).utf8)))
        var message = Data(path.utf8); message.append(inner)
        let mac = HMAC<SHA512>.authenticationCode(for: message, using: SymmetricKey(data: secret))
        return Data(mac).base64EncodedString()
    }
}
