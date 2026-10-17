//  MirrorView.swift
//  Renders the same HUDFrame on the phone.
//  This is a safe-zone mirror, not a pixel-perfect ActiveLook firmware renderer.

import SwiftUI

struct MirrorView: View {
    let frame: HUDFrame
    private let phos = Color(red: 57 / 255, green: 226 / 255, blue: 122 / 255)

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / CGFloat(Display.w)
            let sy = size.height / CGFloat(Display.h)

            func P(_ x: Int, _ y: Int) -> CGPoint {
                CGPoint(x: CGFloat(x) * sx, y: CGFloat(y) * sy)
            }

            func col(_ c: UInt8) -> Color {
                phos.opacity(Double(c) / 15.0)
            }

            ctx.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(red: 0.008, green: 0.02, blue: 0.012))
            )

            // Safe-zone guide on the phone mirror.
            let safeRect = CGRect(
                x: CGFloat(Display.safeMinX) * sx,
                y: CGFloat(Display.safeMinY) * sy,
                width: CGFloat(Display.safeMaxX - Display.safeMinX) * sx,
                height: CGFloat(Display.safeMaxY - Display.safeMinY) * sy
            )

            ctx.stroke(
                Path(safeRect),
                with: .color(phos.opacity(0.12)),
                lineWidth: 1
            )

            for op in frame.ops {
                switch op {
                case .clear, .luma:
                    break

                case .line(let x0, let y0, let x1, let y1, let c):
                    var p = Path()
                    p.move(to: P(x0, y0))
                    p.addLine(to: P(x1, y1))
                    ctx.stroke(p, with: .color(col(c)), lineWidth: 1.5)

                case .rect(let x0, let y0, let x1, let y1, let c):
                    let rect = CGRect(
                        x: P(x0, y0).x,
                        y: P(x0, y0).y,
                        width: CGFloat(x1 - x0) * sx,
                        height: CGFloat(y1 - y0) * sy
                    )
                    ctx.stroke(Path(rect), with: .color(col(c)), lineWidth: 1.5)

                case .rectf(let x0, let y0, let x1, let y1, let c):
                    let rect = CGRect(
                        x: P(x0, y0).x,
                        y: P(x0, y0).y,
                        width: CGFloat(x1 - x0) * sx,
                        height: CGFloat(y1 - y0) * sy
                    )
                    ctx.fill(Path(rect), with: .color(col(c)))

                case .circ(let x, let y, let r, let c):
                    let rect = CGRect(
                        x: P(x - r, y - r).x,
                        y: P(x - r, y - r).y,
                        width: CGFloat(2 * r) * sx,
                        height: CGFloat(2 * r) * sy
                    )
                    ctx.stroke(Path(ellipseIn: rect), with: .color(col(c)), lineWidth: 2)

                case .circf(let x, let y, let r, let c):
                    let rect = CGRect(
                        x: P(x - r, y - r).x,
                        y: P(x - r, y - r).y,
                        width: CGFloat(2 * r) * sx,
                        height: CGFloat(2 * r) * sy
                    )
                    ctx.fill(Path(ellipseIn: rect), with: .color(col(c)))

                case .text(let x, let y, let f, let c, let align, let s):
                    let pt = sizeFor(f) * sy
                    let text = Text(s)
                        .font(.system(size: pt, weight: .bold, design: .monospaced))
                        .foregroundColor(col(c))

                    ctx.draw(
                        text,
                        at: P(x, y),
                        anchor: align == .center ? .center : .leading
                    )
                }
            }
        }
        .aspectRatio(CGFloat(Display.w) / CGFloat(Display.h), contentMode: .fit)
        .background(Color.black)
        .overlay(scanlines.allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: phos.opacity(0.35), radius: 10)
    }

    private func sizeFor(_ f: HUDFont) -> CGFloat {
        switch f {
        case .small: return 11
        case .medium: return 15
        case .large: return 22
        case .huge: return 26
        }
    }

    private var scanlines: some View {
        GeometryReader { geo in
            Path { p in
                var y: CGFloat = 0

                while y < geo.size.height {
                    p.addRect(CGRect(x: 0, y: y, width: geo.size.width, height: 1))
                    y += 3
                }
            }
            .fill(Color.black.opacity(0.18))
        }
    }
}
