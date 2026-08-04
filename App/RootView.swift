import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { BookshelfView() }
                .tabItem { Label("书架", systemImage: "books.vertical.fill") }

            NavigationStack { SearchView() }
                .tabItem { Label("寻书", systemImage: "text.magnifyingglass") }

            NavigationStack { SourceManagerView() }
                .tabItem { Label("书源", systemImage: "point.3.connected.trianglepath.dotted") }
        }
        .tint(AppTheme.vermilion)
    }
}
