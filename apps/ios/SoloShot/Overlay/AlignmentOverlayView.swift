import SwiftUI

struct AlignmentOverlayView: View {
    let target: ImportedTargetLayout
    let person: PersonObservation?
    let imageSize: CGSize
    let ready: Bool
    let debugEnabled: Bool

    var body: some View {
        Canvas { context, size in
            let primitives = OverlayRenderer.primitives(
                target: target,
                person: person,
                imageSize: imageSize,
                viewSize: size,
                includeDebugJoints: debugEnabled
            )
            let targetColor = ready ? Color.green : Color.orange
            let targetPath = Path(roundedRect: primitives.targetRect, cornerRadius: 28)
            context.stroke(
                targetPath,
                with: .color(targetColor.opacity(0.95)),
                style: StrokeStyle(lineWidth: 3, dash: [9, 7])
            )
            let headRadius = max(14, primitives.targetRect.width * 0.12)
            let headRect = CGRect(
                x: primitives.targetHead.x - headRadius,
                y: primitives.targetHead.y - headRadius,
                width: headRadius * 2,
                height: headRadius * 2
            )
            context.stroke(Path(ellipseIn: headRect), with: .color(targetColor), lineWidth: 2)
            var footLine = Path()
            footLine.move(to: CGPoint(x: primitives.targetRect.minX, y: primitives.targetFootY))
            footLine.addLine(to: CGPoint(x: primitives.targetRect.maxX, y: primitives.targetFootY))
            context.stroke(footLine, with: .color(targetColor.opacity(0.85)), lineWidth: 2)

            if debugEnabled {
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
}
