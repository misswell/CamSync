import SwiftUI
import UIKit

/// Adds a selection-only pan recognizer to SwiftUI's underlying UIScrollView.
/// The recognizer fails unless the touch began on a checkbox, leaving ordinary
/// drags entirely to the system scroll recognizer.
struct SelectionPanGestureBridge: UIViewRepresentable {
    let canBegin: (CGPoint) -> Bool
    let onBegan: (CGPoint) -> Void
    let onChanged: (CGPoint) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            context.coordinator.attach(toAncestorOf: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
        DispatchQueue.main.async {
            context.coordinator.attach(toAncestorOf: uiView)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: SelectionPanGestureBridge
        private weak var scrollView: UIScrollView?
        private var selectionPan: StartingPointPanGestureRecognizer?
        private var displayLink: CADisplayLink?
        private var latestLocation: CGPoint?

        init(parent: SelectionPanGestureBridge) {
            self.parent = parent
        }

        func attach(toAncestorOf view: UIView) {
            guard let foundScrollView = containingScrollView(from: view) else { return }
            guard scrollView !== foundScrollView else { return }
            detach()

            let recognizer = StartingPointPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.delegate = self
            recognizer.maximumNumberOfTouches = 1
            recognizer.cancelsTouchesInView = true
            foundScrollView.addGestureRecognizer(recognizer)

            // Normal scrolling waits only long enough to learn whether this
            // touch began on a checkbox. Everywhere else selection fails and
            // UIScrollView's own pan recognizer proceeds normally.
            foundScrollView.panGestureRecognizer.require(toFail: recognizer)
            scrollView = foundScrollView
            selectionPan = recognizer
        }

        func detach() {
            stopDisplayLink()
            if let recognizer = selectionPan {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
            selectionPan = nil
            scrollView = nil
            latestLocation = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let recognizer = gestureRecognizer as? StartingPointPanGestureRecognizer,
                  let startLocation = recognizer.startLocation else { return false }
            return parent.canBegin(startLocation)
        }

        @objc private func handlePan(_ recognizer: StartingPointPanGestureRecognizer) {
            let location = recognizer.location(in: nil)
            switch recognizer.state {
            case .began:
                let startLocation = recognizer.startLocation ?? location
                latestLocation = location
                parent.onBegan(startLocation)
                parent.onChanged(location)
                startDisplayLink()
            case .changed:
                latestLocation = location
                parent.onChanged(location)
            case .ended, .cancelled, .failed:
                finishSelection()
            default:
                break
            }
        }

        private func startDisplayLink() {
            stopDisplayLink()
            let link = CADisplayLink(target: self, selector: #selector(autoScrollFrame(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        private func finishSelection() {
            stopDisplayLink()
            latestLocation = nil
            parent.onEnded()
        }

        @objc private func autoScrollFrame(_ link: CADisplayLink) {
            guard let scrollView, let location = latestLocation else { return }
            let viewport = scrollView.convert(scrollView.bounds, to: nil)
            let edgeSize: CGFloat = 68
            let maxSpeed: CGFloat = 760
            let velocity: CGFloat

            if location.y < viewport.minY + edgeSize {
                let ratio = min(max((viewport.minY + edgeSize - location.y) / edgeSize, 0), 1)
                velocity = -maxSpeed * ratio
            } else if location.y > viewport.maxY - edgeSize {
                let ratio = min(max((location.y - viewport.maxY + edgeSize) / edgeSize, 0), 1)
                velocity = maxSpeed * ratio
            } else {
                velocity = 0
            }

            guard velocity != 0 else { return }
            let frameDuration = max(link.targetTimestamp - link.timestamp, 1.0 / 120.0)
            let minimumY = -scrollView.adjustedContentInset.top
            let maximumY = max(
                minimumY,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            let targetY = min(max(scrollView.contentOffset.y + velocity * frameDuration, minimumY), maximumY)
            guard abs(targetY - scrollView.contentOffset.y) > 0.1 else { return }

            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: false)
            parent.onChanged(location)
        }

        private func containingScrollView(from view: UIView) -> UIScrollView? {
            var candidate = view.superview
            while let current = candidate {
                if let scrollView = current as? UIScrollView {
                    return scrollView
                }
                candidate = current.superview
            }
            return nil
        }
    }
}

private final class StartingPointPanGestureRecognizer: UIPanGestureRecognizer {
    private(set) var startLocation: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        startLocation = touches.first?.location(in: nil)
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        startLocation = nil
    }
}
