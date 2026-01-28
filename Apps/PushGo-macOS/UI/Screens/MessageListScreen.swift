import Observation
import SwiftUI

struct MessageListScreen: View {
    @Environment(LocalizationManager.self) private var localizationManager: LocalizationManager
    @Environment(MessageSearchViewModel.self) private var searchViewModel: MessageSearchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var viewModel: MessageListViewModel
    @Binding var selection: UUID?
    @State private var pendingScrollTarget: UUID?

    private enum Layout {
        static let rowInsets = EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    }

    var body: some View {
        let baseView = Group {
            if !viewModel.hasLoadedOnce {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isShowingSearchResults {
                searchResultsList
            } else if viewModel.filteredMessages.isEmpty {
                emptyState
            } else {
                messagesList
            }
        }
        .navigationTitle(localizationManager.localized("messages"))
        let titledView = applyTitleToolbarIfNeeded(baseView)
        return applySearchIfNeeded(titledView)
    }

    @ViewBuilder
    private func applyTitleToolbarIfNeeded<Content: View>(_ content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.toolbar {
                ToolbarItem(placement: .navigation) {
                    Text(localizationManager.localized("messages"))
                        .font(.headline.weight(.semibold))
                }
            }
        }
    }

    @ViewBuilder
    private func applySearchIfNeeded<Content: View>(_ content: Content) -> some View {
#if os(macOS)
        if #available(macOS 26.0, *) {
            content
        } else {
            content.searchable(
                text: Binding(
                    get: { searchViewModel.query },
                    set: { newValue in searchViewModel.updateQuery(newValue) }
                ),
                placement: .toolbar,
                prompt: Text(localizationManager.localized("search_messages"))
            )
        }
#else
        content
#endif
    }

    private var isShowingSearchResults: Bool {
        searchViewModel.hasSearched
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(viewModel.filteredMessages) { message in
                    MessageRowView(message: message)
                        .tag(message.id)
                        .id(message.id)
                        .listRowInsets(Layout.rowInsets)
                        .listRowBackground(selectedRowBackground(isSelected: selection == message.id))
                        .onAppear { Task { await viewModel.loadMoreIfNeeded(currentItem: message) } }
                }
            }
            .background(ListBlankClickBlocker())
            .background(ListSelectionHighlightDisabler())
            .background(AutoHidingOverlayScrollbars())
            .listStyle(.plain)
            .onAppear { scrollToSelectionIfNeeded(proxy) }
            .onChange(of: selection) { _, newValue in
                pendingScrollTarget = newValue
                scrollToSelectionIfNeeded(proxy)
            }
            .onChange(of: viewModel.filteredMessages.map(\.id)) { _, _ in
                scrollToSelectionIfNeeded(proxy)
            }
        }
    }

    private var searchResultsList: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                if searchViewModel.displayedResults.isEmpty {
                    searchPlaceholderRow
                } else {
                    Section {
                        ForEach(searchViewModel.displayedResults) { message in
                            MessageSearchResultRow(message: message, query: searchViewModel.query)
                                .tag(message.id)
                                .id(message.id)
                                .listRowInsets(Layout.rowInsets)
                                .listRowBackground(selectedRowBackground(isSelected: selection == message.id))
                                .onAppear { searchViewModel.loadMoreIfNeeded(currentItem: message) }
                        }
                        if searchViewModel.hasMore {
                            HStack {
                                Spacer()
                                ProgressView().progressViewStyle(.circular)
                                Spacer()
                            }
                            .listRowInsets(Layout.rowInsets)
                        }
                    } header: {
                        Text(localizationManager.localized("found_number_results", searchViewModel.totalResults))
                    }
                }
            }
            .listStyle(.plain)
            .background(ListBlankClickBlocker())
            .background(ListSelectionHighlightDisabler())
            .background(AutoHidingOverlayScrollbars())
            .onAppear { scrollToSelectionIfNeeded(proxy) }
            .onChange(of: selection) { _, newValue in
                pendingScrollTarget = newValue
                scrollToSelectionIfNeeded(proxy)
            }
            .onChange(of: searchViewModel.displayedResults.map(\.id)) { _, _ in
                scrollToSelectionIfNeeded(proxy)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                Text(localizationManager.localized("no_messages_yet"))
                    .font(.headline)
                Text(localizationManager.localized(
                    "you_can_use_the_pushgo_cli_or_other_integration_tools_to_send_a_test_push_to_the_current_device"
                ))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 48)
        .padding(.horizontal, 24)
    }

    private var searchPlaceholderRow: some View {
        MessageSearchPlaceholderView(
            imageName: "questionmark.circle",
            title: "no_matching_results",
            detailKey: "try_changing_a_keyword_or_adjusting_the_filter_conditions"
        )
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, alignment: .center)
        .listRowInsets(EdgeInsets())
    }

    private func scrollToSelectionIfNeeded(_ proxy: ScrollViewProxy) {
        guard let target = pendingScrollTarget ?? selection else { return }
        let existsInMessages = viewModel.filteredMessages.contains { $0.id == target }
        let existsInSearch = searchViewModel.displayedResults.contains { $0.id == target }
        guard existsInMessages || existsInSearch else { return }
        if reduceMotion {
            proxy.scrollTo(target, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(target, anchor: .center)
            }
        }
        pendingScrollTarget = nil
    }

    @ViewBuilder
    private func selectedRowBackground(isSelected: Bool) -> some View {
        if isSelected {
            Color.accentColor.opacity(0.06)
        } else {
            Color.clear
        }
    }
}
struct ListBlankClickBlocker: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.postsFrameChangedNotifications = true
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in
            await Task.yield()
            context.coordinator.attachIfNeeded(from: nsView)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: @unchecked Sendable {
        private weak var scrollView: NSScrollView?
        private weak var tableView: NSTableView?
        private weak var outlineView: NSOutlineView?
        private var monitor: Any?

        func attachIfNeeded(from anchor: NSView) {
            guard let sv = anchor.findAncestor(of: NSScrollView.self) else { return }
            if scrollView === sv, monitor != nil { return }

            detach()

            scrollView = sv
            if let ov = sv.documentView as? NSOutlineView {
                outlineView = ov
                if ov.selectionHighlightStyle != .none { ov.selectionHighlightStyle = .none }
            } else if let tv = sv.documentView as? NSTableView {
                tableView = tv
                if tv.selectionHighlightStyle != .none { tv.selectionHighlightStyle = .none }
            } else {
                if let tv = sv.documentView?.firstDescendant(of: NSTableView.self) {
                    tableView = tv
                    if tv.selectionHighlightStyle != .none { tv.selectionHighlightStyle = .none }
                }
                if let ov = sv.documentView?.firstDescendant(of: NSOutlineView.self) {
                    outlineView = ov
                    if ov.selectionHighlightStyle != .none { ov.selectionHighlightStyle = .none }
                }
            }

            guard monitor == nil else { return }
            guard let window = anchor.window else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self else { return event }
                guard event.window === window else { return event }
                guard let sv = self.scrollView else { return event }
                let pInWindow = event.locationInWindow
                let pInSV = sv.convert(pInWindow, from: nil)
                guard sv.contentView.bounds.contains(pInSV) else { return event }
                let pInDoc = sv.documentView?.convert(pInWindow, from: nil) ?? .zero

                if let ov = self.outlineView {
                    let row = ov.row(at: pInDoc)
                    if row == -1 {
                        return nil
                    }
                } else if let tv = self.tableView {
                    let row = tv.row(at: pInDoc)
                    if row == -1 {
                        return nil
                    }
                }

                return event
            }
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            scrollView = nil
            tableView = nil
            outlineView = nil
        }
    }
}
struct ListSelectionHighlightDisabler: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in
            await Task.yield()
            context.coordinator.attachIfNeeded(from: nsView)
        }
    }

    @MainActor
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var scrollView: NSScrollView?

        func attachIfNeeded(from anchor: NSView) {
            guard let sv = anchor.findAncestor(of: NSScrollView.self) else { return }
            if scrollView === sv { return }
            scrollView = sv

            if let ov = sv.documentView as? NSOutlineView {
                if ov.selectionHighlightStyle != .none { ov.selectionHighlightStyle = .none }
            } else if let tv = sv.documentView as? NSTableView {
                if tv.selectionHighlightStyle != .none { tv.selectionHighlightStyle = .none }
            } else {
                if let tv = sv.documentView?.firstDescendant(of: NSTableView.self) {
                    if tv.selectionHighlightStyle != .none { tv.selectionHighlightStyle = .none }
                }
                if let ov = sv.documentView?.firstDescendant(of: NSOutlineView.self) {
                    if ov.selectionHighlightStyle != .none { ov.selectionHighlightStyle = .none }
                }
            }
        }

        func detach() {
            scrollView = nil
        }
    }
}
struct AutoHidingOverlayScrollbars: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in
            await Task.yield()
            context.coordinator.attachIfNeeded(from: nsView)
        }
    }

    @MainActor
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var scrollView: NSScrollView?
        private var hideTask: Task<Void, Never>?

        func attachIfNeeded(from anchor: NSView) {
            guard let sv = anchor.findAncestor(of: NSScrollView.self) else { return }
            if scrollView === sv { return }

            detach()
            scrollView = sv

            applyScrollerStyle(to: sv)
            hideScrollers(animated: false)

            sv.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleBoundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: sv.contentView
            )
        }

        func detach() {
            hideTask?.cancel()
            hideTask = nil

            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: scrollView?.contentView
            )
            scrollView = nil
        }

        private func applyScrollerStyle(to sv: NSScrollView) {
            if sv.scrollerStyle != .overlay { sv.scrollerStyle = .overlay }
            if sv.autohidesScrollers != true { sv.autohidesScrollers = true }
            if sv.usesPredominantAxisScrolling != true { sv.usesPredominantAxisScrolling = true }
            if sv.verticalScroller?.controlSize != .mini { sv.verticalScroller?.controlSize = .mini }
            if sv.horizontalScroller?.controlSize != .mini { sv.horizontalScroller?.controlSize = .mini }
        }

        private func handleDidScroll() {
            showScrollers(animated: true)

            hideTask?.cancel()
            let scrollViewBox = WeakBox(scrollView)
            hideTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                guard let scrollView = scrollViewBox.value else { return }
                Self.hideScrollers(on: scrollView, animated: true)
            }
        }

        private func showScrollers(animated: Bool) {
            guard let sv = scrollView else { return }
            sv.verticalScroller?.isHidden = false
            sv.horizontalScroller?.isHidden = false

            let apply = {
                sv.verticalScroller?.alphaValue = 1.0
                sv.horizontalScroller?.alphaValue = 1.0
            }

            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.12
                    apply()
                }
            } else {
                apply()
            }
        }

        @objc
        private func handleBoundsChanged(_: Notification) {
            handleDidScroll()
        }

        private func hideScrollers(animated: Bool) {
            guard let sv = scrollView else { return }
            Self.hideScrollers(on: sv, animated: animated)
        }

        private static func hideScrollers(on sv: NSScrollView, animated: Bool) {
            let apply = {
                sv.verticalScroller?.alphaValue = 0.0
                sv.horizontalScroller?.alphaValue = 0.0
            }

            if animated {
                let scrollViewBox = WeakBox(sv)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    apply()
                } completionHandler: {
                    Task { @MainActor in
                        guard let sv = scrollViewBox.value else { return }
                        sv.verticalScroller?.isHidden = true
                        sv.horizontalScroller?.isHidden = true
                    }
                }
            } else {
                apply()
                sv.verticalScroller?.isHidden = true
                sv.horizontalScroller?.isHidden = true
            }
        }

        private final class WeakBox<Value: AnyObject>: @unchecked Sendable {
            weak var value: Value?

            init(_ value: Value?) {
                self.value = value
            }
        }
    }
}

@MainActor
private extension NSView {
    func findAncestor<T: NSView>(of type: T.Type) -> T? {
        var v: NSView? = self
        while let cur = v {
            if let match = cur as? T { return match }
            v = cur.superview
        }
        return nil
    }

    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for sub in subviews {
            if let t = sub as? T { return t }
            if let hit: T = sub.firstDescendant(of: type) { return hit }
        }
        return nil
    }
}
