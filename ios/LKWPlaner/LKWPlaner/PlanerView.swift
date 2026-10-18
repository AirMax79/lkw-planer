import SwiftUI
import WebKit

/// Adresse von TruckHub. Updates auf GitHub landen automatisch in der App.
let planerURL = URL(string: "https://airmax79.github.io/lkw-planer/")!

/// Zeigt TruckHub in einer WebView und verbindet ihn mit GPS und Mitteilungen des iPhones.
struct PlanerView: UIViewRepresentable {
    func makeCoordinator() -> Bridge { Bridge() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // Keys und Einstellungen bleiben gespeichert
        config.allowsInlineMediaPlayback = true

        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: Bridge.injectedJS,
                                           injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))
        content.add(WeakMessageHandler(context.coordinator), name: "lkw")
        config.userContentController = content

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.07, green: 0.09, blue: 0.10, alpha: 1)
        webView.allowsBackForwardNavigationGestures = false
        if #available(iOS 16.4, *) { webView.isInspectable = true }

        context.coordinator.webView = webView
        webView.load(URLRequest(url: planerURL, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 20))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Verhindert, dass WebKit die Bridge dauerhaft festhält (Speicherleck).
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
