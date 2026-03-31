import AppKit
import SwiftUI

struct NewSessionSheet: View {
  @EnvironmentObject private var coordinator: AppCoordinator
  @EnvironmentObject private var sessionService: SessionService
  @EnvironmentObject private var workflowService: WorkflowService

  let preset: NewSessionPreset

  @State private var title = ""
  @State private var folderPath = ""
  @State private var createWorktree = false
  @State private var branchName = ""
  @State private var repoBranchMode: RepoBranchMode = .current
  @State private var useExistingWorktree = false
  @State private var existingWorktreePath = ""
  @State private var shellPath = ""
  @State private var launchMode: LaunchMode = .plainShell
  @State private var selectedToolID = ""
  @State private var sandboxProfile: SandboxProfile = .fullAccess
  @State private var networkPolicy: NetworkPolicy = .inherited
  @State private var isCreating = false
  @State private var isCheckingRepo = false
  @State private var folderIsGitRepo = false
  @State private var showGitSection = false
  @State private var showSafetySection = false
  @State private var showVibeSection = false
  @State private var showAdvanced = false
  @State private var repoCheckToken = UUID()
  @State private var errorMessage: String?

  private var showsVibeFeatures: Bool {
    sessionService.settings.appMode.showsVibeFeatures
  }

  private var settingForcesWorktree: Bool {
    sessionService.settings.defaultCreateWorktreeForRepoSessions && folderIsGitRepo
  }

  private var effectiveCreateWorktree: Bool {
    settingForcesWorktree || createWorktree
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Create Session")
        .font(.title3.weight(.semibold))

      // MARK: - Tier 1: Always visible

      TextField("Session name (optional)", text: $title)

      VStack(alignment: .leading, spacing: 6) {
        Text("Folder")
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack {
          TextField("Optional project folder", text: $folderPath)
          Button("Choose\u{2026}") {
            chooseFolder()
          }
        }
      }

      // MARK: - Git & Worktree Section (auto-revealed when git repo detected)

      if folderIsGitRepo || preset == .worktree {
        sectionCard {
          VStack(alignment: .leading, spacing: 10) {
            sectionToggleHeader(
              icon: "arrow.triangle.branch",
              title: "Git & Worktree",
              isExpanded: $showGitSection
            )

            if showGitSection {
              Toggle("Create worktree", isOn: $createWorktree)
                .disabled(settingForcesWorktree)

              if settingForcesWorktree {
                Text("Worktree creation is enforced. Disable it in Settings > Sessions.")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }

              if effectiveCreateWorktree {
                if isCheckingRepo {
                  HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking repository\u{2026}")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                } else if folderIsGitRepo {
                  Picker("Worktree mode", selection: $useExistingWorktree) {
                    Text("Create New").tag(false)
                    Text("Attach Existing").tag(true)
                  }
                  .pickerStyle(.segmented)

                  if useExistingWorktree {
                    VStack(alignment: .leading, spacing: 6) {
                      Text("Existing worktree")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                      HStack {
                        TextField("Worktree path", text: $existingWorktreePath)
                        Button("Choose\u{2026}") { chooseExistingWorktree() }
                      }
                    }
                  } else {
                    TextField("Branch name (optional)", text: $branchName)
                  }
                } else {
                  Text("Select a Git repository folder to enable worktree options.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }

              if !effectiveCreateWorktree, folderIsGitRepo {
                VStack(alignment: .leading, spacing: 6) {
                  Text("Branch mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  Picker("Branch mode", selection: $repoBranchMode) {
                    Text("Use Current").tag(RepoBranchMode.current)
                    Text("Set Manually").tag(RepoBranchMode.custom)
                  }
                  .pickerStyle(.segmented)

                  if repoBranchMode == .custom {
                    TextField("Branch name", text: $branchName)
                  }
                }
              }
            }
          }
        }
        .animation(.easeInOut(duration: 0.2), value: showGitSection)
      }

      // MARK: - Safety Section (collapsed by default)

      sectionCard {
        VStack(alignment: .leading, spacing: 10) {
          sectionToggleHeader(
            icon: "shield",
            title: "Safety",
            isExpanded: $showSafetySection
          )

          if showSafetySection {
            Picker("Sandbox profile", selection: $sandboxProfile) {
              ForEach(SandboxProfile.allCases, id: \.self) { profile in
                Text(profile.displayLabel).tag(profile)
              }
            }

            Picker("Network policy", selection: $networkPolicy) {
              ForEach(NetworkPolicy.allCases, id: \.self) { policy in
                Text(policy.displayLabel).tag(policy)
              }
            }
            .pickerStyle(.segmented)
          }
        }
      }
      .animation(.easeInOut(duration: 0.2), value: showSafetySection)

      // MARK: - Vibe Tool Section (hidden in terminal mode)

      if showsVibeFeatures {
        sectionCard {
          VStack(alignment: .leading, spacing: 10) {
            sectionToggleHeader(
              icon: "wand.and.stars",
              title: "Vibe Tool",
              isExpanded: $showVibeSection
            )

            if showVibeSection {
              Picker("Launch mode", selection: $launchMode) {
                Text("Plain Shell").tag(LaunchMode.plainShell)
                Text("Auto-Start Tool").tag(LaunchMode.autoTool)
              }
              .pickerStyle(.segmented)

              if launchMode == .autoTool {
                Picker("Tool", selection: $selectedToolID) {
                  ForEach(workflowService.vibeTools, id: \.id) { tool in
                    Text(tool.isInstalled ? tool.displayName : "\(tool.displayName) (Not Installed)")
                      .tag(tool.id)
                  }
                }
                .disabled(workflowService.vibeTools.isEmpty)
              }
            }
          }
        }
        .animation(.easeInOut(duration: 0.2), value: showVibeSection)
      }

      // MARK: - Advanced

      DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
        TextField("Shell path (optional)", text: $shellPath)
          .textFieldStyle(.roundedBorder)
          .padding(.top, 6)
      }

      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .font(.caption)
      }

      HStack {
        Spacer()
        Button("Cancel") {
          coordinator.showingNewSessionSheet = false
        }
        .keyboardShortcut(.cancelAction)

        Button(isCreating ? "Creating\u{2026}" : "Create Session") {
          createSession()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isCreateDisabled)
      }
    }
    .padding(18)
    .onAppear {
      configurePresetDefaults()
      refreshRepoStatus()
      workflowService.refreshVibeTools()
      if selectedToolID.isEmpty {
        selectedToolID = sessionService.settings.defaultVibeToolID ?? workflowService.vibeTools.first?.id ?? ""
      }
    }
    .onChange(of: folderPath) {
      refreshRepoStatus()
    }
    .onChange(of: folderIsGitRepo) { _, isRepo in
      if isRepo {
        showGitSection = true
        if sessionService.settings.defaultCreateWorktreeForRepoSessions {
          createWorktree = true
        }
      }
    }
    .onChange(of: createWorktree) {
      if createWorktree {
        refreshRepoStatus()
        prefillBranchIfNeeded()
      } else {
        useExistingWorktree = false
        existingWorktreePath = ""
        if repoBranchMode == .current {
          branchName = ""
        }
      }
    }
    .onChange(of: useExistingWorktree) {
      if useExistingWorktree {
        branchName = ""
      } else {
        prefillBranchIfNeeded()
      }
    }
    .onChange(of: repoBranchMode) {
      if repoBranchMode == .current, !createWorktree {
        branchName = ""
      }
    }
  }

  // MARK: - Section Card Components

  private func sectionCard(@ViewBuilder content: () -> some View) -> some View {
    content()
      .padding(12)
      .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
  }

  private func sectionToggleHeader(icon: String, title: String, isExpanded: Binding<Bool>) -> some View {
    Button {
      withAnimation(.easeInOut(duration: 0.2)) {
        isExpanded.wrappedValue.toggle()
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: icon)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.white.opacity(0.4))
          .frame(width: 16)

        Text(title)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.white.opacity(0.7))

        Spacer()

        Image(systemName: isExpanded.wrappedValue ? "chevron.up" : "chevron.down")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(.white.opacity(0.3))
      }
    }
    .buttonStyle(.plain)
  }

  // MARK: - Logic

  private var isCreateDisabled: Bool {
    if isCreating || isCheckingRepo {
      return true
    }
    if effectiveCreateWorktree, !folderIsGitRepo {
      return true
    }
    if effectiveCreateWorktree, useExistingWorktree, existingWorktreePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return true
    }
    if !effectiveCreateWorktree,
       folderIsGitRepo,
       repoBranchMode == .custom,
       branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return true
    }
    if launchMode == .autoTool {
      guard !selectedToolID.isEmpty else { return true }
      let installed = workflowService.vibeTools.first(where: { $0.id == selectedToolID })?.isInstalled ?? false
      if !installed { return true }
    }
    return false
  }

  private func configurePresetDefaults() {
    createWorktree = sessionService.settings.defaultCreateWorktreeForRepoSessions
    sandboxProfile = sessionService.settings.defaultSandboxProfile
    networkPolicy = sessionService.settings.defaultNetworkPolicy
    if preset == .quick {
      folderPath = ""
      createWorktree = false
    } else if preset == .worktree {
      createWorktree = true
      showGitSection = true
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    if panel.runModal() == .OK {
      folderPath = panel.url?.path ?? ""
      prefillBranchIfNeeded()
    }
  }

  private func chooseExistingWorktree() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    if panel.runModal() == .OK {
      existingWorktreePath = panel.url?.path ?? ""
    }
  }

  private func prefillBranchIfNeeded() {
    guard effectiveCreateWorktree, folderIsGitRepo, !useExistingWorktree else { return }
    guard branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let repoName = URL(fileURLWithPath: folderPath).lastPathComponent
    branchName = BranchNameGenerator.generate(
      sessionTitle: title.isEmpty ? nil : title,
      repoName: repoName
    )
  }

  private func refreshRepoStatus() {
    let cleanedFolder = folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let token = UUID()
    repoCheckToken = token

    guard !cleanedFolder.isEmpty else {
      isCheckingRepo = false
      folderIsGitRepo = false
      repoBranchMode = .current
      branchName = ""
      useExistingWorktree = false
      existingWorktreePath = ""
      return
    }

    isCheckingRepo = true
    Task {
      let isRepo = await sessionService.isGitRepository(path: cleanedFolder)
      await MainActor.run {
        guard repoCheckToken == token else { return }
        isCheckingRepo = false
        folderIsGitRepo = isRepo
        if !isRepo {
          repoBranchMode = .current
          branchName = ""
          useExistingWorktree = false
          existingWorktreePath = ""
          if sessionService.settings.defaultCreateWorktreeForRepoSessions {
            createWorktree = false
          }
        } else {
          if sessionService.settings.defaultCreateWorktreeForRepoSessions {
            createWorktree = true
          }
          prefillBranchIfNeeded()
        }
      }
    }
  }

  private func createSession() {
    errorMessage = nil
    isCreating = true

    Task {
      do {
        let created = try await sessionService.createSession(
          from: SessionCreationRequest(
            title: title,
            repoPath: folderPath,
            createWorktree: effectiveCreateWorktree,
            branchName: resolvedBranchName,
            existingWorktreePath: useExistingWorktree ? existingWorktreePath : nil,
            shellPath: shellPath,
            sandboxProfile: sandboxProfile,
            networkPolicy: networkPolicy,
            launchToolID: launchMode == .autoTool ? selectedToolID : nil
          )
        )

        await MainActor.run {
          if launchMode == .autoTool {
            do {
              try workflowService.launchTool(selectedToolID, in: created.session.id)
            } catch {
              sessionService.postStatusMessage(error.localizedDescription, for: created.session.id)
            }
          }
          isCreating = false
          coordinator.showingNewSessionSheet = false
        }
      } catch {
        await MainActor.run {
          isCreating = false
          errorMessage = error.localizedDescription
        }
      }
    }
  }

  private var resolvedBranchName: String? {
    let cleaned = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    if effectiveCreateWorktree { return cleaned }
    if folderIsGitRepo, repoBranchMode == .custom { return cleaned }
    return nil
  }
}

private enum LaunchMode: Hashable {
  case plainShell
  case autoTool
}

private enum RepoBranchMode: Hashable {
  case current
  case custom
}
