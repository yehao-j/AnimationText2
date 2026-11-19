import CoreText
import Metal
import UIKit

struct TextAnimation {
    /// 单个字符的动画时长，单位为秒。
    static let duration: Float = 0.22
    /// 相邻字符开始动画的时间间隔，单位为秒。
    static let stagger: Float = 0.03
    /// 字符在动画开始时的垂直偏移距离，单位为点。
    static let travelDistance: Float = 16
    /// 动画文本使用的字体。
    static let font = UIFont.systemFont(ofSize: 17, weight: .regular)
    /// 字符之间的额外间距，单位为点。
    static let letterSpacing: CGFloat = 0
    /// 相邻文本行之间的额外间距，单位为点。
    static let lineSpacing: CGFloat = 0
}

struct GlyphInstance {
    let origin: SIMD2<Float>
    let size: SIMD2<Float>
    let uvOrigin: SIMD2<Float>
    let uvSize: SIMD2<Float>
    let blurUVOrigin: SIMD2<Float>
    let blurUVSize: SIMD2<Float>
    let delay: Float
    private let padding: Float = 0
}

struct GlyphAtlas {
    let texture: MTLTexture
    let instances: [GlyphInstance]
    let blurAtlasSize: CGSize
    let animationDuration: Float
    let pixelsPerPoint: Float
    let maxBlur: Float
}

enum GlyphAtlasError: LocalizedError {
    case cannotCreateContext
    case cannotCreateTexture
    case atlasOverflow

    var errorDescription: String? {
        switch self {
        case .cannotCreateContext: return "无法创建字形图集上下文"
        case .cannotCreateTexture: return "无法创建 Metal 字形纹理"
        case .atlasOverflow: return "字形图集超出纹理尺寸限制"
        }
    }
}

/// Performs Core Text layout and glyph rasterization only when the viewport changes.
/// The frame loop never reads or modifies these glyph instances.
enum GlyphAtlasBuilder {
    private struct AtlasKey: Hashable {
        let glyph: CGGlyph
        let fontName: String
        let pointSize: Float
    }

    private struct Description {
        let key: AtlasKey
        let localBounds: CGRect
        let baseline: CGPoint
        let delay: Float
    }

    static func build(
        text: String,
        font: UIFont,
        lineSpacing: CGFloat,
        maxBlur: Float,
        contentRect: CGRect,
        contentScale: CGFloat,
        device: MTLDevice
    ) throws -> GlyphAtlas {
        let maxBlur = max(0, maxBlur)
        let lineHeight = font.lineHeight + lineSpacing
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.minimumLineHeight = lineHeight
        paragraphStyle.maximumLineHeight = lineHeight
        paragraphStyle.lineBreakMode = .byCharWrapping

        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .kern: TextAnimation.letterSpacing,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraphStyle
            ]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let path = CGPath(rect: contentRect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributedText.length),
            path,
            nil
        )

        let lines = CTFrameGetLines(frame) as! [CTLine]
        var lineOrigins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &lineOrigins)

        var descriptions: [Description] = []
        var localBoundsByKey: [AtlasKey: CGRect] = [:]
        var fontsByKey: [AtlasKey: CTFont] = [:]
        var sequence = 0

        for (lineIndex, line) in lines.enumerated() {
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            for run in runs {
                let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any]
                let runUIFont = attributes?[.font] as? UIFont ?? font
                let runFont = runUIFont as CTFont
                let fontName = CTFontCopyPostScriptName(runFont) as String
                let glyphCount = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
                var positions = [CGPoint](repeating: .zero, count: glyphCount)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)

                for index in 0..<glyphCount {
                    let delay = Float(sequence) * TextAnimation.stagger
                    sequence += 1

                    var localBounds = CGRect.zero
                    var glyph = glyphs[index]
                    CTFontGetBoundingRectsForGlyphs(runFont, .default, &glyph, &localBounds, 1)
                    guard localBounds.width > 0, localBounds.height > 0 else { continue }

                    let baseline = CGPoint(
                        x: contentRect.minX + lineOrigins[lineIndex].x + positions[index].x,
                        y: contentRect.minY + lineOrigins[lineIndex].y + positions[index].y
                    )
                    let key = AtlasKey(
                        glyph: glyph,
                        fontName: fontName,
                        pointSize: Float(runUIFont.pointSize)
                    )
                    descriptions.append(Description(
                        key: key,
                        localBounds: localBounds,
                        baseline: baseline,
                        delay: delay
                    ))
                    localBoundsByKey[key] = localBounds
                    fontsByKey[key] = runFont
                }
            }
        }

        let scale = max(1, contentScale)
        let paddingInPixels = Int(ceil(CGFloat(maxBlur) * scale)) + 2
        let atlasWidth = 2048
        var x = 0
        var y = 0
        var rowHeight = 0
        var pixelRectsByKey: [AtlasKey: CGRect] = [:]

        for (key, localBounds) in localBoundsByKey {
            let width = Int(ceil(localBounds.width * scale)) + paddingInPixels * 2
            let height = Int(ceil(localBounds.height * scale)) + paddingInPixels * 2
            if width > atlasWidth { throw GlyphAtlasError.atlasOverflow }
            if x + width > atlasWidth {
                x = 0
                y += rowHeight
                rowHeight = 0
            }
            pixelRectsByKey[key] = CGRect(x: x, y: y, width: width, height: height)
            x += width
            rowHeight = max(rowHeight, height)
        }

        let atlasHeight = max(1, y + rowHeight)
        guard atlasHeight <= 16_384 else { throw GlyphAtlasError.atlasOverflow }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: atlasWidth,
            height: atlasHeight,
            bitsPerComponent: 8,
            bytesPerRow: atlasWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw GlyphAtlasError.cannotCreateContext
        }

        context.setFillColor(UIColor.white.cgColor)
        context.setAllowsAntialiasing(true)
        context.setShouldSmoothFonts(true)
        context.scaleBy(x: scale, y: scale)

        for (key, pixelRect) in pixelRectsByKey {
            guard let localBounds = localBoundsByKey[key], let font = fontsByKey[key] else { continue }
            var glyph = key.glyph
            let padding = CGFloat(paddingInPixels) / scale
            var position = CGPoint(
                x: pixelRect.minX / scale - localBounds.minX + padding,
                y: pixelRect.minY / scale - localBounds.minY + padding
            )
            CTFontDrawGlyphs(font, &glyph, &position, 1, context)
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: atlasWidth,
            height: atlasHeight,
            mipmapped: false
        )
        textureDescriptor.usage = .shaderRead
        textureDescriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: textureDescriptor), let data = context.data else {
            throw GlyphAtlasError.cannotCreateTexture
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, atlasWidth, atlasHeight),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: atlasWidth * 4
        )

        let blurAtlasWidth = atlasWidth
        var blurX = 0
        var blurY = 0
        var blurRowHeight = 0
        let blurPixelRects = descriptions.map { description -> CGRect in
            let pixelRect = pixelRectsByKey[description.key]!
            let width = Int(pixelRect.width)
            let height = Int(pixelRect.height)
            if blurX + width > blurAtlasWidth {
                blurX = 0
                blurY += blurRowHeight
                blurRowHeight = 0
            }
            let blurPixelRect = CGRect(x: blurX, y: blurY, width: width, height: height)
            blurX += width
            blurRowHeight = max(blurRowHeight, height)
            return blurPixelRect
        }
        let blurAtlasHeight = max(1, blurY + blurRowHeight)
        guard blurAtlasHeight <= 16_384 else { throw GlyphAtlasError.atlasOverflow }

        let paddingInPoints = CGFloat(paddingInPixels) / scale
        let instances = descriptions.enumerated().map { index, description in
            let pixelRect = pixelRectsByKey[description.key]!
            let blurPixelRect = blurPixelRects[index]
            let absoluteOrigin = CGPoint(
                x: description.baseline.x + description.localBounds.minX - paddingInPoints,
                y: description.baseline.y + description.localBounds.minY - paddingInPoints
            )
            let size = CGSize(
                width: pixelRect.width / scale,
                height: pixelRect.height / scale
            )
            return GlyphInstance(
                origin: SIMD2(Float(absoluteOrigin.x), Float(absoluteOrigin.y)),
                size: SIMD2(Float(size.width), Float(size.height)),
                uvOrigin: SIMD2(
                    Float(pixelRect.minX / CGFloat(atlasWidth)),
                    Float((CGFloat(atlasHeight) - pixelRect.maxY) / CGFloat(atlasHeight))
                ),
                uvSize: SIMD2(
                    Float(pixelRect.width / CGFloat(atlasWidth)),
                    Float(pixelRect.height / CGFloat(atlasHeight))
                ),
                blurUVOrigin: SIMD2(
                    Float(blurPixelRect.minX / CGFloat(blurAtlasWidth)),
                    Float((CGFloat(blurAtlasHeight) - blurPixelRect.maxY) / CGFloat(blurAtlasHeight))
                ),
                blurUVSize: SIMD2(
                    Float(blurPixelRect.width / CGFloat(blurAtlasWidth)),
                    Float(blurPixelRect.height / CGFloat(blurAtlasHeight))
                ),
                delay: description.delay
            )
        }

        let animationDuration = Float(sequence) * TextAnimation.stagger + TextAnimation.duration
        return GlyphAtlas(
            texture: texture,
            instances: instances,
            blurAtlasSize: CGSize(width: blurAtlasWidth, height: blurAtlasHeight),
            animationDuration: animationDuration,
            pixelsPerPoint: Float(scale),
            maxBlur: maxBlur
        )
    }
}
