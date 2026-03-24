import XCTest
@testable import idx0

extension SessionServiceTests {
    func testNiriSelectingTerminalPrimesMissingController() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Prime Controller")).session
        service.ensureNiriLayoutState(for: session.id)

        let layout = service.niriLayout(for: session.id)
        guard let itemID = layout.camera.focusedItemID else {
            XCTFail("Expected focused niri item")
            return
        }
        guard let tabID = service.selectedTabID(for: session.id),
              let tab = service.tabState(sessionID: session.id, tabID: tabID) else {
            XCTFail("Expected selected tab")
            return
        }

        let controllerID = tab.activeControllerID
        service.runtimeControllers.removeValue(forKey: controllerID)
        service.ownerSessionIDByControllerID.removeValue(forKey: controllerID)
        XCTAssertNil(service.paneController(for: controllerID))

        service.niriSelectItem(sessionID: session.id, itemID: itemID)
        XCTAssertNotNil(service.paneController(for: controllerID))
    }

    func testNiriLayoutMaintainsSingleTrailingEmptyWorkspace() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Invariant")).session
        service.ensureNiriLayoutState(for: session.id)
        _ = service.niriAddTerminalRight(in: session.id)
        _ = service.niriAddTaskBelow(in: session.id)
        service.focusNiriWorkspaceDown(sessionID: session.id)
        _ = service.niriAddTerminalRight(in: session.id)
        service.moveNiriColumnToWorkspaceUp(sessionID: session.id)

        let layout = service.niriLayout(for: session.id)
        assertHasSingleTrailingEmptyWorkspace(layout)
    }

    func testNiriToggleColumnTabbedDisplayPreservesItemsAndFocus() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Tabs")).session
        service.ensureNiriLayoutState(for: session.id)
        _ = service.niriAddTaskBelow(in: session.id)

        var layout = service.niriLayout(for: session.id)
        guard let workspaceIndex = niriActiveWorkspaceIndex(layout),
              let columnIndex = niriActiveColumnIndex(layout, workspaceIndex: workspaceIndex)
        else {
            XCTFail("Expected active workspace and column")
            return
        }

        let beforeItemIDs = layout.workspaces[workspaceIndex].columns[columnIndex].items.map(\.id)
        let beforeFocused = layout.workspaces[workspaceIndex].columns[columnIndex].focusedItemID
        let beforeMode = layout.workspaces[workspaceIndex].columns[columnIndex].displayMode

        service.toggleNiriColumnTabbedDisplay(sessionID: session.id)
        layout = service.niriLayout(for: session.id)

        guard let newWorkspaceIndex = niriActiveWorkspaceIndex(layout),
              let newColumnIndex = niriActiveColumnIndex(layout, workspaceIndex: newWorkspaceIndex)
        else {
            XCTFail("Expected active workspace and column after toggle")
            return
        }

        let afterColumn = layout.workspaces[newWorkspaceIndex].columns[newColumnIndex]
        XCTAssertEqual(afterColumn.items.map(\.id), beforeItemIDs)
        XCTAssertEqual(afterColumn.focusedItemID, beforeFocused)
        XCTAssertNotEqual(afterColumn.displayMode, beforeMode)
        assertHasSingleTrailingEmptyWorkspace(layout)
    }

    func testNiriOverviewHorizontalNavigationUsesRowAlignedTargets() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Overview Row Align")).session
        service.ensureNiriLayoutState(for: session.id)

        guard let tile2 = service.niriAddTerminalRight(in: session.id),
              let tile3 = service.niriAddTerminalRight(in: session.id) else {
            XCTFail("Expected right-side tiles")
            return
        }
        service.niriSelectItem(sessionID: session.id, itemID: tile2)
        guard let tile4 = service.niriAddTaskBelow(in: session.id) else {
            XCTFail("Expected stacked tile in middle column")
            return
        }

        service.toggleNiriOverview(sessionID: session.id)
        var layout = service.niriLayout(for: session.id)
        guard let workspaceIndex = niriActiveWorkspaceIndex(layout),
              layout.workspaces[workspaceIndex].columns.count >= 3,
              let tile1 = layout.workspaces[workspaceIndex].columns[0].items.first?.id else {
            XCTFail("Expected three columns with a leading tile")
            return
        }

        service.niriSelectItem(sessionID: session.id, itemID: tile1)
        service.niriFocusNeighbor(sessionID: session.id, horizontal: 1)
        layout = service.niriLayout(for: session.id)
        XCTAssertEqual(layout.camera.focusedItemID, tile2)

        service.niriSelectItem(sessionID: session.id, itemID: tile4)
        service.niriFocusNeighbor(sessionID: session.id, horizontal: 1)
        layout = service.niriLayout(for: session.id)
        XCTAssertEqual(layout.camera.focusedItemID, tile3)

        service.niriSelectItem(sessionID: session.id, itemID: tile4)
        service.niriFocusNeighbor(sessionID: session.id, horizontal: -1)
        layout = service.niriLayout(for: session.id)
        XCTAssertEqual(layout.camera.focusedItemID, tile1)
    }

    func testNiriAddBrowserRightCreatesNewTileEachTime() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Browser Tiles")).session
        service.ensureNiriLayoutState(for: session.id)

        guard let firstBrowserItemID = service.niriAddBrowserRight(in: session.id),
              let secondBrowserItemID = service.niriAddBrowserRight(in: session.id)
        else {
            XCTFail("Expected browser items")
            return
        }

        XCTAssertNotEqual(firstBrowserItemID, secondBrowserItemID)

        let layout = service.niriLayout(for: session.id)
        let browserItems = layout.workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .filter { item in
                if case .browser = item.ref {
                    return true
                }
                return false
            }

        XCTAssertEqual(browserItems.count, 2)
    }

    func testNiriBrowserControllersArePerTile() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Browser Controllers")).session
        service.ensureNiriLayoutState(for: session.id)

        guard let firstBrowserItemID = service.niriAddBrowserRight(in: session.id),
              let secondBrowserItemID = service.niriAddBrowserRight(in: session.id)
        else {
            XCTFail("Expected browser items")
            return
        }

        let firstController = service.niriBrowserController(for: session.id, itemID: firstBrowserItemID)
        let secondController = service.niriBrowserController(for: session.id, itemID: secondBrowserItemID)

        XCTAssertNotNil(firstController)
        XCTAssertNotNil(secondController)
        XCTAssertFalse(firstController === secondController)
    }

    func testNiriAddT3CodeReusesExistingTileAndFocusesIt() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri T3 Reuse")).session
        service.ensureNiriLayoutState(for: session.id)

        guard let firstT3ID = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.t3Code) else {
            XCTFail("Expected T3 tile")
            return
        }

        _ = service.niriAddTerminalRight(in: session.id)
        let secondResult = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.t3Code)
        XCTAssertEqual(secondResult, firstT3ID)

        let layout = service.niriLayout(for: session.id)
        let t3Items = layout.workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .filter { item in
                item.ref.appID == NiriAppID.t3Code
            }
        XCTAssertEqual(t3Items.count, 1)
        XCTAssertEqual(layout.camera.focusedItemID, firstT3ID)
    }

    func testNiriAddVSCodeReusesExistingTileAndFocusesIt() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri VSCode Reuse")).session
        service.ensureNiriLayoutState(for: session.id)

        guard let firstVSCodeID = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.vscode) else {
            XCTFail("Expected VS Code tile")
            return
        }

        _ = service.niriAddTerminalRight(in: session.id)
        let secondResult = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.vscode)
        XCTAssertEqual(secondResult, firstVSCodeID)

        let layout = service.niriLayout(for: session.id)
        let vscodeItems = layout.workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .filter { item in
                item.ref.appID == NiriAppID.vscode
            }
        XCTAssertEqual(vscodeItems.count, 1)
        XCTAssertEqual(layout.camera.focusedItemID, firstVSCodeID)
    }

    func testNiriAddOpenCodeReusesExistingTileAndFocusesIt() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri OpenCode Reuse")).session
        service.ensureNiriLayoutState(for: session.id)

        guard let firstOpenCodeID = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.openCode) else {
            XCTFail("Expected OpenCode tile")
            return
        }

        _ = service.niriAddTerminalRight(in: session.id)
        let secondResult = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.openCode)
        XCTAssertEqual(secondResult, firstOpenCodeID)

        let layout = service.niriLayout(for: session.id)
        let openCodeItems = layout.workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .filter { item in
                item.ref.appID == NiriAppID.openCode
            }
        XCTAssertEqual(openCodeItems.count, 1)
        XCTAssertEqual(layout.camera.focusedItemID, firstOpenCodeID)
    }

    func testCloseNiriFocusedT3TileRemovesItemAndController() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Close T3")).session
        service.ensureNiriLayoutState(for: session.id)
        guard let t3ItemID = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.t3Code) else {
            XCTFail("Expected T3 tile")
            return
        }
        let initialT3Controller: T3TileController? = service.niriAppController(
            for: session.id,
            itemID: t3ItemID,
            appID: NiriAppID.t3Code,
            as: T3TileController.self
        )
        XCTAssertNotNil(initialT3Controller)

        service.closeNiriFocusedItem(in: session.id)
        let layout = service.niriLayout(for: session.id)
        let stillExists = layout.workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .contains(where: { $0.id == t3ItemID })

        XCTAssertFalse(stillExists)
        let removedT3Controller: T3TileController? = service.niriAppController(
            for: session.id,
            itemID: t3ItemID,
            appID: NiriAppID.t3Code,
            as: T3TileController.self
        )
        XCTAssertNil(removedT3Controller)
        assertHasSingleTrailingEmptyWorkspace(layout)
    }

    func testCloseNiriFocusedVSCodeTileRemovesItemAndController() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Close VSCode")).session
        service.ensureNiriLayoutState(for: session.id)
        guard let vscodeItemID = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.vscode) else {
            XCTFail("Expected VS Code tile")
            return
        }
        let initialVSCodeController: VSCodeTileController? = service.niriAppController(
            for: session.id,
            itemID: vscodeItemID,
            appID: NiriAppID.vscode,
            as: VSCodeTileController.self
        )
        XCTAssertNotNil(initialVSCodeController)

        service.closeNiriFocusedItem(in: session.id)
        let layout = service.niriLayout(for: session.id)
        let stillExists = layout.workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .contains(where: { $0.id == vscodeItemID })

        XCTAssertFalse(stillExists)
        let removedVSCodeController: VSCodeTileController? = service.niriAppController(
            for: session.id,
            itemID: vscodeItemID,
            appID: NiriAppID.vscode,
            as: VSCodeTileController.self
        )
        XCTAssertNil(removedVSCodeController)
        assertHasSingleTrailingEmptyWorkspace(layout)
    }

    func testCloseNiriFocusedOpenCodeTileRemovesItemControllerAndArtifacts() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Close OpenCode")).session
        service.ensureNiriLayoutState(for: session.id)
        guard let openCodeItemID = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.openCode) else {
            XCTFail("Expected OpenCode tile")
            return
        }

        let initialController: OpenCodeTileController? = service.niriAppController(
            for: session.id,
            itemID: openCodeItemID,
            appID: NiriAppID.openCode,
            as: OpenCodeTileController.self
        )
        XCTAssertNotNil(initialController)

        let paths = OpenCodeRuntimePaths(sessionID: session.id)
        try paths.ensureBaseDirectories()
        let marker = paths.sessionDirectory.appendingPathComponent("marker.txt", isDirectory: false)
        try "marker".write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        service.closeNiriFocusedItem(in: session.id)

        let layout = service.niriLayout(for: session.id)
        let stillExists = layout.workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .contains(where: { $0.id == openCodeItemID })
        XCTAssertFalse(stillExists)

        let removedController: OpenCodeTileController? = service.niriAppController(
            for: session.id,
            itemID: openCodeItemID,
            appID: NiriAppID.openCode,
            as: OpenCodeTileController.self
        )
        XCTAssertNil(removedController)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionDirectory.path))
        assertHasSingleTrailingEmptyWorkspace(layout)
    }

    func testCloseSessionWithOpenCodeCleansSessionArtifacts() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Close Session OpenCode")).session
        service.ensureNiriLayoutState(for: session.id)
        _ = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.openCode)

        let paths = OpenCodeRuntimePaths(sessionID: session.id)
        try paths.ensureBaseDirectories()
        let marker = paths.sessionDirectory.appendingPathComponent("marker.txt", isDirectory: false)
        try "marker".write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        service.closeSession(session.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionDirectory.path))
    }

    func testCloseNiriFocusedBrowserTileRemovesItem() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Close Browser")).session
        service.ensureNiriLayoutState(for: session.id)
        guard let browserItemID = service.niriAddBrowserRight(in: session.id) else {
            XCTFail("Expected browser tile")
            return
        }

        service.closeNiriFocusedItem(in: session.id)
        let layout = service.niriLayout(for: session.id)
        let stillExists = layout.workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .contains(where: { $0.id == browserItemID })

        XCTAssertFalse(stillExists)
        assertHasSingleTrailingEmptyWorkspace(layout)
    }

    func testCloseNiriFocusedTerminalTileClosesItsTab() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Close Terminal")).session
        service.ensureNiriLayoutState(for: session.id)
        let initialTabCount = service.tabs(for: session.id).count
        guard let addedItemID = service.niriAddTerminalRight(in: session.id) else {
            XCTFail("Expected terminal tile")
            return
        }
        XCTAssertEqual(service.tabs(for: session.id).count, initialTabCount + 1)

        service.closeNiriFocusedItem(in: session.id)
        let layout = service.niriLayout(for: session.id)
        let stillExists = layout.workspaces
            .flatMap(\.columns)
            .flatMap(\.items)
            .contains(where: { $0.id == addedItemID })

        XCTAssertFalse(stillExists)
        XCTAssertEqual(service.tabs(for: session.id).count, initialTabCount)
        assertHasSingleTrailingEmptyWorkspace(layout)
    }

    func testNiriColumnResizePersistsPreferredWidths() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Column Resize")).session
        service.ensureNiriLayoutState(for: session.id)
        _ = service.niriAddTerminalRight(in: session.id)

        var layout = service.niriLayout(for: session.id)
        guard let workspaceIndex = niriActiveWorkspaceIndex(layout),
              workspaceIndex < layout.workspaces.count,
              layout.workspaces[workspaceIndex].columns.count >= 2
        else {
            XCTFail("Expected at least two columns")
            return
        }

        let workspace = layout.workspaces[workspaceIndex]
        let left = workspace.columns[0]
        let right = workspace.columns[1]

        service.niriSetColumnWidths(
            sessionID: session.id,
            workspaceID: workspace.id,
            leftColumnID: left.id,
            leftWidth: 640,
            rightColumnID: right.id,
            rightWidth: 420
        )

        layout = service.niriLayout(for: session.id)
        let resizedWorkspace = layout.workspaces[workspaceIndex]
        XCTAssertEqual(resizedWorkspace.columns[0].preferredWidth, 640)
        XCTAssertEqual(resizedWorkspace.columns[1].preferredWidth, 420)
    }

    func testNiriItemResizePersistsPreferredHeights() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Item Resize")).session
        service.ensureNiriLayoutState(for: session.id)
        guard let _ = service.niriAddTaskBelow(in: session.id) else {
            XCTFail("Expected second task item")
            return
        }

        var layout = service.niriLayout(for: session.id)
        guard let workspaceIndex = niriActiveWorkspaceIndex(layout),
              let columnIndex = niriActiveColumnIndex(layout, workspaceIndex: workspaceIndex),
              layout.workspaces[workspaceIndex].columns[columnIndex].items.count >= 2
        else {
            XCTFail("Expected column with two items")
            return
        }

        let workspace = layout.workspaces[workspaceIndex]
        let column = workspace.columns[columnIndex]
        let upper = column.items[0]
        let lower = column.items[1]

        service.niriSetItemHeights(
            sessionID: session.id,
            workspaceID: workspace.id,
            columnID: column.id,
            upperItemID: upper.id,
            upperHeight: 300,
            lowerItemID: lower.id,
            lowerHeight: 220
        )

        layout = service.niriLayout(for: session.id)
        let resizedColumn = layout.workspaces[workspaceIndex].columns[columnIndex]
        XCTAssertEqual(resizedColumn.items[0].preferredHeight, 300)
        XCTAssertEqual(resizedColumn.items[1].preferredHeight, 220)
    }

    func testNiriMoveItemAcrossWorkspacesUpdatesCameraAndFocus() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Move")).session
        service.ensureNiriLayoutState(for: session.id)
        guard let sourceItemID = service.niriLayout(for: session.id).camera.focusedItemID else {
            XCTFail("Expected focused source item")
            return
        }

        service.focusNiriWorkspaceDown(sessionID: session.id)
        _ = service.niriAddTerminalRight(in: session.id)
        var layout = service.niriLayout(for: session.id)
        guard let destinationWorkspaceID = layout.camera.activeWorkspaceID else {
            XCTFail("Expected destination workspace")
            return
        }

        service.moveNiriItemToWorkspace(
            sessionID: session.id,
            itemID: sourceItemID,
            toWorkspaceID: destinationWorkspaceID
        )
        layout = service.niriLayout(for: session.id)

        let destinationContainsItem = layout.workspaces
            .first(where: { $0.id == destinationWorkspaceID })?
            .columns
            .flatMap(\.items)
            .contains(where: { $0.id == sourceItemID }) ?? false

        XCTAssertTrue(destinationContainsItem)
        XCTAssertEqual(layout.camera.focusedItemID, sourceItemID)
        XCTAssertEqual(layout.camera.activeWorkspaceID, destinationWorkspaceID)
        assertHasSingleTrailingEmptyWorkspace(layout)
    }

    func testNiriMoveT3TileAcrossWorkspacesPreservesInvariants() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Move T3")).session
        service.ensureNiriLayoutState(for: session.id)
        guard let t3ItemID = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.t3Code) else {
            XCTFail("Expected T3 tile")
            return
        }

        service.focusNiriWorkspaceDown(sessionID: session.id)
        _ = service.niriAddTerminalRight(in: session.id)
        let layout = service.niriLayout(for: session.id)
        guard let destinationWorkspaceID = layout.camera.activeWorkspaceID else {
            XCTFail("Expected destination workspace")
            return
        }

        service.moveNiriItemToWorkspace(
            sessionID: session.id,
            itemID: t3ItemID,
            toWorkspaceID: destinationWorkspaceID
        )
        let updated = service.niriLayout(for: session.id)
        let destinationContainsT3 = updated.workspaces
            .first(where: { $0.id == destinationWorkspaceID })?
            .columns
            .flatMap(\.items)
            .contains(where: { $0.id == t3ItemID }) ?? false

        XCTAssertTrue(destinationContainsT3)
        XCTAssertEqual(updated.camera.focusedItemID, t3ItemID)
        assertHasSingleTrailingEmptyWorkspace(updated)
    }

    func testNiriMoveVSCodeTileAcrossWorkspacesPreservesInvariants() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Move VSCode")).session
        service.ensureNiriLayoutState(for: session.id)
        guard let vscodeItemID = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.vscode) else {
            XCTFail("Expected VS Code tile")
            return
        }

        service.focusNiriWorkspaceDown(sessionID: session.id)
        _ = service.niriAddTerminalRight(in: session.id)
        let layout = service.niriLayout(for: session.id)
        guard let destinationWorkspaceID = layout.camera.activeWorkspaceID else {
            XCTFail("Expected destination workspace")
            return
        }

        service.moveNiriItemToWorkspace(
            sessionID: session.id,
            itemID: vscodeItemID,
            toWorkspaceID: destinationWorkspaceID
        )
        let updated = service.niriLayout(for: session.id)
        let destinationContainsVSCode = updated.workspaces
            .first(where: { $0.id == destinationWorkspaceID })?
            .columns
            .flatMap(\.items)
            .contains(where: { $0.id == vscodeItemID }) ?? false

        XCTAssertTrue(destinationContainsVSCode)
        XCTAssertEqual(updated.camera.focusedItemID, vscodeItemID)
        assertHasSingleTrailingEmptyWorkspace(updated)
    }

    func testNiriMoveOpenCodeTileAcrossWorkspacesPreservesInvariants() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Move OpenCode")).session
        service.ensureNiriLayoutState(for: session.id)
        guard let openCodeItemID = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.openCode) else {
            XCTFail("Expected OpenCode tile")
            return
        }

        service.focusNiriWorkspaceDown(sessionID: session.id)
        _ = service.niriAddTerminalRight(in: session.id)
        let layout = service.niriLayout(for: session.id)
        guard let destinationWorkspaceID = layout.camera.activeWorkspaceID else {
            XCTFail("Expected destination workspace")
            return
        }

        service.moveNiriItemToWorkspace(
            sessionID: session.id,
            itemID: openCodeItemID,
            toWorkspaceID: destinationWorkspaceID
        )
        let updated = service.niriLayout(for: session.id)
        let destinationContainsOpenCode = updated.workspaces
            .first(where: { $0.id == destinationWorkspaceID })?
            .columns
            .flatMap(\.items)
            .contains(where: { $0.id == openCodeItemID }) ?? false

        XCTAssertTrue(destinationContainsOpenCode)
        XCTAssertEqual(updated.camera.focusedItemID, openCodeItemID)
        assertHasSingleTrailingEmptyWorkspace(updated)
    }

    func testNiriTrailingEmptyWorkspaceInvariantWithMixedTileTypesIncludingVSCode() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Mixed Invariant")).session
        service.ensureNiriLayoutState(for: session.id)

        _ = service.niriAddBrowserRight(in: session.id)
        _ = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.t3Code)
        _ = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.vscode)
        _ = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.openCode)
        _ = service.niriAddTerminalRight(in: session.id)
        service.focusNiriWorkspaceDown(sessionID: session.id)
        _ = service.niriAddTerminalRight(in: session.id)
        service.moveNiriColumnToWorkspaceUp(sessionID: session.id)

        let layout = service.niriLayout(for: session.id)
        assertHasSingleTrailingEmptyWorkspace(layout)
    }

    func testNiriFocusedVSCodeTileRespondsToZoomAdjustments() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri VSCode Zoom")).session
        service.ensureNiriLayoutState(for: session.id)
        guard let vscodeItemID = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.vscode),
              let controller: VSCodeTileController = service.niriAppController(
                for: session.id,
                itemID: vscodeItemID,
                appID: NiriAppID.vscode,
                as: VSCodeTileController.self
              )
        else {
            XCTFail("Expected VS Code tile and controller")
            return
        }

        controller.webView.pageZoom = 1.0
        XCTAssertTrue(service.adjustNiriFocusedWebTileZoom(for: session.id, delta: 0.1))
        XCTAssertEqual(controller.webView.pageZoom, 1.1, accuracy: 0.0001)

        XCTAssertTrue(service.adjustNiriFocusedWebTileZoom(for: session.id, delta: -0.2))
        XCTAssertEqual(controller.webView.pageZoom, 0.9, accuracy: 0.0001)
    }

    func testNiriFocusedOpenCodeTileRespondsToZoomAdjustments() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri OpenCode Zoom")).session
        service.ensureNiriLayoutState(for: session.id)
        guard let openCodeItemID = service.niriAddSingletonAppRight(in: session.id, appID: NiriAppID.openCode),
              let controller: OpenCodeTileController = service.niriAppController(
                for: session.id,
                itemID: openCodeItemID,
                appID: NiriAppID.openCode,
                as: OpenCodeTileController.self
              )
        else {
            XCTFail("Expected OpenCode tile and controller")
            return
        }

        controller.webView.pageZoom = 1.0
        XCTAssertTrue(service.adjustNiriFocusedWebTileZoom(for: session.id, delta: 0.1))
        XCTAssertEqual(controller.webView.pageZoom, 1.1, accuracy: 0.0001)

        XCTAssertTrue(service.adjustNiriFocusedWebTileZoom(for: session.id, delta: -0.2))
        XCTAssertEqual(controller.webView.pageZoom, 0.9, accuracy: 0.0001)
    }

    func testNiriZoomAdjustmentIgnoresFocusedTerminalTile() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Terminal Zoom Ignore")).session
        service.ensureNiriLayoutState(for: session.id)

        XCTAssertFalse(service.adjustNiriFocusedWebTileZoom(for: session.id, delta: 0.1))
    }

    func testNiriFocusedTileZoomToggleTracksFocusedItem() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Focused Zoom Toggle")).session
        service.ensureNiriLayoutState(for: session.id)
        guard let focusedItemID = service.niriLayout(for: session.id).camera.focusedItemID else {
            XCTFail("Expected focused tile")
            return
        }

        XCTAssertNil(service.niriFocusedTileZoomItemID(for: session.id))
        XCTAssertTrue(service.toggleNiriFocusedTileZoom(sessionID: session.id))
        XCTAssertEqual(service.niriFocusedTileZoomItemID(for: session.id), focusedItemID)
        XCTAssertTrue(service.toggleNiriFocusedTileZoom(sessionID: session.id))
        XCTAssertNil(service.niriFocusedTileZoomItemID(for: session.id))
    }

    func testNiriFocusedTileZoomClearsWhenZoomedItemIsRemoved() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Focused Zoom Clear")).session
        service.ensureNiriLayoutState(for: session.id)
        guard let browserItemID = service.niriAddBrowserRight(in: session.id) else {
            XCTFail("Expected browser tile")
            return
        }

        XCTAssertTrue(service.toggleNiriFocusedTileZoom(sessionID: session.id))
        XCTAssertEqual(service.niriFocusedTileZoomItemID(for: session.id), browserItemID)

        service.closeNiriFocusedItem(in: session.id)

        XCTAssertNil(service.niriFocusedTileZoomItemID(for: session.id))
    }

    func testNiriDefaultTileSizesApplyOnlyToNewTiles() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Default Tile Sizes")).session
        service.ensureNiriLayoutState(for: session.id)

        service.saveSettings { settings in
            settings.niri.defaultNewColumnWidth = 900
            settings.niri.defaultNewTileHeight = 520
        }

        guard let firstItemID = service.niriAddTerminalRight(in: session.id) else {
            XCTFail("Expected first terminal tile")
            return
        }

        var layout = service.niriLayout(for: session.id)
        guard let firstPath = service.findNiriItemPath(layout: layout, itemID: firstItemID) else {
            XCTFail("Expected path for first tile")
            return
        }
        let firstWidth = try XCTUnwrap(layout.workspaces[firstPath.workspaceIndex].columns[firstPath.columnIndex].preferredWidth)
        let firstHeight = try XCTUnwrap(layout.workspaces[firstPath.workspaceIndex].columns[firstPath.columnIndex].items[firstPath.itemIndex].preferredHeight)
        XCTAssertEqual(firstWidth, 900, accuracy: 0.001)
        XCTAssertEqual(firstHeight, 520, accuracy: 0.001)

        service.saveSettings { settings in
            settings.niri.defaultNewColumnWidth = 1100
            settings.niri.defaultNewTileHeight = 640
        }

        guard let secondItemID = service.niriAddTaskBelow(in: session.id),
              let thirdItemID = service.niriAddTerminalRight(in: session.id) else {
            XCTFail("Expected additional terminal tiles")
            return
        }

        layout = service.niriLayout(for: session.id)
        guard let secondPath = service.findNiriItemPath(layout: layout, itemID: secondItemID),
              let thirdPath = service.findNiriItemPath(layout: layout, itemID: thirdItemID)
        else {
            XCTFail("Expected paths for new tiles")
            return
        }

        let unchangedFirstWidth = try XCTUnwrap(layout.workspaces[firstPath.workspaceIndex].columns[firstPath.columnIndex].preferredWidth)
        let unchangedFirstHeight = try XCTUnwrap(layout.workspaces[firstPath.workspaceIndex].columns[firstPath.columnIndex].items[firstPath.itemIndex].preferredHeight)
        let secondHeight = try XCTUnwrap(layout.workspaces[secondPath.workspaceIndex].columns[secondPath.columnIndex].items[secondPath.itemIndex].preferredHeight)
        let thirdWidth = try XCTUnwrap(layout.workspaces[thirdPath.workspaceIndex].columns[thirdPath.columnIndex].preferredWidth)
        let thirdHeight = try XCTUnwrap(layout.workspaces[thirdPath.workspaceIndex].columns[thirdPath.columnIndex].items[thirdPath.itemIndex].preferredHeight)

        XCTAssertEqual(unchangedFirstWidth, 900, accuracy: 0.001)
        XCTAssertEqual(unchangedFirstHeight, 520, accuracy: 0.001)
        XCTAssertEqual(secondHeight, 640, accuracy: 0.001)
        XCTAssertEqual(thirdWidth, 1100, accuracy: 0.001)
        XCTAssertEqual(thirdHeight, 640, accuracy: 0.001)
    }

    func testNiriGenericAppSelectionEnsuresControllerViaDescriptorFactory() async throws {
        let registry = NiriAppRegistry()
        let fixture = try Fixture(niriAppRegistry: registry)
        let service = fixture.service
        let tracker = StubNiriAppTracker()
        let appID = "stub-app"

        registry.register(makeStubNiriAppDescriptor(appID: appID, tracker: tracker))

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Generic Select")).session
        let itemID = addStubNiriAppTile(appID: appID, sessionID: session.id, service: service)

        service.niriSelectItem(sessionID: session.id, itemID: itemID)

        XCTAssertEqual(tracker.ensureCalls.count, 1)
        XCTAssertEqual(tracker.ensureCalls.first?.sessionID, session.id)
        XCTAssertEqual(tracker.ensureCalls.first?.itemID, itemID)
        XCTAssertNotNil(tracker.controller(for: itemID))
    }

    func testNiriGenericAppRetryDispatchesThroughGenericPath() async throws {
        let registry = NiriAppRegistry()
        let fixture = try Fixture(niriAppRegistry: registry)
        let service = fixture.service
        let tracker = StubNiriAppTracker()
        let appID = "stub-app"

        registry.register(makeStubNiriAppDescriptor(appID: appID, tracker: tracker))

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Generic Retry")).session
        let itemID = addStubNiriAppTile(appID: appID, sessionID: session.id, service: service)
        service.niriSelectItem(sessionID: session.id, itemID: itemID)

        service.retryNiriAppTile(sessionID: session.id, itemID: itemID, appID: appID)

        XCTAssertEqual(tracker.retryCalls.count, 1)
        XCTAssertEqual(tracker.retryCalls.first?.sessionID, session.id)
        XCTAssertEqual(tracker.retryCalls.first?.itemID, itemID)
        XCTAssertEqual(tracker.controller(for: itemID)?.retryCount, 1)
    }

    func testNiriGenericAppFocusedZoomDispatchesThroughController() async throws {
        let registry = NiriAppRegistry()
        let fixture = try Fixture(niriAppRegistry: registry)
        let service = fixture.service
        let tracker = StubNiriAppTracker()
        let appID = "stub-app"

        registry.register(makeStubNiriAppDescriptor(appID: appID, tracker: tracker))

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Generic Zoom")).session
        let itemID = addStubNiriAppTile(appID: appID, sessionID: session.id, service: service)
        service.niriSelectItem(sessionID: session.id, itemID: itemID)

        XCTAssertTrue(service.adjustNiriFocusedWebTileZoom(for: session.id, delta: 0.25))
        XCTAssertEqual(tracker.controller(for: itemID)?.zoomAdjustments, [0.25])
    }

    func testNiriGenericAppCleanupRunsOnceWhenLastTileRemoved() async throws {
        let registry = NiriAppRegistry()
        let fixture = try Fixture(niriAppRegistry: registry)
        let service = fixture.service
        let tracker = StubNiriAppTracker()
        let appID = "stub-app"

        registry.register(makeStubNiriAppDescriptor(appID: appID, tracker: tracker))

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Generic Remove Cleanup")).session
        let itemID = addStubNiriAppTile(appID: appID, sessionID: session.id, service: service)
        service.niriSelectItem(sessionID: session.id, itemID: itemID)

        service.closeNiriFocusedItem(in: session.id)

        XCTAssertEqual(tracker.cleanupCallCount(for: session.id), 1)
    }

    func testNiriGenericAppCleanupRunsOnceWhenSessionCloses() async throws {
        let registry = NiriAppRegistry()
        let fixture = try Fixture(niriAppRegistry: registry)
        let service = fixture.service
        let tracker = StubNiriAppTracker()
        let appID = "stub-app"

        registry.register(makeStubNiriAppDescriptor(appID: appID, tracker: tracker))

        let session = try await service.createSession(from: SessionCreationRequest(title: "Niri Generic Session Cleanup")).session
        _ = addStubNiriAppTile(appID: appID, sessionID: session.id, service: service)

        service.closeSession(session.id)

        XCTAssertEqual(tracker.cleanupCallCount(for: session.id), 1)
    }

    func testVSCodeBrowserDebugLaunchConfigUpsertCreatesAttachConfig() throws {
        let data = try SessionService.upsertVSCodeBrowserAttachConfigurationData(
            existingData: nil,
            configurationName: "Attach Chrome (idx-web)",
            port: 9222,
            urlFilter: "http://localhost:3000/*",
            webRoot: "${workspaceFolder}/idx-web"
        )
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["version"] as? String, "0.2.0")
        let configurations = try XCTUnwrap(root["configurations"] as? [[String: Any]])
        XCTAssertEqual(configurations.count, 1)
        XCTAssertEqual(configurations[0]["type"] as? String, "pwa-chrome")
        XCTAssertEqual(configurations[0]["request"] as? String, "attach")
        XCTAssertEqual(configurations[0]["port"] as? Int, 9222)
    }

    func testVSCodeBrowserDebugLaunchConfigUpsertUpdatesExistingByName() throws {
        let existing = """
        {
          "version": "0.2.0",
          "configurations": [
            {
              "name": "Attach Chrome (idx-web)",
              "type": "pwa-chrome",
              "request": "attach",
              "port": 9001,
              "presentation": { "group": "idx0" }
            }
          ]
        }
        """.data(using: .utf8)

        let updatedData = try SessionService.upsertVSCodeBrowserAttachConfigurationData(
            existingData: existing,
            configurationName: "Attach Chrome (idx-web)",
            port: 9222,
            urlFilter: "http://localhost:3000/*",
            webRoot: "${workspaceFolder}"
        )
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
        let configurations = try XCTUnwrap(root["configurations"] as? [[String: Any]])
        XCTAssertEqual(configurations.count, 1)
        XCTAssertEqual(configurations[0]["port"] as? Int, 9222)
        XCTAssertEqual(configurations[0]["webRoot"] as? String, "${workspaceFolder}")
        XCTAssertNotNil(configurations[0]["presentation"])
    }

    func testVSCodeBrowserDebugLaunchConfigUpsertParsesJSONC() throws {
        let existingJSONC = """
        // VS Code launch configs
        {
          "version": "0.2.0",
          /* keep user configs */
          "configurations": []
        }
        """.data(using: .utf8)

        let updatedData = try SessionService.upsertVSCodeBrowserAttachConfigurationData(
            existingData: existingJSONC,
            configurationName: "Attach Chrome (idx-web)",
            port: 9222,
            urlFilter: "http://localhost:3000/*",
            webRoot: "${workspaceFolder}/idx-web"
        )
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
        let configurations = try XCTUnwrap(root["configurations"] as? [[String: Any]])
        XCTAssertEqual(configurations.count, 1)
    }

    func testVSCodeWorkspaceDebugSettingsUpsertTurnsOffDebugByLink() throws {
        let existing = """
        {
          "editor.tabSize": 2
        }
        """.data(using: .utf8)

        let updatedData = try SessionService.upsertVSCodeWorkspaceDebugSettingsData(existingData: existing)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
        XCTAssertEqual(root["debug.javascript.debugByLinkOptions"] as? String, "off")
        XCTAssertEqual(root["editor.tabSize"] as? Int, 2)
    }

    func testNiriLegacyCellsMigrateToWorkspaceModel() async throws {
        let fixture = try Fixture()
        let service = fixture.service

        let session = try await service.createSession(from: SessionCreationRequest(title: "Legacy")).session
        service.ensureNiriLayoutState(for: session.id)
        guard let selectedTabID = service.selectedTabID(for: session.id),
              let secondTabID = service.createTab(in: session.id, activate: false)
        else {
            XCTFail("Expected existing and second tab IDs")
            return
        }

        let legacyLayout = NiriCanvasLayout(
            workspaces: [],
            camera: NiriCameraState(),
            isOverviewOpen: false,
            legacyCells: [
                NiriCanvasCell(
                    id: UUID(),
                    column: 0,
                    row: 0,
                    item: .terminal(tabID: selectedTabID)
                ),
                NiriCanvasCell(
                    id: UUID(),
                    column: 0,
                    row: 1,
                    item: .terminal(tabID: secondTabID)
                )
            ]
        )
        service.setNiriLayoutForTesting(sessionID: session.id, layout: legacyLayout)

        service.ensureNiriLayoutState(for: session.id)
        let migrated = service.niriLayout(for: session.id)

        XCTAssertGreaterThanOrEqual(migrated.workspaces.count, 3)
        XCTAssertEqual(migrated.workspaces[0].columns.count, 1)
        XCTAssertEqual(migrated.workspaces[1].columns.count, 1)
        XCTAssertTrue(migrated.legacyCells.isEmpty)
        assertHasSingleTrailingEmptyWorkspace(migrated)
    }

}
