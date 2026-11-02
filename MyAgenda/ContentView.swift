//
//  ContentView.swift
//  MyAgenda
//
//  Hosts the notebook list and shows the selected notebook's pages.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: [SortDescriptor(\Notebook.sortIndex), SortDescriptor(\Notebook.createdAt)])
    private var notebooks: [Notebook]

    @State private var selectedNotebookID: UUID?
    @State private var showNewNotebook = false
    @State private var showEditNotebook = false
    /// A notebook another device is on, waiting for CloudKit to bring it here.
    @State private var pendingNotebookID: UUID?
    private let position = ReadingPosition.shared

    @State private var workTimer = WorkTimer()
    @State private var showTimer = false
    @State private var timerCenter: CGPoint?
    @GestureState private var timerDrag: CGSize = .zero

    private var selectedNotebook: Notebook? {
        notebooks.first { $0.id == selectedNotebookID } ?? notebooks.first
    }

    var body: some View {
        Group {
            if let notebook = selectedNotebook {
                NotebookPagesView(
                    notebook: notebook,
                    notebooks: notebooks,
                    selectedNotebookID: Binding(
                        get: { notebook.id },
                        set: { selectedNotebookID = $0 }
                    ),
                    onNewNotebook: { showNewNotebook = true },
                    onEditNotebook: { showEditNotebook = true },
                    onShowTimer: { showTimer = true }
                )
                .id(notebook.id)
            } else {
                ProgressView()
            }
        }
        .overlay {
            if showTimer {
                GeometryReader { geo in
                    let base = timerCenter ?? CGPoint(x: geo.size.width - 140, y: 150)
                    TimerWidget(timer: workTimer) { showTimer = false }
                        .position(x: base.x + timerDrag.width, y: base.y + timerDrag.height)
                        .gesture(
                            DragGesture(coordinateSpace: .global)
                                .updating($timerDrag) { value, state, _ in state = value.translation }
                                .onEnded { value in
                                    timerCenter = CGPoint(x: base.x + value.translation.width,
                                                          y: base.y + value.translation.height)
                                }
                        )
                }
                .tint(selectedNotebook?.accentColor ?? .blue)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: showTimer)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                workTimer.refresh()
                position.becameActive()
            }
        }
        .onChange(of: selectedNotebookID) { _, id in
            if let id { position.saveNotebook(id) }
        }
        // Another device moved to a different notebook just now: follow it.
        .onChange(of: position.remoteJump) { _, _ in
            guard let id = position.notebookID, id != selectedNotebookID else { return }
            if notebooks.contains(where: { $0.id == id }) {
                selectedNotebookID = id
            } else {
                pendingNotebookID = id
            }
        }
        .onChange(of: notebooks.map(\.id)) { _, ids in
            if let pending = pendingNotebookID, ids.contains(pending) {
                selectedNotebookID = pending
                pendingNotebookID = nil
            }
        }
        .onAppear(perform: bootstrap)
        .sheet(isPresented: $showNewNotebook) {
            NotebookEditorSheet(existing: nil) { title, hex, style, paper in
                createNotebook(title: title, hex: hex, style: style, paper: paper)
            }
        }
        .sheet(isPresented: $showEditNotebook) {
            if let notebook = selectedNotebook {
                NotebookEditorSheet(
                    existing: notebook,
                    canDelete: notebooks.count > 1,
                    onSave: { title, hex, style, paper in
                        notebook.title = title
                        notebook.accentHex = hex
                        notebook.pageStyle = style
                        // A new paper is for the whole notebook, also the pages
                        // that had chosen their own.
                        if paper != notebook.paper {
                            notebook.paper = paper
                            for page in notebook.pages ?? [] where !page.paperRaw.isEmpty {
                                page.paperRaw = ""
                                page.updatedAt = .now
                            }
                        }
                        try? context.save()
                    },
                    onDelete: { deleteNotebook(notebook) }
                )
            }
        }
    }

    private func bootstrap() {
        if notebooks.isEmpty {
            let notebook = Notebook(title: "Agendă", accentHex: Notebook.themeColors[0], pageStyle: .dots, sortIndex: 0)
            context.insert(notebook)
            try? context.save()
            selectedNotebookID = notebook.id
        } else if selectedNotebookID == nil {
            // Reopen where you left off (on this device or another one).
            if let last = position.notebookID {
                if notebooks.contains(where: { $0.id == last }) {
                    selectedNotebookID = last
                    return
                }
                pendingNotebookID = last   // may still be syncing in
            }
            selectedNotebookID = notebooks.first?.id
        }
    }

    private func createNotebook(title: String, hex: String, style: PageStyle, paper: PaperColor) {
        let nextIndex = (notebooks.map(\.sortIndex).max() ?? -1) + 1
        let notebook = Notebook(title: title, accentHex: hex, pageStyle: style, sortIndex: nextIndex)
        notebook.paper = paper
        context.insert(notebook)
        try? context.save()
        selectedNotebookID = notebook.id
    }

    private func deleteNotebook(_ notebook: Notebook) {
        let fallback = notebooks.first { $0.id != notebook.id }?.id
        context.delete(notebook)
        try? context.save()
        selectedNotebookID = fallback
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Notebook.self, JournalPage.self, TextBox.self], inMemory: true)
}
