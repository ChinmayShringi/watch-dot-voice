import SwiftUI

struct AvatarPickerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Binding var selection: String
    @ObservedObject var catalog: PetCatalogSession
    let spriteName: String
    let onChoose: () -> Void
    @State private var preview = ""

    private var localAppearances: [CompanionAppearance] {
        CompanionAppearance.available(spriteAvailable: CompanionAvatar.spriteAvailable)
    }
    private var identifiers: [String] {
        catalog.items.map { AvatarSelection.identifier(for: $0.id) } + localAppearances.map(\.rawValue)
    }

    var body: some View {
        GeometryReader { geometry in
            TabView(selection: $preview) {
                ForEach(catalog.items) { pet in
                    remotePage(pet)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .tag(AvatarSelection.identifier(for: pet.id))
                }
                ForEach(localAppearances) { appearance in
                    localPage(appearance)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .tag(appearance.rawValue)
                }
            }
            .tabViewStyle(.verticalPage)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .sensitiveContent(placeholder: "Avatars hidden")
        .navigationTitle("")
        .toolbarTitleDisplayMode(.inline)
        .onAppear {
            preview = AvatarSelection.page(current: selection, selected: selection, available: identifiers)
        }
        .onChange(of: identifiers) { _, values in
            preview = AvatarSelection.page(current: preview, selected: selection, available: values)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await catalog.refresh()
            guard !Task.isCancelled, scenePhase == .active else { return }
            if let id = AvatarSelection.petID(from: preview) { _ = await catalog.prepare(id: id) }
        }
        .task(id: preview) {
            guard scenePhase == .active else { return }
            if let id = AvatarSelection.petID(from: preview) { _ = await catalog.prepare(id: id) }
        }
        .accessibilityIdentifier("avatar.picker")
    }

    private func remotePage(_ pet: PetCatalogItem) -> some View {
        let identifier = AvatarSelection.identifier(for: pet.id)
        let url = catalog.cachedURL(for: pet.id)
        return VStack(spacing: 2) {
            Group {
                if let url {
                    CompanionAvatar(appearance: .sprite, animation: .idle, level: 0,
                        atlasURL: url, playbackActive: preview == identifier)
                        .id(catalog.generation)
                } else if preview == identifier {
                    if catalog.errorMessage == nil {
                        ProgressView().accessibilityLabel("Loading avatar")
                    } else {
                        Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                    }
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(-1)
            name(pet.name)
            if url == nil, let error = catalog.errorMessage {
                Text(error).font(.caption2).multilineTextAlignment(.center).lineLimit(2)
                Button("Retry") {
                    Task {
                        await catalog.refresh(retry: true)
                        guard !Task.isCancelled, scenePhase == .active else { return }
                        _ = await catalog.prepare(id: pet.id)
                    }
                }
                    .buttonStyle(.bordered)
            } else {
                chooseButton(identifier: identifier, name: pet.name, enabled: url != nil) {
                    catalog.select(id: pet.id)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func localPage(_ appearance: CompanionAppearance) -> some View {
        VStack(spacing: 2) {
            CompanionAvatar(appearance: appearance, animation: .idle, level: 0,
                playbackActive: preview == appearance.rawValue)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(-1)
            name(appearance.displayName(spriteName: spriteName))
            if catalog.isLoading {
                Text("Loading Dot avatars…").font(.caption2).foregroundStyle(.secondary)
            } else if catalog.items.isEmpty, let error = catalog.errorMessage {
                Text(error).font(.caption2).multilineTextAlignment(.center).lineLimit(2)
            }
            chooseButton(identifier: appearance.rawValue,
                name: appearance.displayName(spriteName: spriteName), enabled: true) { catalog.select(id: nil) }
        }
        .padding(.horizontal, 12)
    }

    private func name(_ value: String) -> some View {
        Text(value).font(.footnote.weight(.semibold))
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }

    private func chooseButton(identifier: String, name: String, enabled: Bool,
                              prepare: @escaping () -> Void) -> some View {
        Button {
            prepare()
            selection = identifier
            onChoose()
        } label: {
            Text(identifier == selection ? "Selected" : "Choose").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(identifier == selection ? .gray : .accentColor)
        .disabled(!enabled)
        .accessibilityLabel(identifier == selection ? "Selected, \(name)" : "Choose \(name)")
        .accessibilityIdentifier("avatar.choose.\(identifier)")
    }
}
