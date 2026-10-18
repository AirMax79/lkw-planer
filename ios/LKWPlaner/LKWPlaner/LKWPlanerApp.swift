import SwiftUI

@main
struct LKWPlanerApp: App {
    var body: some Scene {
        WindowGroup {
            PlanerView()
                .ignoresSafeArea()
                .background(Color(red: 0.07, green: 0.09, blue: 0.10))
                .preferredColorScheme(nil)
        }
    }
}
