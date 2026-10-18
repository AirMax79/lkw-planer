import Foundation
import UIKit
import WebKit
import CoreLocation
import UserNotifications

/// Verbindet TruckHub (Web) mit dem iPhone:
/// - GPS über CoreLocation, auch im Hintergrund (Lenkzeit zählt bei gesperrtem Display weiter)
/// - Mitteilungen (Restlenkzeit, Pause erfüllt, Blitzer, Umfahrung, Parkplätze)
/// - Display bleibt an, solange die Live-Navigation läuft
final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate,
                    CLLocationManagerDelegate, UNUserNotificationCenterDelegate {

    weak var webView: WKWebView?

    // GPS
    private let location = CLLocationManager()
    private var geoActive = false
    private var lastLocation: CLLocation?
    /// Summe der Sekunden, in denen sich der LKW bewegt hat (misst das iPhone selbst, auch im Hintergrund)
    private var drivenSeconds: Double = 0

    // Lenkzeit-Stand, den die Web-App meldet
    private var live = false
    private var stateDrive: Double = 0
    private var stateAt: Double = 0
    private var stateBlock = -1
    private var statePause = false
    private var stateSplit = false
    private var warned = Set<Int>()

    private var triedFallback = false

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.activityType = .automotiveNavigation
        location.distanceFilter = 5
        location.pausesLocationUpdatesAutomatically = false
        UNUserNotificationCenter.current().delegate = self
        requestNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Skript, das vor dem Planer geladen wird

    /// Ersetzt navigator.geolocation durch das GPS des iPhones und stellt window.lkwNative bereit.
    static let injectedJS = #"""
    (function () {
      if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.lkw) return;
      var H = window.webkit.messageHandlers.lkw;
      var watchers = {}, nextId = 1, last = null;
      function toPos(p) {
        var pos = { coords: { latitude: p.lat, longitude: p.lng, accuracy: p.acc, altitude: null, altitudeAccuracy: null,
                              heading: (p.heading >= 0 ? p.heading : null), speed: (p.speed >= 0 ? p.speed : null) },
                    timestamp: p.ts };
        pos._drv = p.drv;
        return pos;
      }
      window.__lkwFix = function (p) {
        last = p; var pos = toPos(p);
        Object.keys(watchers).forEach(function (k) { try { watchers[k].s(pos); } catch (e) {} });
      };
      window.__lkwErr = function (code, msg) {
        Object.keys(watchers).forEach(function (k) { var w = watchers[k]; if (w.e) { try { w.e({ code: code, message: msg }); } catch (e) {} }
          if (w.once) geo.clearWatch(k); });
      };
      var geo = {
        watchPosition: function (s, e) { var id = nextId++; watchers[id] = { s: s, e: e }; H.postMessage({ type: "geo", on: true }); return id; },
        clearWatch: function (id) { delete watchers[id]; if (!Object.keys(watchers).length) H.postMessage({ type: "geo", on: false }); },
        getCurrentPosition: function (s, e, o) {
          if (last && Date.now() - last.ts < ((o && o.maximumAge) || 60000)) { s(toPos(last)); return; }
          var id = nextId++, done = false;
          var t = setTimeout(function () { if (done) return; done = true; geo.clearWatch(id); if (e) try { e({ code: 3, message: "Timeout" }); } catch (x) {} }, (o && o.timeout) || 20000);
          watchers[id] = { once: true, s: function (p) { if (done) return; done = true; clearTimeout(t); geo.clearWatch(id); s(p); },
                           e: function (err) { if (done) return; done = true; clearTimeout(t); if (e) e(err); } };
          H.postMessage({ type: "geo", on: true });
        }
      };
      try { Object.defineProperty(navigator, "geolocation", { value: geo, configurable: true }); } catch (e) {}
      window.__lkwNative = true;
      window.lkwNative = { post: function (m) { H.postMessage(m); } };
    })();
    """#

    // MARK: - Nachrichten aus der Web-App

    private func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
    private func flag(_ v: Any?) -> Bool { (v as? NSNumber)?.boolValue ?? false }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "geo":
            if flag(m["on"]) { startLocation() } else { stopLocation() }
        case "live":
            live = flag(m["on"])
            UIApplication.shared.isIdleTimerDisabled = live
            if live { requestNotifications() } else { warned.removeAll() }
        case "state":
            stateDrive = num(m["driveSec"])
            stateAt = drivenSeconds
            let block = Int(num(m["block"]))
            if block != stateBlock { stateBlock = block; warned.removeAll() }
            statePause = flag(m["pause"])
            stateSplit = flag(m["split"])
            live = flag(m["live"])
            UIApplication.shared.isIdleTimerDisabled = live
        case "notify":
            schedule(id: (m["id"] as? String) ?? UUID().uuidString,
                     title: (m["title"] as? String) ?? "TruckHub",
                     body: (m["body"] as? String) ?? "",
                     after: num(m["after"]))
        case "cancel":
            if let ids = m["ids"] as? [String] {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            }
        default:
            break
        }
    }

    // MARK: - GPS

    private func startLocation() {
        geoActive = true
        lastLocation = nil
        switch location.authorizationStatus {
        case .notDetermined:
            location.requestWhenInUseAuthorization()
        case .denied, .restricted:
            sendError(code: 1, message: "Ortung nicht erlaubt")
            return
        default:
            break
        }
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        location.startUpdatingLocation()
    }

    private func stopLocation() {
        geoActive = false
        location.stopUpdatingLocation()
        location.allowsBackgroundLocationUpdates = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard geoActive else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation()
        case .denied, .restricted:
            sendError(code: 1, message: "Ortung nicht erlaubt")
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations {
            guard loc.horizontalAccuracy >= 0 else { continue }
            if let prev = lastLocation {
                let dt = min(60, max(0, loc.timestamp.timeIntervalSince(prev.timestamp)))
                var kmh = loc.speed >= 0 ? loc.speed * 3.6 : (dt > 0 ? loc.distance(from: prev) / dt * 3.6 : 0)
                if !kmh.isFinite { kmh = 0 }
                // Bewegung zählt als Lenkzeit – Stillstand (z. B. Stau) nicht
                if kmh > 4 && loc.horizontalAccuracy < 80 { drivenSeconds += dt }
            }
            lastLocation = loc
        }
        guard let loc = lastLocation else { return }
        checkDrivingTime()
        sendFix(loc)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let e = error as? CLError, e.code == .locationUnknown { return }   // kurzzeitig kein Signal
        if let e = error as? CLError, e.code == .denied { sendError(code: 1, message: "Ortung nicht erlaubt"); return }
        sendError(code: 2, message: error.localizedDescription)
    }

    private func sendFix(_ loc: CLLocation) {
        // Im Hintergrund schläft die Web-Ansicht – dann zählt nur das iPhone mit
        guard UIApplication.shared.applicationState == .active else { return }
        let fix: [String: Any] = [
            "lat": loc.coordinate.latitude,
            "lng": loc.coordinate.longitude,
            "acc": loc.horizontalAccuracy,
            "speed": loc.speed.isFinite ? loc.speed : -1,
            "heading": loc.course.isFinite ? loc.course : -1,
            "ts": loc.timestamp.timeIntervalSince1970 * 1000,
            "drv": drivenSeconds
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: fix),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__lkwFix && window.__lkwFix(\(json))", completionHandler: nil)
    }

    private func sendError(code: Int, message: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [message]),
              let arr = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__lkwErr && window.__lkwErr(\(code), \(arr)[0])", completionHandler: nil)
    }

    @objc private func appBecameActive() {
        if live { UIApplication.shared.isIdleTimerDisabled = true }
        if geoActive, let loc = lastLocation, Date().timeIntervalSince(loc.timestamp) < 10 { sendFix(loc) }
    }

    // MARK: - Lenkzeit-Warnungen (funktionieren auch bei gesperrtem iPhone)

    private var pauseDriveWarned = false
    private func checkDrivingTime() {
        guard live else { return }
        let movedSincePause = drivenSeconds - stateAt
        if statePause {
            // „Pause“ läuft laut App, aber der LKW bewegt sich seit Minuten → Fahrer hat „Pause beenden“ vergessen
            if movedSincePause > 180 && !pauseDriveWarned {
                pauseDriveWarned = true
                schedule(id: "pausedrive", title: "⏸ Pause läuft noch – aber du fährst",
                         body: "Bitte in TruckHub „Pause beenden“ tippen, damit die Lenkzeit stimmt.", after: 0)
            }
            if movedSincePause <= 180 { return }
        } else { pauseDriveWarned = false }
        let rest = 270 * 60 - (stateDrive + (drivenSeconds - stateAt))
        let steps: [(Int, String, String)] = [
            (0, "⏱ 4,5 h Lenkzeit erreicht",
             stateSplit ? "Jetzt mindestens 30 min Pause (2. Teil)." : "Jetzt 45 min Pause (oder 15 + 30 min)."),
            (15, "⏱ Noch 15 min Lenkzeit", "Bitte bald für die Pause anhalten."),
            (30, "⏱ Noch 30 min Lenkzeit", "Zeit, einen Parkplatz für die Pause zu suchen.")
        ]
        var fired = false
        for (minutes, title, body) in steps {
            let limit = Double(minutes * 60)
            if rest <= limit {
                if !warned.contains(minutes) {
                    warned.insert(minutes)
                    if !fired { schedule(id: "drive\(minutes)", title: title, body: body, after: 0); fired = true }
                }
            } else if rest > limit + 300 {
                warned.remove(minutes)
            }
        }
    }

    // MARK: - Mitteilungen

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func schedule(id: String, title: String, body: String, after: Double) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger: UNNotificationTrigger? = after > 0.5
            ? UNTimeIntervalNotificationTrigger(timeInterval: after, repeats: false)
            : nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    /// Mitteilungen auch anzeigen, während die App offen ist
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // MARK: - Links, Fehler, Offline

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme ?? ""
        let own = url.host == planerURL.host || url.isFileURL || ["about", "blob", "data"].contains(scheme)
        if ["tel", "mailto", "sms", "maps"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        if !own && navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url)       // z. B. Apple Karten, TomTom-Seiten → außerhalb der App
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// Links mit target="_blank" und window.open → in Safari bzw. Apple Karten öffnen
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { UIApplication.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        loadOfflineCopy()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    /// Ohne Internet: mitgelieferte Kopie des Planers öffnen (Karte und Routing brauchen trotzdem Netz)
    private func loadOfflineCopy() {
        guard !triedFallback, let wv = webView,
              let file = Bundle.main.url(forResource: "index", withExtension: "html") else { return }
        triedFallback = true
        wv.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    }
}
