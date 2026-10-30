import Foundation
import ReadiumShared
import SwiftUI
import UIKit
import WebKit

struct ContinuousReadingPosition: Equatable {
    var index: Int
    var fraction: Double = 0
    var fragment = ""
    var quote = ""
}

struct ContinuousPublicationView: UIViewRepresentable {
    let publication: Publication
    let initial: ContinuousReadingPosition
    let theme: String
    let publisherStyles: Bool
    let fontSize: Double
    var typography: [String: Any]? = nil
    var scrolled: (() -> Void)? = nil
    let changed: (ContinuousReadingPosition) -> Void
    let tapped: () -> Void
    let ready: () -> Void
    let failure: (String) -> Void
    let installNavigation: (@escaping (ContinuousReadingPosition) -> Void) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let handler = PublicationSchemeHandler(publication: publication, failure: failure)
        context.coordinator.schemeHandler = handler
        config.setURLSchemeHandler(handler, forURLScheme: "ibooks-stream")
        config.userContentController.add(context.coordinator, name: "readerStream")
        config.userContentController.addUserScript(WKUserScript(source: ContinuousPublicationScript.child,
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false; web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear; web.scrollView.isDirectionalLockEnabled = true
        web.scrollView.alwaysBounceHorizontal = false; web.navigationDelegate = context.coordinator
        web.scrollView.panGestureRecognizer.addTarget(context.coordinator, action: #selector(Coordinator.panned(_:)))
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false; tap.delaysTouchesBegan = false; tap.delaysTouchesEnded = false
        tap.delegate = context.coordinator
        web.addGestureRecognizer(tap)
        context.coordinator.web = web
        installNavigation { [weak web] position in
            guard let literal = try? ContinuousPublicationScript.literal(position.json) else { return }
            web?.evaluateJavaScript("window.readerStream?.seek(\(literal))")
        }
        handler.document = Data(ContinuousPublicationScript.document(publication: publication, initial: initial, settings: settings).utf8)
        web.load(URLRequest(url: URL(string: "ibooks-stream://publication/__reader__.html")!))
        return web
    }
    private var settings: [String: Any] {
        var value: [String: Any] = ["theme": theme, "font": fontSize, "publisher": publisherStyles,
         "paper": typography?["paper"] ?? (theme == "dark" ? "#151515" : theme == "sepia" ? "#f2e3c8" : "#ffffff"),
         "ink": theme == "dark" ? "#e5e1da" : "#3c3328"]
        if let typography { value["typography"] = typography }
        return value
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.owner = self
        guard let literal = try? ContinuousPublicationScript.literal(settings), literal != context.coordinator.settings else { return }
        context.coordinator.settings = literal
        web.evaluateJavaScript("window.readerStream?.configure(\(literal))")
    }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading(); web.configuration.userContentController.removeScriptMessageHandler(forName: "readerStream")
        coordinator.schemeHandler?.stopAll(); coordinator.web = nil
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, UIGestureRecognizerDelegate {
        var owner: ContinuousPublicationView
        weak var web: WKWebView?
        var schemeHandler: PublicationSchemeHandler?
        var settings = ""
        init(_ owner: ContinuousPublicationView) { self.owner = owner }
        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began { owner.scrolled?() }
        }
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let web else { return }
            let point = gesture.location(in: web)
            web.evaluateJavaScript(ContinuousPublicationScript.menuAllowed(at: point)) { [weak self] value, error in
                guard error == nil, value as? Bool == true else { return }
                self?.owner.tapped()
            }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any],
                  let type = value["type"] as? String else { return }
            switch type {
            case "position":
                guard let index = value["index"] as? Int, owner.publication.readingOrder.indices.contains(index) else { return }
                owner.changed(ContinuousReadingPosition(index: index, fraction: min(1, max(0, value["fraction"] as? Double ?? 0))))
            case "ready": owner.ready()
            default: break
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if ["ibooks-stream", "about"].contains(url.scheme ?? "") { decisionHandler(.allow); return }
            if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(url.scheme ?? "") {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }
    }
}

private extension ContinuousReadingPosition {
    var json: [String: Any] { ["index": index, "fraction": fraction, "fragment": fragment, "quote": quote] }
}

final class PublicationSchemeHandler: NSObject, WKURLSchemeHandler {
    let publication: Publication
    let failure: (String) -> Void
    var document = Data()
    private var requests: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(publication: Publication, failure: @escaping (String) -> Void) { self.publication = publication; self.failure = failure }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask as AnyObject)
        requests[id] = Task { @MainActor [weak self] in
            guard let self, let url = urlSchemeTask.request.url else { return }
            defer { self.requests.removeValue(forKey: id) }
            do {
                let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if path == "__reader__.html" {
                    guard self.requests[id] != nil else { return }
                    urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: self.document.count, textEncodingName: "utf-8"))
                    urlSchemeTask.didReceive(self.document); urlSchemeTask.didFinish(); return
                }
                guard let href = AnyURL(string: path), let resource = self.publication.get(href) else { throw LocalBookError.missing }
                var data = try await resource.read().get()
                try Task.checkCancellation()
                let mime = Self.mime(url.pathExtension)
                if mime == "application/xhtml+xml" || mime == "text/html" {
                    let text: String
                    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { text = String(data: data, encoding: .utf16) ?? TextDecoder.decode(data, contentType: mime) }
                    else { text = TextDecoder.decode(data, contentType: mime) }
                    data = Data(ContinuousPublicationScript.prepareHTML(text).utf8)
                } else if mime == "text/css" {
                    data = Data(ContinuousPublicationScript.viewportUnits(String(decoding: data, as: UTF8.self)).utf8)
                }
                guard self.requests[id] != nil else { return }
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime == "application/xhtml+xml" ? "text/html" : mime, expectedContentLength: data.count,
                    textEncodingName: mime.contains("html") || mime == "text/css" ? "utf-8" : nil))
                urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
            } catch is CancellationError { return }
            catch {
                guard self.requests[id] != nil else { return }
                self.failure(error.localizedDescription); urlSchemeTask.didFailWithError(error)
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        requests.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject))?.cancel()
    }
    func stopAll() { requests.values.forEach { $0.cancel() }; requests.removeAll() }
    static func mime(_ ext: String) -> String {
        let types = ["xhtml":"application/xhtml+xml", "html":"text/html", "htm":"text/html", "css":"text/css", "svg":"image/svg+xml",
         "jpg":"image/jpeg", "jpeg":"image/jpeg", "png":"image/png", "gif":"image/gif", "webp":"image/webp",
         "woff":"font/woff", "woff2":"font/woff2", "ttf":"font/ttf", "otf":"font/otf", "avif":"image/avif"]
        return types[ext.lowercased()] ?? "application/octet-stream"
    }
}

enum ContinuousPublicationScript {
    /// One native tap observer covers both chapters and the space between them.
    /// Let links, form controls and an active text selection keep their action.
    static func menuAllowed(at point: CGPoint) -> String {
        let coordinates = (try? literal([point.x, point.y])) ?? "[0,0]"
        return """
        (()=>{const p=\(coordinates);let doc=document,node=doc.elementFromPoint(p[0],p[1]);
        if(node?.tagName==='IFRAME'){const r=node.getBoundingClientRect();doc=node.contentDocument;if(!doc)return false;node=doc.elementFromPoint(p[0]-r.left,p[1]-r.top)}
        if(node?.closest?.('a[href],button,input,textarea,select,[contenteditable]'))return false;
        const selection=doc.getSelection?.();return !selection||selection.isCollapsed})()
        """
    }
    static func viewportUnits(_ css: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)vh\b"#, options: .caseInsensitive) else { return css }
        return expression.stringByReplacingMatches(in: css, range: NSRange(css.startIndex..., in: css),
            withTemplate: "calc(var(--ibooks-vh, 8px) * $1)")
    }
    static func literal(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
    }
    static func prepareHTML(_ html: String) -> String {
        let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'self' data:;script-src 'none';style-src 'self' 'unsafe-inline';img-src 'self' data:;font-src 'self' data:;connect-src 'none';frame-src 'none';object-src 'none';\"/>"
        guard let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) else {
            return "<!doctype html><html><head>\(policy)</head><body>\(viewportUnits(html))</body></html>"
        }
        var result = html; result.insert(contentsOf: policy, at: head.upperBound)
        result = viewportUnits(result)
        if result.range(of: "<!doctype", options: .caseInsensitive) == nil { result = "<!doctype html>" + result }
        return result
    }
    static func document(publication: Publication, initial: ContinuousReadingPosition, settings: [String: Any]) -> String {
        let links = publication.readingOrder.map { ["href": $0.href.components(separatedBy: "#")[0], "title": $0.title ?? ""] }
        let pages = (try? literal(links)) ?? "[]", start = (try? literal(initial.json)) ?? "{}", config = (try? literal(settings)) ?? "{}"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=4"/>
        <style>html,body{margin:0;padding:0;overflow-x:hidden;overflow-anchor:none}iframe{display:block;width:100%;border:0;height:100vh;background:transparent}main{padding:16px 0 64px}section{margin:0;padding:0 0 28px;overflow-anchor:none}</style></head><body><main id="book"></main><script>
        (()=>{const pages=\(pages), start=\(start);let settings=\(config), restoring=true, target=start, current=start.index||0, timer=0;
        const host=document.getElementById('book'), frames=[];
        const bridge=(type,data={})=>window.webkit.messageHandlers.readerStream.postMessage({type,...data});
        function config(frame){frame.contentWindow?.postMessage({readerStream:'configure',settings,viewport:innerHeight},'*')}
        function load(frame){if(!frame.dataset.loaded){frame.dataset.loaded='1';frame.src=frame.dataset.src}else config(frame)}
        pages.forEach((page,index)=>{const section=document.createElement('section'),frame=document.createElement('iframe');frame.name='reader-'+index;frame.title=page.title;frame.dataset.index=index;frame.dataset.src=page.href;frame.setAttribute('sandbox','allow-same-origin allow-scripts');section.appendChild(frame);host.appendChild(section);frames.push(frame)});
        function indexAtTop(){let found=0;for(let i=0;i<frames.length;i++){if(frames[i].getBoundingClientRect().top<=100)found=i;else break}return found}
        function seek(position){if(!frames[position.index])return;target=position;restoring=true;current=position.index;load(frames[current]);scrollTo(0,frames[current].parentElement.offsetTop);config(frames[current]);frames[current].contentWindow?.postMessage({readerStream:'seek',position},'*')}
        window.readerStream={seek,configure(value){settings=value;document.body.style.background=value.paper;frames.filter(f=>f.dataset.loaded).forEach(config)}};
        function position(){if(restoring)return;current=indexAtTop();const frame=frames[current],rect=frame.getBoundingClientRect();const fraction=Math.max(0,Math.min(1,-rect.top/Math.max(1,rect.height-innerHeight)));bridge('position',{index:current,fraction});
          frames.forEach((f,i)=>{const r=f.getBoundingClientRect();if(r.bottom>-innerHeight*2&&r.top<innerHeight*3)load(f);else if(Math.abs(i-current)>4&&f.dataset.loaded){delete f.dataset.loaded;f.src='about:blank'}})}
        addEventListener('scroll',()=>{clearTimeout(timer);timer=setTimeout(position,160)},{passive:true});
        addEventListener('resize',()=>{frames.filter(f=>f.dataset.loaded).forEach(config);position()});
        addEventListener('message',event=>{const d=event.data;if(!d||d.readerStream!=='child')return;const frame=frames[d.index];if(!frame||event.source!==frame.contentWindow)return;
          if(d.type==='height'){const anchor=indexAtTop(),old=frame.offsetHeight,height=Math.max(40,Math.min(10000000,d.height||40));if(Math.abs(height-old)>1){frame.style.height=height+'px';if(d.index<anchor&&!restoring)scrollBy(0,height-old)}config(frame);if(restoring&&d.index===target.index)frame.contentWindow.postMessage({readerStream:'seek',position:target},'*')}
          else if(d.type==='seeked'){if(restoring&&d.index===target.index){scrollTo(0,frame.parentElement.offsetTop+Math.max(0,d.y||0));restoring=false;bridge('ready');position()}}
          else if(d.type==='link'){const value=new URL(d.href,frame.dataset.src.startsWith('ibooks-stream:')?frame.dataset.src:new URL(frame.dataset.src,location.href));const index=pages.findIndex(p=>new URL(p.href,location.href).pathname===value.pathname);if(index>=0)seek({index,fraction:0,fragment:value.hash.slice(1)})}
        });
        const observer=new IntersectionObserver(items=>items.forEach(item=>{if(item.isIntersecting)load(item.target)}),{rootMargin:'1800px 0px'});frames.forEach(f=>observer.observe(f));
        document.body.style.background=settings.paper;if(frames.length)seek(start);else bridge('ready');
        })();</script></body></html>
        """
    }

    static let child = #"""
    (()=>{if(window===top)return;const match=window.name.match(/^reader-(\d+)$/);if(!match)return;const index=Number(match[1]);let ready=false,lastHeight=0,viewport=800;
      const send=(type,value={})=>parent.postMessage({readerStream:'child',index,type,...value},'*');
      function height(){if(!document.body)return;const h=Math.ceil(Math.max(document.body.scrollHeight,document.body.getBoundingClientRect().height));if(Math.abs(h-lastHeight)>1){lastHeight=h;send('height',{height:h})}}
      function configure(s){document.documentElement.style.setProperty('--ibooks-vh',(viewport/100)+'px');let style=document.getElementById('ibooks-continuous-style');if(!style){style=document.createElementNS('http://www.w3.org/1999/xhtml','style');style.id='ibooks-continuous-style';document.head.appendChild(style)}
        style.textContent=`html,body{height:auto!important;min-height:0!important;column-count:auto!important;column-width:auto!important;overflow:visible!important;background:${s.paper}!important;color:${s.ink}}body{margin:0;padding:28px 26px}img,svg,video{max-width:100%!important;max-height:${viewport*.88}px!important;object-fit:contain;break-inside:avoid} ${s.publisher?'':`body{font-family:-apple-system,'PingFang SC',sans-serif!important;font-size:${18*s.font/100}px!important;font-weight:300!important;line-height:1.85!important}p{margin-bottom:1em}`} `;
        if(s.typography){const t=s.typography;style.textContent+=`${t.embedded?"@font-face{font-family:ibooks-imported;src:url('reader-font.ttf')}":''}body{box-sizing:border-box;width:100%;max-width:${t.maxWidth+2*t.margin}px!important;margin:0 auto!important;padding-left:${t.margin}px!important;padding-right:${t.margin}px!important;font-family:${t.embedded?'ibooks-imported':JSON.stringify(t.font)},sans-serif!important;font-size:${18*s.font/100}px!important;line-height:${18*s.font/100+t.lineSpacing}px!important}p{text-indent:${t.indent?'2em':'0'}!important;margin-bottom:${t.paragraphSpacing}px!important}`}
        height()}
      function seek(p){let y=Math.max(0,(document.body?.scrollHeight-viewport)*(p.fraction||0));if(p.fragment){const element=document.getElementById(decodeURIComponent(p.fragment));if(element)y=element.getBoundingClientRect().top+scrollY}
        if(p.quote){const walker=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT);let node;while(node=walker.nextNode()){const i=node.textContent.indexOf(p.quote);if(i>=0){const r=document.createRange();r.setStart(node,i);r.setEnd(node,Math.min(node.length,i+p.quote.length));y=r.getBoundingClientRect().top+scrollY;break}}}send('seeked',{y})}
      addEventListener('message',event=>{if(event.source!==parent||!event.data)return;const d=event.data;if(d.readerStream==='configure'){viewport=d.viewport||800;if(ready)configure(d.settings)}else if(d.readerStream==='seek'&&ready)seek(d.position)});
      function install(){if(!document.body)return;ready=true;new ResizeObserver(height).observe(document.body);document.fonts?.ready.then(height);document.querySelectorAll('img').forEach(i=>i.addEventListener('load',height));height();send('height',{height:lastHeight})}
      if(document.readyState==='loading')addEventListener('DOMContentLoaded',install,{once:true});else install();
      addEventListener('click',event=>{const a=event.target.closest?.('a[href]');if(a){const href=a.getAttribute('href');if(href&&!/^https?:/i.test(href)){event.preventDefault();send('link',{href:new URL(href,location.href).href})}}});
    })();
    """#
}
