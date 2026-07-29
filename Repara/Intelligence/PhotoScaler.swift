import UIKit

/// Two sizes, two purposes — do not conflate them.
///
/// The **council** gets the full-resolution original: that is the evidence a
/// worker acts on, and 6.8 MB across two photos has been accepted without
/// complaint. The **model** gets a downscaled copy: 1568 px on the long edge is
/// plenty to identify a dumped mattress and costs a fraction of the tokens.
enum PhotoScaler {

    /// The long edge Claude's vision pipeline is happy with. Larger costs more
    /// tokens without helping identify what is in a street photograph.
    static let modelLongEdge: CGFloat = 1568

    /// JPEG quality for the copy sent to the model. Lower than the council's
    /// copy on purpose — the model is identifying a mattress, not reading a
    /// serial number.
    static let modelQuality: CGFloat = 0.7

    /// Quality for the copy that goes to the council. High, because a worker
    /// looks at it and decides what to bring.
    static let councilQuality: CGFloat = 0.9

    /// The full-resolution JPEG for the submission.
    static func forCouncil(_ image: UIImage) -> Data? {
        image.jpegData(compressionQuality: councilQuality)
    }

    /// A downscaled JPEG for the Claude API.
    static func forModel(_ image: UIImage) -> Data? {
        downscaled(image, longEdge: modelLongEdge).jpegData(compressionQuality: modelQuality)
    }

    static func downscaled(_ image: UIImage, longEdge: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > longEdge else { return image }

        let scale = longEdge / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
