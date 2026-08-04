import ReparaCore
import UIKit

/// Two sizes, two purposes — do not conflate them.
///
/// The **council** gets the largest copy that is certain to arrive. The
/// **model** gets a smaller one still: 1568 px on the long edge is plenty to
/// identify a dumped mattress and costs a fraction of the tokens.
///
/// This used to hand the council the full-resolution original at quality 0.9,
/// on the strength of a note that 6.8 MB across two photos had once uploaded
/// fine. It does not any more: a single ~6 MB photograph came back from
/// `POST /ocorrencias` as a **500 whose body mentioned the size**, which cost a
/// report somebody was standing in the street to file. `Photo.maxBytes` carries
/// the full evidence and the reasoning behind the number; this file is what
/// holds photographs to it.
///
/// **The budget is met by re-encoding, never by refusing.** If even the
/// smallest encoding overshoots, the smallest one is what gets handed back —
/// a photograph the portal might refuse still beats a report with no evidence
/// on it, and the alternative is telling somebody outdoors that their camera
/// produced a file this app will not carry.
enum PhotoScaler {

    /// The long edge the council's copy is capped at.
    ///
    /// 2048 px is about 3 MP: several times what the portal's own detail view
    /// displays, and more than enough to see a mattress, a pothole, a broken
    /// lamp or a graffitied shutter. Beyond it, a street photograph is spending
    /// bytes on texture nobody is going to look at — and bytes are the thing
    /// that lost a report.
    static let councilLongEdge: CGFloat = 2048

    /// Tried in order until one fits `Photo.maxBytes`.
    ///
    /// It starts high because a council worker looks at this and decides what
    /// to bring. In practice a 2048 px street scene lands well under budget at
    /// the first rung, so the rest of the ladder is a backstop for the
    /// high-detail cases — foliage, gravel, crowds — rather than the normal path.
    static let councilQualities: [CGFloat] = [0.9, 0.8, 0.7, 0.6, 0.5]

    /// The long edge every provider's vision pipeline is happy with, and the
    /// tightest of the three, so one size serves all. Larger costs more
    /// tokens without helping identify what is in a street photograph.
    static let modelLongEdge: CGFloat = 1568

    /// JPEG quality for the copy sent to the model. Lower than the council's
    /// copy on purpose — the model is identifying a mattress, not reading a
    /// serial number.
    static let modelQuality: CGFloat = 0.7

    /// The JPEG for the submission: capped, and inside `Photo.maxBytes`.
    static func forCouncil(_ image: UIImage) -> Data? {
        let pixels = "\(Int(image.size.width))×\(Int(image.size.height))"
        var smallest: Data?

        // Halving the long edge is the second lever and it is rarely reached:
        // it takes an image that is still over budget at quality 0.5.
        for longEdge in [councilLongEdge, councilLongEdge / 2] {
            let scaled = downscaled(image, longEdge: longEdge)
            for quality in councilQualities {
                guard let data = scaled.jpegData(compressionQuality: quality) else { continue }
                smallest = data
                guard data.count <= Photo.maxBytes else { continue }

                // Quality as the percentage every JPEG encoder is discussed in,
                // rather than the 0.900000 a CGFloat interpolates to.
                Log.photos.notice(
                    """
                    council copy \(pixels, privacy: .public) → \
                    \(Int(longEdge), privacy: .public) px q\(Int(quality * 100), privacy: .public) \
                    \(data.count, privacy: .public) B
                    """)
                return data
            }
        }

        // Over budget at 1024 px and quality 0.5 means the budget was not the
        // problem. Send the smallest encoding rather than nothing, and say so —
        // if a submission then fails, this line is what explains it.
        Log.photos.error(
            """
            council copy \(pixels, privacy: .public) would not fit \
            \(Photo.maxBytes, privacy: .public) B; sending \
            \(smallest?.count ?? 0, privacy: .public) B
            """)
        return smallest
    }

    /// A downscaled JPEG for the model provider.
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
