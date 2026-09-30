import SwiftUI

/// Tabs inside one navigation stack: prepare / job / model screens open above the tab bar, like in the Expo app.
struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if app.ready {
                NavigationStack(path: $app.path) {
                    MainTabs()
                        .navigationDestination(for: Screen.self) { screen in
                            switch screen {
                            case .prepare(let args): PrepareView(args: args)
                            case .job(let id): JobView(id: id, slots: app.plannedSlots[id] ?? [:])
                            case .model(let source, let id): ModelDetailView(source: source, id: id)
                            case .preview(let id): PreviewView(id: id)
                            case .control(let id, let name): ControlView(printer: id, name: name)
                            case .printerProfile(let id, let name): PrinterProfileView(printer: id, name: name)
                            }
                        }
                }
                .sheet(item: $app.connectRequest) { request in
                    ConnectView(request: request)
                }
                .onChange(of: app.server) { _, _ in app.processInbox() }
            } else {
                Theme.bg.ignoresSafeArea()
            }
        }
        .tint(Theme.accent)
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        let t = app.l10n
        TabView(selection: $app.tab) {
            HomeView()
                .tabItem { Label(t(.tabPrint), systemImage: "shippingbox") }
                .tag(AppTab.print)
            DiscoverView()
                .tabItem { Label(t(.tabDiscover), systemImage: "magnifyingglass") }
                .tag(AppTab.discover)
            JobsView()
                .tabItem { Label(t(.tabJobs), systemImage: "list.bullet") }
                .tag(AppTab.jobs)
            PrintersView()
                .tabItem { Label(t(.tabPrinters), systemImage: "printer") }
                .tag(AppTab.printers)
            SettingsView()
                .tabItem { Label(t(.tabSettings), systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}
