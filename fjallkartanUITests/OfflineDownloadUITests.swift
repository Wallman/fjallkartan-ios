import UIKit
import XCTest

// excluded from CI in scheme
final class OfflineDownloadUITests: XCTestCase {

    @MainActor
    func testOfflineRegionAndSearch_withDownload_showsTiles() throws {
        var app = launch(networkDisabled: false)
        let regionName = "UI Test Region \(Int(Date().timeIntervalSince1970))"
        let searchQuery = "stockholm"

        searchAndSelectSecondResult(searchQuery: searchQuery, in: app)
        clickDownloadButton(in: app)
        startDownload(regionName: regionName, in: app)
        awaitDownload(regionName: regionName, in: app)
        
//        backgroundApp(app, seconds: 20) // make sure download continues in background, does not work on simulator

        app = launch(networkDisabled: true)
        searchAndSelectSecondResult(searchQuery: "gävle", in: app)
        clearTileCache(in: app)

        searchAndSelectSecondResult(searchQuery: searchQuery, in: app)
        assertMapShowsTiles(in: app)
        drawRouteAndVerifyElevation(in: app)

        // clean up
        deleteRegion(regionName: regionName, in: app)
    }

    @MainActor
    func testOfflineRegionAndSearch_withoutDownload_showsNoTiles() throws {
        var app = launch(networkDisabled: false)
        let searchQuery = "ume"

        searchAndSelectSecondResult(searchQuery: searchQuery, in: app)
        clearTileCache(in: app)
        app.terminate()
        
        app = launch(networkDisabled: true)

        searchAndSelectSecondResult(searchQuery: searchQuery, in: app)
        assertMapShowsNoTiles(in: app)
    }
    
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(networkDisabled: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        if networkDisabled {
            app.launchEnvironment["UITEST_DISABLE_NETWORK"] = "1"
        }
        app.launch()
        return app;
    }

    @MainActor
    private func clearTileCache(in app: XCUIApplication) {
        let aboutButton = app.buttons["about.open"]
        XCTAssertTrue(aboutButton.waitForExistence(timeout: 5), "about button never appeared")
        aboutButton.tap()

        let versionRow = app.descendants(matching: .any)["about.version"]
        XCTAssertTrue(versionRow.waitForExistence(timeout: 5), "version row never appeared")
        versionRow.press(forDuration: 1.0) // undiscoverable on purpose — see AboutView

        let clearButton = app.buttons["debug.clearTileCache"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 5), "clear tile cache button never appeared")
        clearButton.tap()

        let message = app.staticTexts["debug.tileCacheClearedMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 10), "tile cache never finished clearing")

        app.buttons["debug.done"].tap()
        app.buttons["about.done"].tap()
    }

    @MainActor
    private func backgroundApp(_ app: XCUIApplication, seconds: TimeInterval) {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: seconds)
        app.activate()
        let searchButton = app.buttons["mapControls.search"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 15),
                      "app never came back to the foreground after backgrounding")
    }

    @MainActor
    private func searchAndSelectSecondResult(searchQuery: String, in app: XCUIApplication) {
        let searchButton = app.buttons["mapControls.search"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 10), "search button never appeared")
        searchButton.tap()

        let field = app.textFields["placeSearch.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "search field never appeared")
        let clearButton = app.buttons["xmark.circle.fill"]
        if clearButton.waitForExistence(timeout: 1) {
            clearButton.tap()
        }
        field.typeText(searchQuery)

        let secondResult = app.cells.element(boundBy: 1)
        XCTAssertTrue(secondResult.waitForExistence(timeout: 5),
                      "search never returned a second result for \"\(searchQuery)\"")
        secondResult.tap()
    }

    @MainActor
    private func drawRouteAndVerifyElevation(in app: XCUIApplication) {
        let map = app.otherElements["map"]
        XCTAssertTrue(map.waitForExistence(timeout: 10), "map never appeared")

        let measureButton = app.buttons["mapControls.measure"]
        XCTAssertTrue(measureButton.waitForExistence(timeout: 5), "ruler button never appeared")
        measureButton.tap()

        let start = map.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45))
        let end = map.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55))
        start.press(forDuration: 0.1, thenDragTo: end)

        let distanceReadout = app.otherElements["measureReadout.distance"]
        XCTAssertTrue(distanceReadout.waitForExistence(timeout: 20), "distance readout never appeared")

        let elevationSummary = distanceReadout.descendants(matching: .any)["measureReadout.elevationSummary"]
        XCTAssertTrue(elevationSummary.waitForExistence(timeout: 20), "ascent/descent summary never appeared — elevation lookup never completed")
    }

    @MainActor
    private func clickDownloadButton(in app: XCUIApplication) {
        let toggleMoreControls = app.buttons["mapControls.toggleMore"]
        XCTAssertTrue(toggleMoreControls.waitForExistence(timeout: 5), "map controls never appeared")
        toggleMoreControls.tap()

        let downloadToggle = app.buttons["mapControls.download"]
        XCTAssertTrue(downloadToggle.waitForExistence(timeout: 5), "download toggle never appeared")
        downloadToggle.tap()
    }

    @MainActor
    private func startDownload(regionName: String, in app: XCUIApplication) {
        let startDownload = app.buttons["offlineRegions.startDownload"]
        XCTAssertTrue(startDownload.waitForExistence(timeout: 5), "\"Download this area\" bar never appeared")
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: startDownload
        )
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed,
                       "\"Download this area\" stayed disabled after selecting a search result")
        startDownload.tap()

        let namingAlert = app.alerts.firstMatch
        XCTAssertTrue(namingAlert.waitForExistence(timeout: 5), "naming alert never appeared")
        let nameField = namingAlert.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "naming alert's text field never appeared")
        nameField.typeText(regionName)
        let saveButton = namingAlert.buttons.element(boundBy: 1)
        XCTAssertTrue(saveButton.exists, "naming alert's save button never appeared")
        saveButton.tap()
        Thread.sleep(forTimeInterval: 0.2)
    }

    @MainActor
    private func awaitDownload(regionName: String, in app: XCUIApplication) {
        let doneIcon = app.images["offlineRegions.complete.\(regionName)"]
        XCTAssertTrue(doneIcon.waitForExistence(timeout: 20), "download never finished")

        XCTAssertFalse(app.staticTexts["offlineRegions.error.\(regionName)"].exists,
                        "an error message showed up while downloading the region")

        app.buttons["offlineRegions.done"].tap()
    }

    @MainActor
    private func assertMapShowsTiles(in app: XCUIApplication) {
        let map = app.otherElements["map"]
        XCTAssertTrue(map.waitForExistence(timeout: 10), "map never appeared")

        // Give the raster layer a moment to finish compositing after the
        // camera move triggered by the search selection above.
        Thread.sleep(forTimeInterval: 2)

        guard let cgImage = map.screenshot().image.cgImage else {
            XCTFail("couldn't get pixel data from the map screenshot")
            return
        }
        XCTAssertTrue(imageHasVisualVariety(cgImage, sampleRect: CGRect(x: 0.06, y: 0.16, width: 0.34, height: 0.64)),
                      "map looks blank/flat while offline — no tile imagery visible")
    }

    @MainActor
    private func assertMapShowsNoTiles(in app: XCUIApplication) {
        let map = app.otherElements["map"]
        XCTAssertTrue(map.waitForExistence(timeout: 5), "map never appeared")

        Thread.sleep(forTimeInterval: 2)

        guard let cgImage = map.screenshot().image.cgImage else {
            XCTFail("couldn't get pixel data from the map screenshot")
            return
        }
        XCTAssertFalse(imageHasVisualVariety(cgImage, sampleRect: CGRect(x: 0.06, y: 0.16, width: 0.34, height: 0.64)),
                        "map showed tile imagery even though no region was ever downloaded — " +
                        "the offline verification in testOfflineRegionViaSearch() is a false positive")
    }

    private func imageHasVisualVariety(
        _ image: CGImage,
        sampleRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) -> Bool {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return false }

        let bytesPerRow = image.bytesPerRow
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let length = CFDataGetLength(data)

        let gridSize = 12
        var buckets = Set<[UInt8]>()
        for row in 0..<gridSize {
            for col in 0..<gridSize {
                let colFraction = sampleRect.minX + (CGFloat(col) + 0.5) / CGFloat(gridSize) * sampleRect.width
                let rowFraction = sampleRect.minY + (CGFloat(row) + 0.5) / CGFloat(gridSize) * sampleRect.height
                let x = min(width - 1, max(0, Int(CGFloat(width) * colFraction)))
                let y = min(height - 1, max(0, Int(CGFloat(height) * rowFraction)))
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < length else { continue }
                buckets.insert([bytes[offset] / 8, bytes[offset + 1] / 8, bytes[offset + 2] / 8])
            }
        }

        return buckets.count > 3
    }

    @MainActor
    private func deleteRegion(regionName: String, in app: XCUIApplication) {
        clickDownloadButton(in: app)
        let regionsButton = app.buttons["mapControls.regions"]
        XCTAssertTrue(regionsButton.waitForExistence(timeout: 5))
        regionsButton.tap()

        let offlineRegionRow = app.staticTexts[regionName]
        XCTAssertTrue(offlineRegionRow.waitForExistence(timeout: 10), "region no longer listed after relaunch")

        let deleteButton = app.buttons["offlineRegions.delete.\(regionName)"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.tap()

        let confirmDialog = app.sheets.firstMatch.waitForExistence(timeout: 5)
            ? app.sheets.firstMatch : app.alerts.firstMatch
        XCTAssertTrue(confirmDialog.exists)
        confirmDialog.buttons.element(boundBy: 0).tap()

        let rowGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: offlineRegionRow
        )
        XCTAssertEqual(XCTWaiter().wait(for: [rowGone], timeout: 10), .completed,
                       "region row never disappeared after delete")

        let doneButton = app.buttons["offlineRegions.done"]
        doneButton.tap()
    }
}

