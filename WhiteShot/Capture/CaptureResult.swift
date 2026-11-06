import CoreGraphics
import Foundation

/// A finished capture on its way to the user's chosen destinations.
struct CaptureResult {
    var image: CGImage
    /// Backing scale of the display it came from (2 on Retina).
    var scale: CGFloat
    /// Window title or app name, available to the `${title}` filename variable.
    var title: String = ""
    var date = Date()
    /// Where on screen the picture was taken from (screen coordinates, origin bottom-left), if it was one region or window.
    var sourceFrame: CGRect?
}
