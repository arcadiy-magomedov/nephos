import Foundation
import XCTest

@testable import NephosCore

@MainActor
private final class SocialFixtureTokens: AccessTokenProviding {
    let value: String
    init(_ value: String) { self.value = value }
    func accessToken() async throws -> String { value }
}

final class NativeSocialTests: XCTestCase {
    @MainActor
    func testRealPeopleCorrectionsSharingAndRevocation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["NEPHOS_SOCIAL_E2E"] == "1" else {
            throw XCTSkip("Run python3 run_social_e2e.py --backend-stable for real face/sharing acceptance.")
        }
        guard let ownerToken = env["NEPHOS_E2E_BEARER"],
            let recipientToken = env["NEPHOS_E2E_RECIPIENT_BEARER"],
            let recipientID = env["NEPHOS_E2E_RECIPIENT"],
            let library = env["NEPHOS_E2E_LIBRARY"].flatMap(UUID.init(uuidString:)),
            let rawAssets = env["NEPHOS_E2E_ASSETS"]
        else { throw ClientError.invalid("Missing isolated social fixture.") }
        let assets = rawAssets.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
        XCTAssertEqual(assets.count, 2)
        let base = URL(string: "http://localhost:18080")!
        let config = try await HTTP.json(ServerConfig.self, HTTP.request(base.appendingPathComponent("v1/config")))
        let connection = Connection(baseURL: base, config: config, allowDevelopmentHTTP: true)
        let owner = API(connection: connection, auth: SocialFixtureTokens(ownerToken))
        let recipient = API(connection: connection, auth: SocialFixtureTokens(recipientToken))
        let observations = try await owner.observations()
        XCTAssertEqual(observations.items.count, 2)
        let first = try XCTUnwrap(observations.items.first { $0.assetId == assets[0] })
        let second = try XCTUnwrap(observations.items.first { $0.assetId == assets[1] })
        let firstPerson = try XCTUnwrap(first.personId)
        let secondPerson = try XCTUnwrap(second.personId)
        XCTAssertNotEqual(firstPerson, secondPerson)
        try await owner.namePerson(firstPerson, input: PersonNameInput(name: "Fixture One", aliases: ["Fixture Alias"]))
        try await owner.namePerson(secondPerson, input: PersonNameInput(name: "Fixture Two", aliases: []))
        let named = try await owner.people(name: "fixture alias")
        XCTAssertEqual(named.items.map(\.id), [firstPerson])
        let personPhotos = try await owner.personAssets(firstPerson)
        XCTAssertEqual(personPhotos.items, [assets[0]])
        let metadata = try await owner.assets(ids: personPhotos.items)
        XCTAssertEqual(metadata.map(\.id), personPhotos.items)
        try await owner.mergePerson(secondPerson, into: firstPerson)
        let merged = try await owner.person(secondPerson)
        XCTAssertEqual(merged.redirectId, firstPerson)
        let mergedAssets = try await owner.personAssets(firstPerson)
        XCTAssertEqual(Set(mergedAssets.items), Set(assets))
        try await owner.undoMerge(secondPerson)
        let unmerged = try await owner.person(secondPerson)
        XCTAssertNil(unmerged.redirectId)
        try await owner.splitObservation(first.id)
        let splitObservations = try await owner.observations(asset: assets[0])
        let split = try XCTUnwrap(splitObservations.items.first?.personId)
        XCTAssertNotEqual(split, firstPerson)
        try await owner.assignObservation(first.id, person: firstPerson)
        try await owner.negativeMatch(firstPerson, other: secondPerson)
        do {
            try await owner.mergePerson(secondPerson, into: firstPerson)
            XCTFail("A negative match must prevent merging.")
        } catch ClientError.http(409, _) {}
        try await owner.removeNegativeMatch(firstPerson, other: secondPerson)
        try await owner.mergePerson(secondPerson, into: firstPerson)
        try await owner.undoMerge(secondPerson)
        let history = try await owner.corrections()
        XCTAssertTrue(history.items.contains { $0.kind == "merge" })
        XCTAssertTrue(history.items.contains { $0.kind == "unmerge" })
        let privatePeople = try await recipient.people()
        XCTAssertTrue(privatePeople.items.isEmpty)
        do {
            _ = try await recipient.person(firstPerson)
            XCTFail("Private face names leaked to a different account.")
        } catch ClientError.http(404, _) {}
        var cursor: String?
        var known: [DirectoryUser] = []
        repeat {
            let page = try await owner.directory(after: cursor)
            known += page.items
            cursor = page.nextCursor
        } while cursor != nil && known.count < 1000
        XCTAssertTrue(known.contains { $0.id == recipientID })
        let shareID = UUID()
        let input = ShareInput(libraryId: library, recipientId: recipientID, allAssets: false, assetIds: [assets[0]])
        let selected = try await owner.putShare(shareID, input: input)
        XCTAssertEqual(selected.assetIds, [assets[0]])
        _ = try await owner.putShare(shareID, input: input)
        let recipientShares = try await recipient.shares()
        XCTAssertTrue(recipientShares.items.contains { $0.id == shareID })
        let sharedAsset = try await recipient.asset(assets[0])
        XCTAssertNotNil(sharedAsset.sharedBy)
        let sharedLibraries = try await recipient.libraries()
        XCTAssertTrue(sharedLibraries.items.contains { $0.id == library && $0.isReadOnly })
        _ = try await HTTP.data(recipient.previewRequest(assets[0], size: .thumbnail), maximum: 8 * 1024 * 1024)
        await assertDenied { _ = try await recipient.asset(assets[1]) }
        _ = try await owner.putShare(
            shareID, input: ShareInput(libraryId: library, recipientId: recipientID, allAssets: true, assetIds: []))
        _ = try await recipient.asset(assets[1])
        _ = try await owner.putShare(shareID, input: input)
        await assertDenied { _ = try await recipient.asset(assets[1]) }
        try await owner.deleteShare(shareID)
        await assertDenied { _ = try await recipient.asset(assets[0]) }
        await assertDenied {
            _ = try await HTTP.data(recipient.previewRequest(assets[0], size: .thumbnail), maximum: 8 * 1024 * 1024)
        }
        print(
            "PASS native real API: face crops/labels/merge/undo/split/assignment/negative match/private history, directory, selected/all sharing, narrowing and revocation"
        )
    }

    @MainActor
    private func assertDenied(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Access should have been denied.")
        } catch ClientError.http(let status, _) {
            XCTAssertTrue([403, 404].contains(status))
        } catch {
            XCTFail("Unexpected failure: \(error)")
        }
    }
}
