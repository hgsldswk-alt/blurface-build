import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum ShareArtwork {
    static func storeURL(appID: String?) -> URL? {
        guard let appID, !appID.isEmpty, appID.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return URL(string: "https://apps.apple.com/app/id" + appID)
    }

    static func qr(_ url: URL) -> CIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        return filter.outputImage
    }

    static func make(photo: CGImage?, count: Int, includeBadge: Bool, storeURL: URL?) throws -> CGImage {
        let photoSize = photo.map {
            CGSize(width: 1080, height: max(1, (1080 * CGFloat($0.height) / CGFloat($0.width)).rounded()))
        }
        let naturalHeight = photoSize?.height ?? 0
        let height = photo == nil ? 1350 : min(naturalHeight, 1850) + (includeBadge ? 215 : 0)
        let size = CGSize(width: 1080, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let ink = UIColor(red: 0.063, green: 0.149, blue: 0.208, alpha: 1)
        let accent = UIColor(red: 0, green: 0.408, blue: 0.459, alpha: 1)
        let paper = UIColor(red: 0.945, green: 0.961, blue: 0.973, alpha: 1)
        let badge = includeBadge ? storeURL.flatMap { url -> CGImage? in
            guard let code = qr(url) else { return nil }
            let scale = max(1, floor(132 / code.extent.width))
            let scaled = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            return CIContext().createCGImage(scaled, from: scaled.extent)
        } : nil

        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            paper.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            if let photo {
                let availableHeight = min(naturalHeight, 1850)
                let scale = min(1080 / CGFloat(photo.width), availableHeight / CGFloat(photo.height))
                let width = CGFloat(photo.width) * scale
                UIImage(cgImage: photo).draw(in: CGRect(x: (1080 - width) / 2, y: 0, width: width, height: availableHeight))
            } else {
                label(L.t("milestone.title"), rect: CGRect(x: 90, y: 145, width: 900, height: 100), size: 51, color: ink)
                label(count.formatted(), rect: CGRect(x: 80, y: 350, width: 920, height: 305), size: 245, color: accent)
                label(L.f("milestone.copies", count), rect: CGRect(x: 90, y: 720, width: 900, height: 190), size: 57, color: ink)
            }
            if includeBadge {
                let top = size.height - 215
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: top, width: 1080, height: 215))
                let square = CGRect(x: 46, y: top + 30, width: 154, height: 154)
                if let badge {
                    let inset = (square.width - CGFloat(badge.width)) / 2
                    context.cgContext.interpolationQuality = .none
                    UIImage(cgImage: badge).draw(in: square.insetBy(dx: inset, dy: inset))
                } else {
                    paper.setFill()
                    context.fill(square)
                    label(L.t("share.qrPlaceholder"), rect: square.insetBy(dx: 8, dy: 28), size: 21, color: accent)
                }
                label(L.t("app.title"), rect: CGRect(x: 240, y: top + 42, width: 788, height: 59), size: 42, color: ink)
                label(L.t("share.hashtag"), rect: CGRect(x: 240, y: top + 112, width: 788, height: 66), size: 33, color: accent)
            }
        }
        guard let image = rendered.cgImage else { throw PhotoFailure.write }
        return image
    }

    private static func label(_ title: String, rect: CGRect, size: CGFloat, color: UIColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        (title as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                 attributes: [.font: UIFont.systemFont(ofSize: size, weight: .semibold),
                                              .foregroundColor: color, .paragraphStyle: paragraph], context: nil)
    }
}
