import SwiftUI

struct AlignmentOverlayView: View {
    let target: ImportedTargetLayout
    let person: PersonObservation?
    let referenceContour: SilhouetteContour?
    let liveContour: SilhouetteContour?
    let imageSize: CGSize
    let ready: Bool
    let debugEnabled: Bool

    var body: some View {
        Canvas { context, size in
            let primitives = OverlayRenderer.primitives(
                target: target,
                person: person,
                referenceContour: referenceContour,
                liveContour: liveContour,
                imageSize: imageSize,
                viewSize: size,
                includeDebugJoints: debugEnabled
            )
            let targetColor = ready ? Color.green : Color.orange
            if primitives.referenceLoops.isEmpty {
                drawFallbackTarget(context: &context, primitives: primitives, color: targetColor)
            } else {
                context.stroke(
                    path(for: primitives.referenceLoops),
                    with: .color(targetColor.opacity(0.98)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [10, 7])
                )
            }
            if !primitives.liveLoops.isEmpty {
                context.stroke(
                    path(for: primitives.liveLoops),
                    with: .color(ready ? .green : .cyan),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
            }

            if debugEnabled {
                drawFallbackTarget(context: &context, primitives: primitives, color: .orange)
                context.stroke(
                    Path(primitives.imageRect),
                    with: .color(.purple),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
                if let personRect = primitives.personRect {
                    context.stroke(Path(personRect), with: .color(.cyan), lineWidth: 1.5)
                }
                for point in primitives.joints.values {
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                        with: .color(.cyan)
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func path(for loops: [[CGPoint]]) -> Path {
        var path = Path()
        for loop in loops where loop.count >= 3 {
            path.move(to: loop[0])
            for point in loop.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
        return path
    }

    private func drawFallbackTarget(
        context: inout GraphicsContext,
        primitives: OverlayPrimitives,
        color: Color
    ) {
        context.stroke(
            Path(roundedRect: primitives.targetRect, cornerRadius: 28),
            with: .color(color.opacity(0.90)),
            style: StrokeStyle(lineWidth: 2, dash: [9, 7])
        )
        let headRadius = max(14, primitives.targetRect.width * 0.12)
        let headRect = CGRect(
            x: primitives.targetHead.x - headRadius,
            y: primitives.targetHead.y - headRadius,
            width: headRadius * 2,
            height: headRadius * 2
        )
        context.stroke(Path(ellipseIn: headRect), with: .color(color), lineWidth: 1.5)
        var footLine = Path()
        footLine.move(to: CGPoint(x: primitives.targetRect.minX, y: primitives.targetFootY))
        footLine.addLine(to: CGPoint(x: primitives.targetRect.maxX, y: primitives.targetFootY))
        context.stroke(footLine, with: .color(color.opacity(0.80)), lineWidth: 1.5)
    }
}
