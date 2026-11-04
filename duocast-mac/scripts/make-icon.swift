import AppKit
import CoreGraphics
import Foundation

// 1024 画布上画图标：一个输入分叉成三路，三种颜色对应界面里的 A/B/C
let canvas: CGFloat = 1024
let size = CGSize(width: canvas, height: canvas)

guard let ctx = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// 背景：macOS 标准圆角方块（留 64pt 边距）
let tile = CGRect(x: 64, y: 64, width: 896, height: 896)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 200, cornerHeight: 200, transform: nil)

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()

let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [color(0x2A2621), color(0x121110)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 960), end: CGPoint(x: 512, y: 64), options: [])
ctx.restoreGState()

// 内侧细边
ctx.addPath(tilePath)
ctx.setStrokeColor(color(0x4A4235, 0.55))
ctx.setLineWidth(3)
ctx.strokePath()

// 主干 + 三条分支
let trunkStart = CGPoint(x: 250, y: 512)
let split = CGPoint(x: 452, y: 512)
let ends = [
    CGPoint(x: 706, y: 300),
    CGPoint(x: 706, y: 512),
    CGPoint(x: 706, y: 724),
]
let branchColors: [UInt32] = [0xF2F2F2, 0xE8C268, 0x7DD9A6]

ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setLineWidth(38)

// 主干统一白色
ctx.setStrokeColor(color(0xF2F2F2))
ctx.move(to: trunkStart)
ctx.addLine(to: split)
ctx.strokePath()

for (index, end) in ends.enumerated() {
    ctx.setStrokeColor(color(branchColors[index]))
    ctx.move(to: split)

    if index == 1 {
        ctx.addLine(to: end)
    } else {
        // 用两段贝塞尔做出分叉的弧度
        let c1 = CGPoint(x: 580, y: 512)
        let c2 = CGPoint(x: 580, y: end.y)
        ctx.addCurve(to: end, control1: c1, control2: c2)
    }

    ctx.strokePath()

    // 端点圆环
    let radius: CGFloat = 58
    let circle = CGRect(x: end.x - radius, y: end.y - radius, width: radius * 2, height: radius * 2)
    ctx.setFillColor(color(branchColors[index]))
    ctx.fillEllipse(in: circle)
}

guard let image = ctx.makeImage() else { exit(1) }

let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/icon/icon-1024.png")
try data.write(to: out)
print("wrote \(out.path)")
