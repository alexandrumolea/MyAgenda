//
//  NotebookPagesView.swift
//  MyAgenda
//
//  The main screen for a single notebook: Liquid Glass top bar (notebook
//  switcher, day strip, navigation), paged canvas with rich-text overlay, glass
//  pen toolbar and per-notebook calendar. The top bar can be hidden from the
//  "…" menu for a minimal, page-only mode; that menu button is the one control
//  that stays, always in the same corner.
//

import SwiftUI
import SwiftData
import PencilKit
import PhotosUI

struct NotebookPagesView: View {
    let notebook: Notebook
    let notebooks: [Notebook]
    @Binding var selectedNotebookID: UUID?
    var onNewNotebook: () -> Void
    var onEditNotebook: () -> Void
    var onShowTimer: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var pages: [JournalPage]
    // SwiftData refreshes only what a query fetches: a box reached through its
    // page keeps its old values after a change from another device, until the
    // app restarts. So pages show their boxes from these, not from the page.
    @Query private var liveTextBoxes: [TextBox]
    @Query private var liveChecklists: [ChecklistBox]
    @Query private var liveImages: [ImageBox]

    @State private var selection: UUID?
    @State private var pen = PenSettings()
    @State private var proxy = CanvasProxy()
    /// The pull-out calendar under the top bar.
    @State private var calendarReveal = CalendarReveal()
    /// Start-of-day dates with notes, for the dots in the strip and calendar.
    @State private var noteDays: Set<Date> = []
    @State private var noteCache = NoteDayCache()
    @State private var selectedImageID: UUID?
    @State private var croppingImage = false
    /// Minimal mode: the whole top bar is gone and only the floating "…" button
    /// stays. Persisted so the notebook opens the way it was left.
    @AppStorage("topBarHidden") private var topBarHidden = false
    /// The bottom pen toolbar, hidden by swiping it off to the right or from the menu.
    @AppStorage("penToolbarHidden") private var toolbarHidden = false
    /// Tiny clock in the top-left corner, only in minimal mode (the status bar
    /// clock is gone then). Floats over the page and takes no space.
    @AppStorage("showsMiniClock") private var showsMiniClock = false
    /// Staging flags for the bar's flow animation. `topBarHidden` is the
    /// persisted truth; these let the pills leave one after another, the
    /// remaining ones sliding right and pouring into the "…" button.
    @State private var hideNavPill = UserDefaults.standard.bool(forKey: "topBarHidden")
    @State private var hideDaysPill = UserDefaults.standard.bool(forKey: "topBarHidden")
    @State private var hideNotebookPill = UserDefaults.standard.bool(forKey: "topBarHidden")
    @State private var barFlow: Task<Void, Never>?
    /// Staging flag for the toolbar: docked at the right edge before it drains
    /// into the reopen handle (and right after it pours back out of it).
    @State private var toolsDocked = false
    @State private var toolsFlow: Task<Void, Never>?
    /// Pull-past-the-last-page progress (only the hint observes it).
    @State private var pagePull = PagePullState()
    /// Where the docked pen toolbar takes touches (see ToolbarDock).
    @State private var dockRegions = DockHitRegions()
    /// Live safe-area insets of the screen. The page itself always runs edge
    /// to edge; only the floating controls use these.
    @State private var safeTop: CGFloat = 0
    /// The page to reopen, if it hasn't synced in yet (with when it was asked).
    @State private var pendingPage: (id: UUID, since: Date)?
    private let position = ReadingPosition.shared
    /// The "liquid snap" used whenever glass appears, hides or flows.
    static let liquid = Animation.spring(duration: 0.5, bounce: 0.25)
    /// How a pill or the toolbar pours out of / drains into its glass target.
    /// Pouring out fades in while unfolding from the target. Draining keeps the
    /// pill fully opaque and squashes it to a droplet at its trailing edge that
    /// slides inside the target's glass, where the two blend — no fade, so it
    /// reads as liquid being drawn in rather than as a dissolve.
    static let drain = AnyTransition.asymmetric(
        insertion: .scale(scale: 0.2, anchor: .trailing)
            .combined(with: .offset(x: 48))
            .combined(with: .opacity),
        removal: .scale(scale: 0.08, anchor: .trailing)
            .combined(with: .offset(x: 48))
    )
    @State private var editingTextBoxID: UUID?
    /// A text or checklist is being moved: the page doesn't scroll meanwhile.
    @State private var boxLifted = false
    /// iPhone: the box just started by a tap, scrolled into view.
    @State private var revealTextBoxID: UUID?
    @State private var showTagsSidebar = false
    @State private var showOverview = false
    @State private var phoneZoom: CGFloat = 1
    @GestureState private var phonePinch: CGFloat = 1
    @State private var showPhotoPicker = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var editingChecklistID: UUID?
    /// A long-press that selected a checklist should not also paste an image
    /// (the page's paste gesture is a long-press too); this suppresses it once.
    @State private var suppressPaste = false
    @State private var showRename = false
    @State private var renameText = ""

    /// Whether each page has notes, re-checked only when the page changes.
    private final class NoteDayCache {
        var entries: [UUID: (stamp: Date, hasNotes: Bool)] = [:]
    }

    private struct PreparedImage: Sendable {
        var data: Data
        var aspectRatio: Double
    }

    init(notebook: Notebook,
         notebooks: [Notebook],
         selectedNotebookID: Binding<UUID?>,
         onNewNotebook: @escaping () -> Void,
         onEditNotebook: @escaping () -> Void,
         onShowTimer: @escaping () -> Void) {
        self.notebook = notebook
        self.notebooks = notebooks
        self._selectedNotebookID = selectedNotebookID
        self.onNewNotebook = onNewNotebook
        self.onEditNotebook = onEditNotebook
        self.onShowTimer = onShowTimer
        let nbID = notebook.id
        _pages = Query(
            filter: #Predicate<JournalPage> { $0.notebookID == nbID },
            sort: [SortDescriptor(\.day), SortDescriptor(\.orderInDay)]
        )
        _liveTextBoxes = Query(filter: #Predicate<TextBox> { $0.page?.notebookID == nbID })
        _liveChecklists = Query(filter: #Predicate<ChecklistBox> { $0.page?.notebookID == nbID })
        _liveImages = Query(filter: #Predicate<ImageBox> { $0.page?.notebookID == nbID })
    }

    private var store: PageStore { PageStore(context: context) }
    private var selectedPage: JournalPage? { pages.first { $0.id == selection } }
    /// On iPhone the page is view-only (no drawing) and fit-to-width.
    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private let phoneLogicalWidth: CGFloat = 1024   // iPad-like page width
    static let tagsPanelWidth: CGFloat = 280
    /// iPad: room the bars leave on the left for the open tags panel.
    private var panelInset: CGFloat { showTagsSidebar && !isPhone ? Self.tagsPanelWidth : 0 }

    var body: some View {
        ZStack {
            pageArea
                // The bar floats over the page; the page scrolls underneath it
                // (see `pageTopInset`), like any iOS scroll view under glass.
                .overlay(alignment: .top) {
                    CalendarOverlay(
                        reveal: calendarReveal,
                        selectedDay: selectedPage?.day ?? .now,
                        markedDays: noteDays,
                        topInset: topRowInset + Self.barHeight + 6
                    ) { day in
                        goToDay(day)
                        calendarReveal.settle(open: false)
                    }
                    .padding(.leading, panelInset)
                }
                .overlay(alignment: .topTrailing) { topRow }
                .overlay(alignment: .top) {
                    if topBarHidden && showsMiniClock {
                        miniClock
                            .transition(.scale(scale: 0.7, anchor: .top).combined(with: .opacity))
                    }
                }
                .animation(Self.liquid, value: topBarHidden)
                .animation(Self.liquid, value: showsMiniClock)
                .animation(Self.liquid, value: safeTop)
                // The paper always runs edge to edge, in both modes, so hiding
                // the bar never resizes the page (and its canvas) mid-animation.
                // The status bar simply sits over the paper, as in any iOS app.
                .ignoresSafeArea(.container, edges: .vertical)

            bottomToolbar
        }
        // iPad: the panel floats over the page, so opening it never resizes the
        // page (and its canvas). iPhone: presented as a sheet (below) so it
        // isn't squeezed on the narrow screen.
        .overlay(alignment: .leading) {
            if showTagsSidebar && !isPhone {
                TagsSidebar(
                    page: selectedPage,
                    notebookPages: pages,
                    onJump: { selection = $0 },
                    onClose: { withAnimation(.snappy(duration: 0.28)) { showTagsSidebar = false } }
                )
                .frame(width: Self.tagsPanelWidth)
                .frame(maxHeight: .infinity)
                // Same as the inset-grouped list, so header and list read as one
                // surface; unlike secondarySystemBackground it stays apart from
                // dark paper. It runs under the status bar and home indicator and
                // takes the touches there, so none reach the page underneath. The
                // shadow sits on it alone: on the whole panel it would render the
                // list offscreen on every scroll frame.
                .background {
                    Color(.systemGroupedBackground)
                        .shadow(color: .black.opacity(0.15), radius: 12, x: 3)
                        .ignoresSafeArea()
                }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color(.opaqueSeparator)).frame(width: 1)
                        .ignoresSafeArea()
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .tint(notebook.accentColor)
        // Minimal mode hides the status bar. The home indicator is deliberately
        // left alone: hiding it (persistentSystemOverlays) makes UIKit defer
        // every touch near the screen edges ("System gesture gate timed out").
        .statusBarHidden(topBarHidden)
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { top in
            safeTop = top
        }
        .animation(.snappy(duration: 0.28), value: showTagsSidebar)
        // Dark paper turns the whole app dark (bars, menus, status bar), so it
        // all reads as one inverted page; other paper leaves it to the system.
        .preferredColorScheme(selectedPaper.isDark ? .dark : nil)
        .sheet(isPresented: Binding(
            get: { isPhone && showTagsSidebar },
            set: { if isPhone { showTagsSidebar = $0 } }
        )) {
            TagsSidebar(
                page: selectedPage,
                notebookPages: pages,
                onJump: { selection = $0; showTagsSidebar = false },
                onClose: { showTagsSidebar = false }
            )
        }
        // Leaving the app: nothing may stay behind in the save delay, or it
        // would never reach iCloud (and could be lost).
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            proxy.flushPendingSave?()
            try? context.save()
        }
        .onChange(of: selection) { oldValue, newValue in
            // Persist any pending drawing on the page we're leaving BEFORE we
            // consider pruning it — otherwise a just-drawn page can look empty
            // (debounced save not yet flushed) and get deleted.
            proxy.flushPendingSave?()
            phoneZoom = 1
            selectedImageID = nil
            croppingImage = false
            // Leaving the page ends any editing: otherwise the keyboard stays up
            // and typing lands in a box on the page you just left.
            editingTextBoxID = nil
            editingChecklistID = nil
            if let newValue { position.savePage(newValue, in: notebook.id) }
            // Prune the empty page we left AFTER the paging transition settles —
            // deleting it mid-swipe mutates the TabView's page array and leaves
            // the pager stuck between two half-pages.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard selection == newValue else { return }
                pruneIfEmpty(oldValue, movingTo: newValue)
            }
        }
        .overlay {
            if showOverview {
                PageOverview(
                    pages: pages,
                    selection: selection,
                    accent: notebook.accentColor,
                    onSelect: { id in
                        selection = id
                        withAnimation(.snappy(duration: 0.3)) { showOverview = false }
                    },
                    onDelete: deletePage,
                    onClose: { withAnimation(.snappy(duration: 0.3)) { showOverview = false } }
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        // Another device moved to another page of this notebook just now.
        .onChange(of: position.remoteJump) { _, _ in
            guard position.notebookID == notebook.id,
                  let id = position.pageID(in: notebook.id), id != selection else { return }
            restorePage(id)
        }
        .onChange(of: pages.map(\.id)) { _, ids in
            guard let pending = pendingPage else { return }
            if ids.contains(pending.id), Date.now.timeIntervalSince(pending.since) < 30 {
                selection = pending.id
            }
            if ids.contains(pending.id) || Date.now.timeIntervalSince(pending.since) >= 30 {
                pendingPage = nil
            }
        }
        .onAppear {
            bootstrap()
            // Keep the staging flags in step with the persisted state (no flow).
            hideNavPill = topBarHidden
            hideDaysPill = topBarHidden
            hideNotebookPill = topBarHidden
        }
        .onChange(of: pages.map(\.updatedAt), initial: true) { _, _ in refreshNoteDays() }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickedPhoto, matching: .images)
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = await Self.prepareImage(rawData: data) {
                    await MainActor.run { addImageBox(image) }
                }
                await MainActor.run { pickedPhoto = nil }
            }
        }
        .alert("Nume pagină", isPresented: $showRename) {
            TextField("Nume", text: $renameText)
            Button("Salvează") {
                selectedPage?.title = renameText.trimmingCharacters(in: .whitespaces)
                selectedPage?.updatedAt = .now
                try? context.save()
            }
            Button("Anulează", role: .cancel) {}
        } message: {
            Text("Dă un nume paginii pentru cuprins.")
        }
    }

    // MARK: - Top bar

    /// Height of the glass pills and of the floating menu button.
    private static let barHeight: CGFloat = 44
    private static let barInset: CGFloat = 16
    /// Space above the page so a fresh page starts right below the bar while
    /// its content still flows under the glass when scrolled. Zero in minimal
    /// mode. The scroll view already keeps its content below the status bar, so
    /// only the bar itself is counted. It is padding inside the scroll content
    /// (not a content margin), so the page glides up with the bar's spring.
    private var pageTopInset: CGFloat { topBarHidden ? 0 : Self.barHeight + 8 + 4 }

    /// Where the bar row sits: under the status bar when it is shown; without
    /// it, below the top-edge gesture zone (and below the sensor housing on
    /// iPhone, whose safe area remains).
    private var topRowInset: CGFloat { topBarHidden ? max(20, safeTop + 4) : safeTop + 8 }

    /// Three glass pills — notebook (tags + switcher), day strip, navigation —
    /// and the "…" button, in one container so their glass blends when they
    /// touch. The flow is driven by layout: the pills leave one at a time from
    /// the right; each time one goes, the HStack slides the rest towards the
    /// button, and each pill drains into it with `drain`. Showing runs the same
    /// in reverse, the pills pouring out of the button and spreading left.
    private var topRow: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 14) {
                if !hideNotebookPill {
                    HStack(spacing: 2) {
                        barButton("tag", active: showTagsSidebar) {
                            withAnimation(.snappy(duration: 0.28)) { showTagsSidebar.toggle() }
                        }
                        notebookMenu
                    }
                    .padding(.horizontal, 2)
                    // Not `.interactive()`: it hosts a Menu, and the press gesture
                    // of interactive glass competes with the menu's tap.
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectTransition(.identity)
                    .transition(Self.drain)
                }

                if !hideDaysPill {
                    DateStrip(selectedDay: selectedPage?.day ?? .now, markedDays: noteDays) { day in
                        // The current day again: same as pulling the calendar out.
                        if let current = selectedPage?.day,
                           Calendar.current.isDate(day, inSameDayAs: current) {
                            calendarReveal.settle(open: !calendarReveal.isOpen)
                        } else {
                            goToDay(day)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.barHeight)
                    .mask(edgeFade)
                    .glassEffect(.regular, in: .capsule)
                    .glassEffectTransition(.identity)
                    // Pull down on the days to bring the calendar out of them.
                    .gesture(VerticalPullGesture(reveal: calendarReveal))
                    .transition(Self.drain)
                }

                if !hideNavPill {
                    barButton("square.grid.2x2") {
                        openOverview()
                    }
                    .padding(2)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .glassEffectTransition(.identity)
                    .transition(Self.drain)
                }

                pageMenuButton
            }
        }
        .padding(.horizontal, Self.barInset)
        .padding(.leading, panelInset)
        .padding(.top, topRowInset)
    }

    /// Fades the day strip into the capsule's rounded ends.
    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 20)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 20)
        }
    }

    /// Live time, centred at the top and re-rendered on the minute. Touches
    /// pass through to the page.
    private var miniClock: some View {
        TimelineView(.everyMinute) { context in
            Text(context.date, style: .time)
                .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
        }
        .padding(.top, max(22, safeTop + 6))
        .allowsHitTesting(false)
    }

    // MARK: - Flow (staged hide / show)

    /// Hide: nav pill drains into the button; the day strip stretches to meet
    /// it and, once there, drains; the notebook pill glides across and, once
    /// it has arrived, drains too. Only then does the status bar go, so the row
    /// stays put while the pills flow. The pauses let each pill reach the
    /// button before it is drawn in (a pill removed mid-glide would vanish in
    /// the air). Show: the reverse, with the stages overlapping more tightly.
    private func setTopBar(hidden: Bool) {
        barFlow?.cancel()
        barFlow = Task {
            if hidden {
                withAnimation(Self.liquid) { hideNavPill = true }
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                withAnimation(Self.liquid) { hideDaysPill = true }
                try? await Task.sleep(for: .milliseconds(340))
                guard !Task.isCancelled else { return }
                withAnimation(Self.liquid) { hideNotebookPill = true; topBarHidden = true }
            } else {
                withAnimation(Self.liquid) { topBarHidden = false; hideNotebookPill = false }
                try? await Task.sleep(for: .milliseconds(110))
                guard !Task.isCancelled else { return }
                withAnimation(Self.liquid) { hideDaysPill = false }
                try? await Task.sleep(for: .milliseconds(110))
                guard !Task.isCancelled else { return }
                withAnimation(Self.liquid) { hideNavPill = false }
            }
        }
    }

    /// Hide: the capsule glides to the right edge, then drains into the handle.
    /// Show: it pours out of the handle at the edge, then glides back to centre.
    private func setToolbar(hidden: Bool) {
        toolsFlow?.cancel()
        toolsFlow = Task {
            if hidden {
                withAnimation(Self.liquid) { toolsDocked = true }
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                withAnimation(Self.liquid) { toolbarHidden = true }
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                toolsDocked = false   // off-screen bookkeeping, no animation
            } else {
                toolsDocked = true
                withAnimation(Self.liquid) { toolbarHidden = false }
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                withAnimation(Self.liquid) { toolsDocked = false }
            }
        }
    }

    private func barButton(_ system: String, active: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
    }

    private var notebookMenu: some View {
        Menu {
            notebookMenuItems
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.accentColor)
                Text(notebook.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var notebookMenuItems: some View {
        Picker("Notebook", selection: $selectedNotebookID) {
            ForEach(notebooks) { nb in
                Label(nb.title, systemImage: "book.closed.fill").tag(Optional(nb.id))
            }
        }
        .pickerStyle(.inline)

        Divider()
        Button { onNewNotebook() } label: { Label("Notebook nou", systemImage: "plus") }
        Button { onEditNotebook() } label: { Label("Editează „\(notebook.title)”", systemImage: "pencil") }
    }

    // MARK: - "…" menu

    /// Glass button in the top-right corner — the one control that survives
    /// minimal mode. From here the bar can be hidden and brought back.
    private var pageMenuButton: some View {
        // UIKit button + native menu: the whole circle opens it (a SwiftUI Menu
        // only reacted on the dots). The glass stays SwiftUI so it still
        // blends with the pills.
        GlassMenuButton(systemImage: "ellipsis") { pageMenuElements() }
            .frame(width: Self.barHeight, height: Self.barHeight)
            .glassEffect(.regular, in: .circle)
    }

    /// The "…" menu, rebuilt each time it opens.
    private func pageMenuElements() -> [UIMenuElement] {
        func action(_ title: String, _ image: String, attributes: UIMenuElement.Attributes = [],
                    on: Bool = false, _ handler: @escaping () -> Void) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: image), attributes: attributes,
                     state: on ? .on : .off) { _ in handler() }
        }

        var view: [UIMenuElement] = [
            action(topBarHidden ? "Arată bara" : "Ascunde bara",
                   topBarHidden ? "arrow.down.to.line.compact" : "arrow.up.to.line.compact") {
                setTopBar(hidden: !topBarHidden)
            },
            action(toolbarHidden ? "Arată instrumentele" : "Ascunde instrumentele",
                   toolbarHidden ? "pencil.and.outline" : "pencil.slash") {
                setToolbar(hidden: !toolbarHidden)
            }
        ]
        if topBarHidden {
            view.append(action("Ceas mic", "clock", on: showsMiniClock) { showsMiniClock.toggle() })
        }
        var sections: [UIMenuElement] = [UIMenu(options: .displayInline, children: view)]

        // With the bar hidden, the essentials move in here so the page stays usable.
        if topBarHidden {
            let notebookChoices = notebooks.map { nb in
                action(nb.title, "book.closed.fill", on: nb.id == notebook.id) { selectedNotebookID = nb.id }
            }
            let notebookMenu = UIMenu(title: notebook.title, image: UIImage(systemName: "book.closed.fill"),
                                      children: [
                UIMenu(options: .displayInline, children: notebookChoices),
                action("Notebook nou", "plus") { onNewNotebook() },
                action("Editează „\(notebook.title)”", "pencil") { onEditNotebook() }
            ])
            sections.append(UIMenu(options: .displayInline, children: [
                notebookMenu,
                action("Pagină nouă", "plus") { addPage() },
                action("Calendar", "calendar") { calendarReveal.settle(open: true) },
                action("Toate paginile", "square.grid.2x2") {
                    openOverview()
                },
                action(showTagsSidebar ? "Ascunde etichetele" : "Etichete", "tag") {
                    withAnimation(.snappy(duration: 0.28)) { showTagsSidebar.toggle() }
                }
            ]))
        }

        if let page = selectedPage {
            sections.append(UIMenu(options: .displayInline, children: [
                action(page.isFavorite ? "Scoate din favorite" : "Adaugă la favorite",
                       page.isFavorite ? "star.slash" : "star") {
                    page.isFavorite.toggle()
                    page.updatedAt = .now
                    try? context.save()
                },
                action("Redenumește pagina", "character.cursor.ibeam") {
                    renameText = page.title
                    showRename = true
                },
                paperMenu(for: page, action: action)
            ]))
            sections.append(UIMenu(options: .displayInline, children: [
                action("Șterge pagina", "trash", attributes: .destructive) { deletePage(page) }
            ]))
        }
        return sections
    }

    /// Paper color, for this page or for the whole notebook.
    private func paperMenu(for page: JournalPage,
                           action: (String, String, UIMenuElement.Attributes, Bool,
                                    @escaping () -> Void) -> UIAction) -> UIMenu {
        let pageChoices = [action("Ca tot caietul", "book.closed", [], page.paperRaw.isEmpty) {
            setPaper(nil, of: page)
        }] + PaperColor.allCases.map { paper in
            action(paper.label, paper.symbol, [], page.paperRaw == paper.rawValue) {
                setPaper(paper, of: page)
            }
        }
        let notebookChoices = PaperColor.allCases.map { paper in
            action(paper.label, paper.symbol, [], notebook.paper == paper) { setNotebookPaper(paper) }
        }
        return UIMenu(title: "Hârtie", image: UIImage(systemName: paper(of: page).symbol), children: [
            UIMenu(title: "Pagina aceasta", options: .displayInline, children: pageChoices),
            UIMenu(title: "Tot caietul", options: .displayInline, children: notebookChoices)
        ])
    }

    // MARK: - Page area

    @ViewBuilder private var pageArea: some View {
        if pages.isEmpty {
            ContentUnavailableView(
                "Nicio pagină încă",
                systemImage: "book.closed",
                description: Text("Apasă + ca să adaugi prima pagină.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TabView(selection: $selection) {
                ForEach(pages) { page in
                    pageContent(for: page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Same color as the paper, so the area under the floating bar reads
            // as the page continuing, not as a margin. Also under the keyboard:
            // on iPhone the page stops above it, and the editing bar's clear
            // strip showed the window (black in dark mode) instead of paper.
            .background { selectedPaper.color.ignoresSafeArea() }
            // iPad: don't push the page up when the keyboard appears — text
            // stays put. iPhone: make room, so a box tapped low stays visible.
            .ignoresSafeArea(.keyboard, edges: isPhone ? [] : .bottom)
            // Pulling past the last page: a glass "+" grows from the right edge.
            .overlay(alignment: .trailing) { PagePullHint(state: pagePull) }
            .simultaneousGesture(
                MagnifyGesture()
                    .onEnded { value in
                        if !isPhone, value.magnification < 0.75 {
                            openOverview()
                        }
                    }
            )
            // A finger tap on the page closes the tags sidebar (Pencil still
            // draws — the canvas consumes Pencil touches).
            .simultaneousGesture(
                TapGesture().onEnded {
                    if showTagsSidebar {
                        withAnimation(.snappy(duration: 0.28)) { showTagsSidebar = false }
                    }
                }
            )
        }
    }

    /// Pen toolbar layer (see ToolbarDock): always just above the home
    /// indicator, and hidden while the editing bar is up.
    @ViewBuilder private var bottomToolbar: some View {
        if !pages.isEmpty {
            ToolbarDock(regions: dockRegions) {
                BottomToolbarLayer(
                    pen: pen, proxy: proxy, regions: dockRegions, isPhone: isPhone,
                    // While editing, the bar above the keyboard is the only one.
                    showsToolbar: editingTextBoxID == nil && editingChecklistID == nil,
                    toolbarHidden: toolbarHidden, toolsDocked: toolsDocked,
                    leadingInset: panelInset,
                    onAddText: addTextBoxOnFreeSpot,
                    onAddChecklist: addChecklistOnFreeSpot,
                    onAddPhoto: { showPhotoPicker = true },
                    onAddPage: addPage,
                    onTimer: onShowTimer,
                    onHide: { setToolbar(hidden: true) },
                    onShow: { setToolbar(hidden: false) }
                )
                .tint(notebook.accentColor)
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func pageContent(for page: JournalPage) -> some View {
        GeometryReader { geo in
            let viewport = geo.size
            if isPhone {
                // Show the full iPad-width page scaled to fit the phone width;
                // pinch to zoom in/out (view-only, so scaling is fine).
                let logicalW = page.canvasWidth > 1 ? CGFloat(page.canvasWidth) : phoneLogicalWidth
                let fitScale = viewport.width / logicalW
                let zoom = min(max(phoneZoom * phonePinch, 0.5), 4)
                let scale = fitScale * zoom
                // A box just started by a tap, while it is being written.
                let revealBox = textBoxes(of: page)
                    .first { $0.id == revealTextBoxID && $0.id == editingTextBoxID }
                // More than a screen of paper, as on iPad, so the page always
                // scrolls and every tap lands on it; and a screen below a new box,
                // so it can scroll above the keyboard.
                let logicalH = max(CGFloat(page.canvasHeight), CGFloat(page.contentHeight),
                                   logicalW * 1.3, viewport.height * 1.35 / fitScale,
                                   revealBox.map { CGFloat($0.y) * logicalW + viewport.height / scale } ?? 0)
                let pageSize = CGSize(width: logicalW, height: logicalH)

                ScrollViewReader { reader in
                    ScrollView([.vertical, .horizontal], showsIndicators: true) {
                        ZStack(alignment: .topLeading) {
                            // New text reads at ~17pt on screen despite the scaled-down page.
                            pageLayers(for: page, pageSize: pageSize,
                                       textSize: min(max(17 / fitScale, 18), 48), displayScale: scale)
                                .frame(width: logicalW, height: logicalH, alignment: .topLeading)
                                .scaleEffect(scale, anchor: .topLeading)
                                .frame(width: logicalW * scale, height: logicalH * scale, alignment: .topLeading)

                            // A new box may start below the screen or under the
                            // keyboard: scroll it up to the top third, at its left.
                            if let box = revealBox {
                                Color.clear
                                    .frame(width: 1, height: 1)
                                    .padding(.leading, CGFloat(box.x) * logicalW * scale)
                                    .padding(.top, CGFloat(box.y) * logicalW * scale)
                                    .id(box.id)
                                    // After the keyboard is up, which scrolls the page itself.
                                    .task {
                                        try? await Task.sleep(for: .milliseconds(350))
                                        withAnimation(.snappy(duration: 0.3)) {
                                            reader.scrollTo(box.id, anchor: UnitPoint(x: 0, y: 0.3))
                                        }
                                    }
                            }
                        }
                        .padding(.top, pageTopInset)
                    }
                    // Zoomed out, content smaller than the screen stays at the top
                    // instead of being centred (which left a band above the page).
                    .defaultScrollAnchor(.topLeading, for: .alignment)
                    // Beyond the page (zoomed out, under the bar), the same paper.
                    .background(paper(of: page).color)
                    .scrollDisabled(boxLifted)
                    // Near the bottom, the page grows, as on iPad: there is always
                    // more paper below. Only once you've scrolled, so just opening
                    // a page never changes it.
                    .onScrollGeometryChange(for: Bool.self) { scrollGeo in
                        scrollGeo.contentOffset.y + scrollGeo.contentInsets.top > 20
                            && scrollGeo.contentOffset.y + scrollGeo.containerSize.height
                                > scrollGeo.contentSize.height - 140
                    } action: { _, atBottom in
                        if atBottom {
                            growPage(page, currentHeight: logicalH, viewport: viewport.height / scale)
                        }
                    }
                    .simultaneousGesture(
                        MagnifyGesture()
                            .updating($phonePinch) { value, state, _ in state = value.magnification }
                            .onEnded { value in
                                phoneZoom = min(max(phoneZoom * value.magnification, 0.5), 4)
                            }
                    )
                }
            } else {
                let pageWidth = viewport.width
                let pageHeight = max(viewport.height * 1.35, CGFloat(page.contentHeight))
                let pageSize = CGSize(width: pageWidth, height: pageHeight)

                ScrollView(.vertical, showsIndicators: true) {
                    pageLayers(for: page, pageSize: pageSize)
                        .frame(width: pageWidth, height: pageHeight, alignment: .topLeading)
                        .padding(.top, pageTopInset)
                }
                // Under the bar, the same paper (also while swiping between pages).
                .background(paper(of: page).color)
                .scrollDisabled(boxLifted)
                .onScrollGeometryChange(for: Bool.self) { scrollGeo in
                    scrollGeo.contentOffset.y + scrollGeo.containerSize.height
                        > scrollGeo.contentSize.height - 140
                } action: { _, atBottom in
                    if atBottom { growPage(page, currentHeight: pageHeight, viewport: viewport.height) }
                }
            }
        }
        .background {
            if page.id == pages.last?.id {
                PagerPullDetector(state: pagePull) { addPageFromPull() }
            }
        }
        .tag(Optional(page.id))
    }

    @ViewBuilder
    private func pageLayers(for page: JournalPage, pageSize: CGSize,
                            textSize: CGFloat = 18, displayScale: CGFloat = 1) -> some View {
        let paper = paper(of: page)
        ZStack(alignment: .topLeading) {
            PaperBackground(style: notebook.pageStyle, paper: paper)

            PageCanvasView(
                page: page,
                tool: pen.pkTool,
                toolKind: pen.tool,
                proxy: proxy,
                isActive: page.id == selection,
                paper: paper,
                onSqueeze: { pen.toggleEraser() },
                onDoubleTap: { pen.toggleLasso() },
                // iPad: double tap the bare page to start writing right there.
                onFingerDoubleTap: isPhone ? nil : { point in
                    addTextBox(at: point, on: page, pageSize: pageSize)
                }
            )

            // Custom variable-width pen engine (GoodNotes-like). Active only for
            // the pen tool; other tools use PencilKit directly. Off on iPhone.
            InkOverlay(
                isActive: !isPhone && pen.tool == .pen,
                color: UIColor(pen.penColor),
                previewColor: paper.shown(UIColor(pen.penColor)),
                baseWidth: pen.width,
                inkType: pen.penInk.inkType,
                ballpoint: pen.penInk.ballpointTuning,
                proxy: proxy
            )

            // iPhone (no Pencil): a finger tap on the empty page starts a text
            // box at the left margin of the first free line, wherever the tap
            // lands. Text and photos sit above this layer, so a tap on one goes
            // to it instead. While something is being edited, the dismiss
            // layer below sits on top and the first tap just ends that edit.
            if isPhone {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { _ in
                            guard selectedImageID == nil else {
                                if !croppingImage {
                                    withAnimation(.snappy(duration: 0.2)) { selectedImageID = nil }
                                }
                                return
                            }
                            let spot = freeSpot(on: page, pageSize: pageSize, textSize: textSize)
                            addTextBox(at: spot, on: page, pageSize: pageSize)
                            revealTextBoxID = editingTextBoxID
                        }
                    )
            }

            // Tap an empty spot to dismiss a selected/editing element.
            if editingChecklistID != nil || editingTextBoxID != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.2)) {
                            editingChecklistID = nil
                            editingTextBoxID = nil
                        }
                    }
            }

            ForEach(imageBoxes(of: page)) { box in
                ImageBoxContainer(
                    box: box,
                    pageSize: pageSize,
                    scale: displayScale,
                    isSelected: selectedImageID == box.id,
                    onSelect: { selected in
                        selectedImageID = selected ? box.id : nil
                        editingChecklistID = nil
                        editingTextBoxID = nil
                    },
                    onMove: { nx, ny in
                        box.x = nx; box.y = ny; page.updatedAt = .now
                    },
                    onResize: { wf in
                        box.widthFraction = wf; page.updatedAt = .now
                    },
                    onDelete: {
                        selectedImageID = nil
                        deleteImageBox(box, on: page)
                    },
                    onCrop: { rect in
                        box.applyCrop(rect)
                        page.updatedAt = .now
                        try? context.save()
                    },
                    onCropModeChange: { croppingImage = $0 }
                )
                .zIndex(selectedImageID == box.id ? 5 : 0)
            }

            ForEach(checklistBoxes(of: page)) { box in
                ChecklistBoxContainer(
                    box: box,
                    pageSize: pageSize,
                    scale: displayScale,
                    fontSize: max(19, textSize),
                    editTapCount: isPhone ? 1 : 2,
                    paper: paper,
                    accent: notebook.accentColor,
                    isEditing: editingChecklistID == box.id,
                    onSetEditing: { editing in
                        selectedImageID = nil
                        editingChecklistID = editing ? box.id : nil
                    },
                    onMove: { nx, ny in box.x = nx; box.y = ny; page.updatedAt = .now },
                    onResize: { wf in box.widthFraction = wf; page.updatedAt = .now },
                    onLift: liftBox,
                    onDelete: { deleteChecklist(box, on: page) }
                )
            }

            // A box never written in (left by a closed app, or still being
            // started on the other device) is invisible: it is left out, so it
            // does not swallow taps meant for the empty page.
            ForEach(textBoxes(of: page).filter { !$0.rtfData.isEmpty || $0.id == editingTextBoxID }) { box in
                TextBoxContainer(
                    box: box,
                    pageSize: pageSize,
                    isEditing: editingTextBoxID == box.id,
                    textSize: textSize,
                    scale: displayScale,
                    accent: notebook.accentColor,
                    paper: paper,
                    // iPhone: one tap edits (double tap is for iPad, where a
                    // single finger tap is free for other things).
                    editTapCount: isPhone ? 1 : 2,
                    onBeginEdit: {
                        selectedImageID = nil
                        editingTextBoxID = box.id
                    },
                    onEndEdit: { handleEndEdit(box) },
                    onMove: { nx, ny in
                        box.x = nx; box.y = ny; box.updatedAt = .now
                        page.updatedAt = .now
                    },
                    onResize: { wf in
                        box.widthFraction = wf; box.updatedAt = .now
                        page.updatedAt = .now
                    },
                    onLift: liftBox
                )
            }
        }
        // Overlays (checklist, text) follow the paper, not the system: on white
        // paper in dark mode SwiftUI's .primary would be white and vanish.
        .environment(\.colorScheme, paper.colorScheme)
        .contentShape(Rectangle())
        // A tap anywhere outside the selected photo deselects it. Simultaneous,
        // so it never gets in the way of the canvas or the page's other layers.
        .simultaneousGesture(
            SpatialTapGesture().onEnded { value in
                deselectImage(unlessTapped: value.location, on: page, pageSize: pageSize)
            },
            including: isPhone ? .subviews : .all
        )
        // Long-press an empty spot to paste a clipboard image there. Simultaneous
        // so it fires over the canvas without blocking Pencil drawing.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                .onEnded { value in
                    if case .second(true, let drag?) = value {
                        if suppressPaste { suppressPaste = false; return }
                        pasteImage(at: drag.location, on: page, pageSize: pageSize)
                    }
                }
        )
    }

    private var selectedPaper: PaperColor { selectedPage.map(paper(of:)) ?? notebook.paper }

    /// The page's own paper, else this notebook's.
    private func paper(of page: JournalPage) -> PaperColor {
        PaperColor(rawValue: page.paperRaw) ?? notebook.paper
    }

    /// The same as the notebook's is stored as "none", so the page follows
    /// the notebook if that changes later.
    private func setPaper(_ paper: PaperColor?, of page: JournalPage) {
        page.paperRaw = paper == nil || paper == notebook.paper ? "" : paper!.rawValue
        page.updatedAt = .now
        try? context.save()
    }

    /// The whole notebook: every page, including those with their own color.
    private func setNotebookPaper(_ paper: PaperColor) {
        notebook.paper = paper
        for page in pages where !page.paperRaw.isEmpty {
            page.paperRaw = ""
            page.updatedAt = .now
        }
        try? context.save()
    }

    /// A text or checklist held to be moved: the page stays still under the
    /// finger until it is let go, and the hold must not also paste on the page.
    private func liftBox(_ lifted: Bool) {
        if lifted { suppressPaste = true }
        boxLifted = lifted
    }

    private func textBoxes(of page: JournalPage) -> [TextBox] {
        liveTextBoxes.filter { $0.page?.id == page.id }.sorted { $0.createdAt < $1.createdAt }
    }

    private func imageBoxes(of page: JournalPage) -> [ImageBox] {
        liveImages.filter { $0.page?.id == page.id }.sorted { $0.createdAt < $1.createdAt }
    }

    private func checklistBoxes(of page: JournalPage) -> [ChecklistBox] {
        liveChecklists.filter { $0.page?.id == page.id }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Y is stored as a fraction of the page WIDTH (stable), so it can exceed 1
    /// on a tall page. This upper bound keeps a new element on the visible page.
    private func maxYFraction(_ pageSize: CGSize) -> Double {
        Double((pageSize.height - 20) / pageSize.width)
    }

    private func addChecklist(at point: CGPoint, on page: JournalPage, pageSize: CGSize) {
        let nx = min(max(Double(point.x / pageSize.width), 0), 0.85)
        let ny = min(max(Double(point.y / pageSize.width), 0), maxYFraction(pageSize))
        let box = ChecklistBox(x: nx, y: ny, page: page)
        box.widthFraction = max(0.3, 0.97 - nx)   // like text: to the page's edge
        context.insert(box)
        page.updatedAt = .now
        try? context.save()
        editingChecklistID = box.id
    }

    private func deleteChecklist(_ box: ChecklistBox, on page: JournalPage) {
        context.delete(box)
        page.updatedAt = .now
        try? context.save()
    }

    /// Downscale + re-encode the picked photo, then place it on the page.
    private func addImageBox(_ image: PreparedImage) {
        guard let page = selectedPage else { return }
        insertImage(image, x: 0.18, y: 0.14, on: page)
    }

    private static func prepareImage(rawData: Data) async -> PreparedImage? {
        await Task.detached(priority: .userInitiated) {
            guard let ui = UIImage(data: rawData), ui.size.width > 0 else { return nil }
            let maxDim: CGFloat = 1600
            let factor = min(1, maxDim / max(ui.size.width, ui.size.height))
            let target = CGSize(width: ui.size.width * factor, height: ui.size.height * factor)
            let renderer = UIGraphicsImageRenderer(size: target)
            let resized = renderer.image { _ in ui.draw(in: CGRect(origin: .zero, size: target)) }
            let data = resized.jpegData(compressionQuality: 0.8) ?? rawData
            return PreparedImage(data: data, aspectRatio: Double(ui.size.height / ui.size.width))
        }.value
    }

    private func insertImage(_ image: PreparedImage, x: Double, y: Double, on page: JournalPage) {
        let box = ImageBox(x: x, y: y, widthFraction: 0.4, aspectRatio: image.aspectRatio,
                           imageData: image.data, page: page)
        context.insert(box)
        page.updatedAt = .now
        try? context.save()
    }

    private func deleteImageBox(_ box: ImageBox, on page: JournalPage) {
        context.delete(box)
        page.updatedAt = .now
        try? context.save()
    }

    /// Paste from the system clipboard at the long-pressed spot (works across
    /// notebooks, and from other apps). Ink copied with the lasso comes back
    /// as strokes — still ink, erasable and lasso-able — centred on the spot;
    /// PencilKit also puts a picture of it on the clipboard, which is used only
    /// when there is no ink.
    private func pasteImage(at point: CGPoint, on page: JournalPage, pageSize: CGSize) {
        let pasteboard = UIPasteboard.general
        if let data = pasteboard.data(forPasteboardType: PKAppleDrawingTypeIdentifier as String),
           let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty {
            guard page.id == selection else { return }
            let bounds = drawing.bounds
            let moved = drawing.transformed(using: CGAffineTransform(
                translationX: point.x - bounds.midX, y: point.y - bounds.midY))
            proxy.commit(drawing: moved)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        guard let image = UIPasteboard.general.image,
              let data = image.jpegData(compressionQuality: 0.9) ?? image.pngData() else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        let nx = min(max(Double(point.x / pageSize.width), 0), 0.9)
        let ny = min(max(Double(point.y / pageSize.width), 0), maxYFraction(pageSize))
        Task {
            if let image = await Self.prepareImage(rawData: data) {
                await MainActor.run {
                    insertImage(image, x: nx, y: ny, on: page)
                }
            }
        }
    }

    // MARK: - Actions

    private func bootstrap() {
        guard selection == nil else { return }
        // Reopen the page you were on in this notebook (here or on another device).
        if let last = position.pageID(in: notebook.id) {
            if pages.contains(where: { $0.id == last }) {
                selection = last
                return
            }
            pendingPage = (last, .now)   // may still be syncing in
        }
        let page = store.firstPage(on: .now, in: notebook, createIfMissing: true)
        try? context.save()
        selection = page?.id ?? pages.first?.id
    }

    /// A page made on purpose: it stays even if left blank, until you delete it.
    private func restorePage(_ id: UUID) {
        if pages.contains(where: { $0.id == id }) {
            selection = id
        } else {
            pendingPage = (id, .now)
        }
    }

    private func addPage() {
        let day = selectedPage?.day ?? Calendar.current.startOfDay(for: .now)
        let page = store.addPage(on: day, in: notebook)
        page.keepsWhenEmpty = true
        try? context.save()
        selection = page.id
    }

    /// Released far enough past the last page: let the bounce settle, then
    /// slide to the new page.
    private func addPageFromPull() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.snappy(duration: 0.35)) { addPage() }
        }
    }

    /// Opens a day: its first page with notes, else its first page.
    private func goToDay(_ date: Date) {
        let page = store.pages(on: date, in: notebook).first(where: hasNotes)
            ?? store.firstPage(on: date, in: notebook, createIfMissing: true)
        try? context.save()
        selection = page?.id
    }

    /// Recomputes which days have notes, re-checking only changed pages.
    private func refreshNoteDays() {
        var days = Set<Date>()
        for page in pages {
            let known = noteCache.entries[page.id]
            let notes: Bool
            if let known, known.stamp == page.updatedAt {
                notes = known.hasNotes
            } else {
                notes = hasNotes(page)
                noteCache.entries[page.id] = (page.updatedAt, notes)
            }
            if notes { days.insert(Calendar.current.startOfDay(for: page.day)) }
        }
        if days != noteDays { noteDays = days }
    }

    private func deselectImage(unlessTapped point: CGPoint, on page: JournalPage, pageSize: CGSize) {
        guard let id = selectedImageID, !croppingImage else { return }
        if let box = (page.imageBoxes ?? []).first(where: { $0.id == id }) {
            let width = box.widthFraction * pageSize.width
            let frame = CGRect(x: box.x * pageSize.width, y: box.y * pageSize.width,
                               width: width, height: width * box.aspectRatio)
            // The margin covers the controls on the photo's corners.
            if frame.insetBy(dx: -24, dy: -24).contains(point) { return }
        }
        withAnimation(.snappy(duration: 0.2)) { selectedImageID = nil }
    }

    /// Grid of all pages: whatever is still pending is saved first, so the
    /// thumbnails show the page as it is right now.
    private func openOverview() {
        proxy.flushPendingSave?()
        editingTextBoxID = nil
        editingChecklistID = nil
        withAnimation(.snappy(duration: 0.28)) { showOverview = true }
    }

    /// First free spot on the page: below everything already on it.
    /// `textSize` is the size checklists are shown at on this device.
    private func freeSpot(on page: JournalPage, pageSize: CGSize, textSize: CGFloat = 18) -> CGPoint {
        let width = pageSize.width
        var bottom = width * 0.03
        for box in textBoxes(of: page) where !box.rtfData.isEmpty {
            let textWidth = max(CGFloat(box.widthFraction) * width - 12, 40)
            let height = TextBoxView.attributedString(from: box.rtfData)?
                .boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                .height ?? 24
            bottom = max(bottom, CGFloat(box.y) * width + height + 12)
        }
        for box in imageBoxes(of: page) {
            bottom = max(bottom, CGFloat(box.y + box.widthFraction * box.aspectRatio) * width)
        }
        // A row is one line of the checklist's font plus the gap between rows.
        let row = ceil(UIFont.systemFont(ofSize: max(19, textSize)).lineHeight) + 6
        for box in checklistBoxes(of: page) {
            bottom = max(bottom, CGFloat(box.y) * width + CGFloat(box.items.count) * row + 24)
        }
        if let ink = proxy.canvas?.drawing.bounds, !ink.isNull {
            bottom = max(bottom, ink.maxY)
        }
        return CGPoint(x: width * 0.05, y: bottom + 12)
    }

    private func addTextBoxOnFreeSpot() {
        guard let page = selectedPage, let size = proxy.canvas?.bounds.size else { return }
        addTextBox(at: freeSpot(on: page, pageSize: size), on: page, pageSize: size)
    }

    private func addChecklistOnFreeSpot() {
        guard let page = selectedPage, let size = proxy.canvas?.bounds.size else { return }
        addChecklist(at: freeSpot(on: page, pageSize: size), on: page, pageSize: size)
    }

    /// Insert a text box at a page point. It runs to the right edge of the
    /// page, so text flows across the whole line, like writing on paper.
    private func addTextBox(at point: CGPoint, on page: JournalPage, pageSize: CGSize) {
        guard pageSize.width > 0, pageSize.height > 0 else { return }
        let nx = min(max(Double(point.x / pageSize.width), 0), 0.9)
        let ny = min(max(Double(point.y / pageSize.width), 0), maxYFraction(pageSize))
        let widthFraction = max(0.3, 0.97 - nx)
        let box = TextBox(x: nx, y: ny, widthFraction: widthFraction, page: page)
        context.insert(box)
        page.updatedAt = .now
        try? context.save()
        editingTextBoxID = box.id
    }

    /// A page is empty when it has no strokes and no (non-empty) text boxes.
    /// Pages you created yourself never count as empty: only you delete them.
    private func isPageEmpty(_ page: JournalPage) -> Bool {
        !page.keepsWhenEmpty && !page.isFavorite && !hasNotes(page)
    }

    /// Anything written or placed on the page.
    private func hasNotes(_ page: JournalPage) -> Bool {
        if !(page.textBoxes ?? []).isEmpty || !(page.imageBoxes ?? []).isEmpty
            || !(page.checklistBoxes ?? []).isEmpty
            || !page.title.trimmingCharacters(in: .whitespaces).isEmpty {
            return true
        }
        guard !page.drawingData.isEmpty else { return false }
        return (try? PKDrawing(data: page.drawingData))?.strokes.isEmpty == false
    }

    /// When leaving a page that was opened implicitly (today at launch, a day
    /// from the strip) and never written on, delete it — so days don't keep a
    /// blank page you never asked for. Pages you created are left alone.
    private func pruneIfEmpty(_ oldSelection: UUID?, movingTo newSelection: UUID?) {
        guard let oldSelection, oldSelection != newSelection,
              let page = pages.first(where: { $0.id == oldSelection }),
              isPageEmpty(page) else { return }
        context.delete(page)
        try? context.save()
    }

    private func deletePage(_ page: JournalPage) {
        // Pick a neighbour to select if we're deleting the current page.
        if selection == page.id {
            if let idx = pages.firstIndex(where: { $0.id == page.id }) {
                let neighbour = pages[safe: idx + 1] ?? pages[safe: idx - 1]
                selection = neighbour?.id
            } else {
                selection = nil
            }
        }
        context.delete(page)
        try? context.save()
    }

    private func growPage(_ page: JournalPage, currentHeight: CGFloat, viewport: CGFloat) {
        let newHeight = currentHeight + viewport * 0.8
        if Double(newHeight) > page.contentHeight {
            page.contentHeight = Double(newHeight)
            page.updatedAt = .now
        }
    }

    private func handleEndEdit(_ box: TextBox) {
        // The box may have been deleted (e.g. via the X) while resigning.
        guard box.modelContext != nil else {
            if editingTextBoxID == box.id { editingTextBoxID = nil }
            return
        }
        let attributed = TextBoxView.attributedString(from: box.rtfData)
        let isEmpty = attributed?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        if isEmpty {
            context.delete(box)
        }
        selectedPage?.updatedAt = .now
        try? context.save()
        if editingTextBoxID == box.id { editingTextBoxID = nil }
    }
}

// MARK: - Text box container (position / move / resize / tap-to-edit)

private struct TextBoxContainer: View {
    let box: TextBox
    let pageSize: CGSize
    let isEditing: Bool
    var textSize: CGFloat = 18
    /// How much the page is shrunk on screen (iPhone): finger distances are
    /// divided by it and the controls counter-scaled, so they keep real size.
    var scale: CGFloat = 1
    var accent: Color = .accentColor
    var paper: PaperColor = .white
    var editTapCount: Int = 2
    var onBeginEdit: () -> Void
    var onEndEdit: () -> Void
    var onMove: (Double, Double) -> Void
    var onResize: (Double) -> Void
    /// Held long enough to move (true), then let go (false).
    var onLift: (Bool) -> Void

    @State private var dragOffset: CGSize = .zero
    /// Held long enough to move.
    @State private var isLifted = false
    @State private var widthDrag: CGFloat = 0

    var body: some View {
        let baseX = box.x * pageSize.width
        // Anchor Y to the page WIDTH (stable) so the box doesn't slide down as
        // the page grows taller on scroll.
        let baseY = box.y * pageSize.width
        // Never let the box extend past the right edge of the page.
        let maxWidth = max(90, pageSize.width * (1 - box.x) - 6)
        let width = min(max(90, box.widthFraction * pageSize.width + widthDrag), maxWidth)

        // No border, even while editing: the text sits directly on the paper,
        // with the background color only if one was chosen.
        TextBoxView(box: box, isEditing: isEditing, onEndEditing: onEndEdit,
                    baseFontSize: textSize, accent: accent, paper: paper)
            .frame(width: width, alignment: .topLeading)
            .frame(minHeight: isEditing ? 40 : 0, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 8).fill(backgroundFill))
            .overlay(alignment: .bottomTrailing) { resizeHandle(width: width) }
            .overlay { if !isEditing { tapMoveLayer(baseX: baseX, baseY: baseY) } }
            // Lifts slightly under the finger once it can be moved.
            .scaleEffect(isLifted ? 1.02 : 1, anchor: .topLeading)
            .animation(.snappy(duration: 0.18), value: isLifted)
            .offset(x: baseX + dragOffset.width, y: baseY + dragOffset.height)
            .onChange(of: isLifted) { _, lifted in
                onLift(lifted)
                guard lifted else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
    }

    private var backgroundFill: Color {
        guard !box.backgroundColorRaw.isEmpty, let color = Color(hex: box.backgroundColorRaw) else { return .clear }
        return color.opacity(EditPalette.backgroundOpacity)
    }

    @ViewBuilder private func tapMoveLayer(baseX: CGFloat, baseY: CGFloat) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: editTapCount) { onBeginEdit() }
            // Press and hold, then drag: a plain drag over text scrolls the
            // page instead of carrying the text along.
            .gesture(HoldToMoveGesture(
                onLift: { isLifted = $0 },
                onChange: { moved in
                    dragOffset = CGSize(width: moved.width / scale, height: moved.height / scale)
                },
                onEnd: { moved in
                    let nx = (baseX + moved.width / scale) / pageSize.width
                    let ny = (baseY + moved.height / scale) / pageSize.width
                    let maxY = Double((pageSize.height - 20) / pageSize.width)
                    onMove(min(max(Double(nx), 0), 0.98), min(max(Double(ny), 0), maxY))
                    dragOffset = .zero
                }
            ))
    }

    @ViewBuilder private func resizeHandle(width: CGFloat) -> some View {
        if isEditing {
            WidthHandleMark(scale: scale)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { v in widthDrag = v.translation.width / scale }
                        .onEnded { v in
                            let base = box.widthFraction * pageSize.width
                            let maxFraction = max(0.15, 1 - box.x - 0.02)
                            let fraction = (base + v.translation.width / scale) / pageSize.width
                            onResize(min(max(Double(fraction), 0.1), maxFraction))
                            widthDrag = 0
                        }
                )
        }
    }
}
