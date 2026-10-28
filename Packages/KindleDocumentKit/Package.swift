// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KindleDocumentKit",
    platforms: [.iOS(.v17)],
    products: [.library(name: "KindleDocumentKit", type: .dynamic, targets: ["KindleDocumentKit"])],
    dependencies: [
        .package(url: "https://github.com/mlilback/LibmobiSPM.git", revision: "9f50f89509a2edc229b08ae4e128caa7bc983f3a")
    ],
    targets: [.target(name: "KindleDocumentKit", dependencies: [.product(name: "CLibmobi", package: "LibmobiSPM")])]
)
