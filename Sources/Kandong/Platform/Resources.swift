import Foundation

extension Bundle {
    /// SwiftPM's resource bundle is copied into Contents/Resources when packaging Kandong.app.
    static var kandongResources: Bundle {
        if let url = Bundle.main.url(forResource: "Kandong_Kandong", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }
}
