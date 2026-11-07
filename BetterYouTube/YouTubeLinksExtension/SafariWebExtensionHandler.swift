import SafariServices

// All routing happens through the app's registered URL scheme. No browsing data is sent to
// the native extension and no extra capabilities or app group are needed.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: nil)
    }
}
