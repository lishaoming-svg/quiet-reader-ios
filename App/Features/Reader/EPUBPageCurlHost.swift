import Foundation
import ReadiumNavigator
import ReadiumShared
import SwiftUI
import WebKit

/// Keeps Readium's live, selectable document between turns. During a committed
/// swipe, UIKit curls snapshots of the actual rendered pages, preserving all CSS.
struct EPUBPageCurlHost: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    let mode: ReaderMode
    let paper: UIColor
    let onTurn: () -> Void
    let installTurnHandler: (@escaping (Int) -> Void) -> Void
    var onAnnotation: ((Locator, Bool) -> Void)? = nil

    func makeUIViewController(context: Context) -> EPUBCurlController {
        let controller = EPUBCurlController(navigator: navigator)
        controller.update(mode: mode, paper: paper, onTurn: onTurn)
        controller.annotate = onAnnotation
        installTurnHandler { [weak controller] direction in controller?.turn(direction) }
        return controller
    }
    func updateUIViewController(_ controller: EPUBCurlController, context: Context) {
        controller.update(mode: mode, paper: paper, onTurn: onTurn)
        controller.annotate = onAnnotation
    }
    static func dismantleUIViewController(_ controller: EPUBCurlController, coordinator: ()) { controller.stop() }
}

@MainActor
final class EPUBCurlController: UIViewController {
    let navigator: EPUBNavigatorViewController
    var annotate: ((Locator, Bool) -> Void)?
    private var mode = ReaderMode.pageCurl
    private var paper = UIColor.systemBackground
    private var onTurn: () -> Void = {}
    private var turnTask: Task<Void, Never>?
    private var overlay: UIView?
    private var curl: UIPageViewController?
    private var completion: CheckedContinuation<Void, Never>?

    init(navigator: EPUBNavigatorViewController) {
        self.navigator = navigator
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    @objc func highlightSelection() {
        guard let locator = navigator.currentSelection?.locator else { return }
        annotate?(locator, false); navigator.clearSelection()
    }
    @objc func noteSelection() {
        guard let locator = navigator.currentSelection?.locator else { return }
        annotate?(locator, true); navigator.clearSelection()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(navigator); view.addSubview(navigator.view); navigator.didMove(toParent: self)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let gesture = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            gesture.direction = direction; view.addGestureRecognizer(gesture)
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        navigator.view.frame = view.bounds
        overlay?.frame = view.bounds; curl?.view.frame = view.bounds
        configurePans(in: navigator.view)
    }
    func update(mode: ReaderMode, paper: UIColor, onTurn: @escaping () -> Void) {
        self.mode = navigator.settings.scroll ? .scroll : mode; self.paper = paper; self.onTurn = onTurn
        if isViewLoaded { view.backgroundColor = paper; configurePans(in: navigator.view) }
    }
    private func configurePans(in content: UIView) {
        if let scroll = content as? UIScrollView { scroll.panGestureRecognizer.isEnabled = mode != .pageCurl }
        content.subviews.forEach { configurePans(in: $0) }
    }
    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        guard mode == .pageCurl else { return }
        let forward = (gesture.direction == .left) == (navigator.settings.readingProgression == .ltr)
        turn(forward ? 1 : -1)
    }
    func turn(_ direction: Int) {
        guard turnTask == nil else { return }
        onTurn()
        turnTask = Task { [weak self] in
            guard let self else { return }
            defer { self.clearAnimation(); self.turnTask = nil }
            let original = self.mode == .pageCurl ? await self.pageImage() : nil
            guard !Task.isCancelled else { return }
            if let original {
                let cover = UIImageView(image: original); cover.frame = self.view.bounds
                cover.contentMode = .scaleToFill; self.view.addSubview(cover); self.overlay = cover
            }
            let options = NavigatorGoOptions(animated: self.mode == .pageSlide)
            let moved = direction > 0 ? await self.navigator.goForward(options: options) : await self.navigator.goBackward(options: options)
            guard moved, !Task.isCancelled, let original else { return }
            // Readium waits for the target resource here, including image-only pages.
            _ = await self.navigator.evaluateJavaScript("document.readyState")
            guard !Task.isCancelled, let target = await self.pageImage() else { return }
            await self.animate(from: original, to: target, direction: direction)
        }
    }
    private func pageImage() async -> UIImage? {
        view.layoutIfNeeded()
        func webViews(_ content: UIView) -> [WKWebView] {
            if let web = content as? WKWebView { return [web] }
            return content.subviews.flatMap(webViews)
        }
        let visible = webViews(navigator.view).filter {
            let frame = $0.convert($0.bounds, to: view)
            return frame.intersection(view.bounds).width > view.bounds.width * 0.5
        }
        guard !visible.isEmpty, view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        var images: [(UIImage, CGRect)] = []
        for web in visible {
            let config = WKSnapshotConfiguration(); config.afterScreenUpdates = true
            let image: UIImage? = await withCheckedContinuation { continuation in
                web.takeSnapshot(with: config) { image, _ in continuation.resume(returning: image) }
            }
            if let image { images.append((image, web.convert(web.bounds, to: view))) }
        }
        guard !images.isEmpty else { return nil }
        return UIGraphicsImageRenderer(size: view.bounds.size).image { context in
            paper.setFill(); context.cgContext.fill(view.bounds)
            images.forEach { $0.0.draw(in: $0.1) }
        }
    }
    private func animate(from old: UIImage, to new: UIImage, direction: Int) async {
        guard !Task.isCancelled else { return }
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                              options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])
        controller.view.backgroundColor = paper
        addChild(controller); controller.view.frame = view.bounds; view.addSubview(controller.view)
        controller.didMove(toParent: self); curl = controller
        func page(_ image: UIImage) -> UIViewController {
            let page = UIViewController(); let canvas = UIImageView(image: image)
            canvas.contentMode = .scaleToFill; canvas.backgroundColor = paper; page.view = canvas
            return page
        }
        let navigation: UIPageViewController.NavigationDirection = direction > 0 ? .forward : .reverse
        controller.setViewControllers([page(old)], direction: navigation, animated: false)
        controller.view.layoutIfNeeded()
        await withCheckedContinuation { continuation in
            completion = continuation
            controller.setViewControllers([page(new)], direction: navigation, animated: true) { [weak self] _ in
                self?.completeAnimation()
            }
        }
    }
    private func completeAnimation() { completion?.resume(); completion = nil }
    private func clearAnimation() {
        completeAnimation()
        curl?.willMove(toParent: nil); curl?.view.removeFromSuperview(); curl?.removeFromParent(); curl = nil
        overlay?.removeFromSuperview(); overlay = nil
    }
    func stop() { turnTask?.cancel(); clearAnimation() }
}
