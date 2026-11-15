//
//  NotebookEditorSheet.swift
//  MyAgenda
//
//  Create or edit a notebook: title, theme color, page style, paper color.
//

import SwiftUI

struct NotebookEditorSheet: View {
    /// nil = create a new notebook.
    var existing: Notebook?
    var canDelete: Bool = false
    var onSave: (_ title: String, _ accentHex: String, _ style: PageStyle,
                                  _ paper: PaperColor) -> Void
    var onDelete: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var accentHex: String
    @State private var style: PageStyle
    @State private var paper: PaperColor
    @State private var showDeleteConfirm = false

    init(existing: Notebook?,
         canDelete: Bool = false,
         onSave: @escaping (_ title: String, _ accentHex: String, _ style: PageStyle,
                                  _ paper: PaperColor) -> Void,
         onDelete: @escaping () -> Void = {}) {
        self.existing = existing
        self.canDelete = canDelete
        self.onSave = onSave
        self.onDelete = onDelete
        _title = State(initialValue: existing?.title ?? "")
        _accentHex = State(initialValue: existing?.accentHex ?? Notebook.themeColors[0])
        _style = State(initialValue: existing?.pageStyle ?? .dots)
        _paper = State(initialValue: existing?.paper ?? .white)
    }

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 14)]

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Notebook Name", text: $title)
                }

                Section("Theme Color") {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(Notebook.themeColors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex) ?? .blue)
                                .frame(width: 40, height: 40)
                                .overlay(
                                    Circle().strokeBorder(
                                        accentHex == hex ? Color.primary : Color.clear,
                                        lineWidth: 3
                                    )
                                )
                                .onTapGesture { accentHex = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Page Style") {
                    Picker("Page Style", selection: $style) {
                        ForEach(PageStyle.allCases) { s in
                            Label(s.label, systemImage: s.symbol).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Picker("Paper", selection: $paper) {
                        ForEach(PaperColor.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Paper")
                } footer: {
                    Text("Applies to every page in this notebook. A page can choose its own paper from the “…” menu.")
                }

                if canDelete {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete Notebook", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "New Notebook" : "Edit Notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(name.isEmpty ? "Agenda" : name, accentHex, style, paper)
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Delete this notebook and all its pages?",
                                isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
