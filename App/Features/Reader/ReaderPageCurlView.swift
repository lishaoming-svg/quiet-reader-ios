import SwiftUI
import UIKit

/// Native page curl, with only the current page and its neighbours kept in memory.
struct ReaderPageCurlView<Page: View>: UIViewControllerRepresentable {
    let count: Int
    let revision: String
    let background: UIColor
    @Binding var index: Int
    @ViewBuilder var page: (Int) -> Page

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
            options: [.spineLocation: UIPageViewController.SpineLocation.min.rawValue])
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.isDoubleSided = false
        // The reader's existing edge taps handle navigation; avoid advancing twice for one tap.
        for gesture in controller.gestureRecognizers where gesture is UITapGestureRecognizer { gesture.isEnabled = false }
        context.coordinator.show(controller, animated: false)
        return controller
    }
    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        let changed = coordinator.parent.revision != revision
        coordinator.parent = self
        controller.view.backgroundColor = background
        if changed { coordinator.cache = [:] }
        for (number, value) in coordinator.cache {
            value.rootView = AnyView(page(number))
            value.view.backgroundColor = background
        }
        coordinator.show(controller, animated: !changed && context.transaction.animation != nil)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: ReaderPageCurlView
        fileprivate var cache: [Int: CurlPageController] = [:]
        private var turning = false
        init(_ parent: ReaderPageCurlView) { self.parent = parent }

        private func controller(_ index: Int) -> CurlPageController? {
            guard (0..<parent.count).contains(index) else { return nil }
            if let cached = cache[index] { return cached }
            let value = CurlPageController(index: index, rootView: AnyView(parent.page(index)))
            value.view.backgroundColor = parent.background
            cache[index] = value
            return value
        }
        func show(_ pager: UIPageViewController, animated: Bool) {
            guard !turning, let target = controller(parent.index) else { return }
            let current = pager.viewControllers?.first as? CurlPageController
            guard current !== target else { return }
            turning = true
            let direction: UIPageViewController.NavigationDirection = (current?.index ?? 0) > parent.index ? .reverse : .forward
            pager.setViewControllers([target], direction: direction, animated: animated) { [weak self, weak pager] _ in
                guard let self, let pager else { return }
                self.turning = false
                self.cache = self.cache.filter { abs($0.key - self.parent.index) <= 1 }
                self.show(pager, animated: false)
            }
        }
        func pageViewController(_ pager: UIPageViewController, viewControllerBefore controller: UIViewController) -> UIViewController? {
            guard let current = controller as? CurlPageController else { return nil }
            return self.controller(current.index - 1)
        }
        func pageViewController(_ pager: UIPageViewController, viewControllerAfter controller: UIViewController) -> UIViewController? {
            guard let current = controller as? CurlPageController else { return nil }
            return self.controller(current.index + 1)
        }
        func pageViewController(_ pager: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            turning = true
        }
        func pageViewController(_ pager: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            turning = false
            if completed, let visible = pager.viewControllers?.first as? CurlPageController { parent.index = visible.index }
            cache = cache.filter { abs($0.key - parent.index) <= 1 }
        }
    }
}

private final class CurlPageController: UIHostingController<AnyView> {
    let index: Int
    init(index: Int, rootView: AnyView) { self.index = index; super.init(rootView: rootView) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(index:rootView:)") }
}
