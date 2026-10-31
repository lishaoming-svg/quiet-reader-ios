import PDFKit
import SwiftUI
import WebKit

/// Measures the renderer that is actually on screen, including iframe offsets,
/// page columns, publisher fonts and zoom. Active only while the ruler is on.
struct ReaderLineGuideProbe: UIViewRepresentable {
    var fraction: Double
    var changed: (CGRect?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.isUserInteractionEnabled = false
        context.coordinator.view = view; context.coordinator.start()
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.fraction = fraction; context.coordinator.changed = changed
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator: NSObject {
        weak var view: UIView?
        var fraction = 0.22
        var changed: (CGRect?) -> Void = { _ in }
        private var displayLink: CADisplayLink?
        private var sampling = false
        private var previous: CGRect?
        func start() {
            let link = CADisplayLink(target: self, selector: #selector(sample))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 12, preferred: 8)
            link.add(to: .main, forMode: .common); displayLink = link
        }
        func stop() { displayLink?.invalidate(); displayLink = nil }
        private func publish(_ value: CGRect?) {
            guard previous != value else { return }
            previous = value; changed(value)
        }
        @objc private func sample() {
            guard !sampling, let view, let window = view.window, view.bounds.height > 0 else { return }
            let viewport = view.bounds, y = CGFloat(fraction) * viewport.height
            var lines: [CGRect] = [], webs: [WKWebView] = []
            func visit(_ node: UIView) {
                guard !node.isHidden, node.alpha > 0.01 else { return }
                let frame = node.convert(node.bounds, to: view)
                if let canvas = node as? ReaderPageTextCanvas, frame.intersects(viewport) {
                    lines += canvas.renderedLineRects().map { canvas.convert($0, to: view) }; return
                }
                if let pdf = node as? PDFView, frame.intersects(viewport) {
                    for page in pdf.visiblePages {
                        let bounds = page.bounds(for: pdf.displayBox)
                        for line in page.selection(for: bounds)?.selectionsByLine() ?? [] {
                            let rect = pdf.convert(line.bounds(for: page), from: page)
                            lines.append(pdf.convert(rect, to: view))
                        }
                    }
                    return
                }
                if let web = node as? WKWebView, frame.intersects(viewport) { webs.append(web); return }
                node.subviews.forEach(visit)
            }
            visit(window)
            if let line = ReaderLineGuideGeometry.closestLine(lines, to: y, viewport: viewport) { publish(line); return }
            let target = CGPoint(x: viewport.midX, y: y)
            guard let web = webs.first(where: { $0.convert($0.bounds, to: view).contains(target) }) ?? webs.first else { publish(nil); return }
            let point = web.convert(target, from: view)
            sampling = true
            web.evaluateJavaScript(ReaderLineGuideScript.measure(at: point)) { [weak self, weak web, weak view] value, _ in
                guard let self else { return }; self.sampling = false
                guard let web, let view, view.window != nil else { return }
                guard let values = value as? [String: Double], let x = values["x"], let y = values["y"],
                      let width = values["width"], let height = values["height"] else { self.publish(nil); return }
                let rect = web.convert(CGRect(x: x, y: y, width: width, height: height), to: view)
                self.publish(rect.intersects(view.bounds) ? rect : nil)
            }
        }
    }
}

enum ReaderLineGuideScript {
    static func measure(at point: CGPoint) -> String {
        let point = (try? ContinuousPublicationScript.literal(["x": point.x, "y": point.y])) ?? "{\"x\":0,\"y\":0}"
        return "(\(measurement))(\(point))"
    }
    static let measurement = #"""
    (point=>{
      const vw=innerWidth,vh=innerHeight;let best=null,distance=Infinity,count=0;
      function scan(doc,ox=0,oy=0,sx=1,sy=1){
        if(!doc?.body)return;
        const visible=r=>r.width>2&&r.height>=4&&r.x<vw&&r.x+r.width>0&&r.y<vh&&r.y+r.height>0;
        const convert=r=>({x:ox+r.left*sx,y:oy+r.top*sy,width:r.width*sx,height:r.height*sy});
        // Prefer the paragraph under the ruler. This avoids walking a whole
        // long chapter on every sample, including when reading near its end.
        const caret=doc.caretRangeFromPoint?.((point.x-ox)/sx,(point.y-oy)/sy);
        const parent=caret?.startContainer?.parentElement;
        const scope=parent?.closest('p,li,blockquote,td,div,h1,h2,h3')||doc.body;
        const walker=doc.createTreeWalker(scope,NodeFilter.SHOW_TEXT);let node;
        while((node=walker.nextNode())&&count++<5000){
          if(!node.textContent.trim()||node.parentElement?.closest('script,style,noscript,rt,rp,[hidden]'))continue;
          const parent=node.parentElement;if(!parent||getComputedStyle(parent).visibility==='hidden')continue;
          if(![...parent.getClientRects()].some(r=>visible(convert(r))))continue;
          const range=doc.createRange();range.selectNodeContents(node);
          for(const box of range.getClientRects()){
            const r=convert(box);if(!visible(r))continue;
            const delta=Math.abs(r.y+r.height/2-point.y);
            if(delta<distance){distance=delta;best=r}
          }
        }
        for(const frame of doc.querySelectorAll('iframe')){
          const r=convert(frame.getBoundingClientRect());if(!visible(r))continue;
          try{scan(frame.contentDocument,r.x,r.y,r.width/Math.max(1,frame.clientWidth),r.height/Math.max(1,frame.clientHeight))}catch{}
        }
      }
      scan(document);return best;
    })
    """#
}
