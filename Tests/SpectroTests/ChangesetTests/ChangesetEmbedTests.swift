import Foundation
import Testing
@testable import Spectro

@EmbeddedSchema
struct EmbedAddress {
    @Column var street: String
    @Column var city: String
    @Column var postalCode: String?
}

@EmbeddedSchema
struct EmbedPhone {
    @ID var id: UUID
    @Column var number: String
    @Column var kind: String = "mobile"
}

@EmbeddedSchema
struct EmbedSettings {
    @Column var theme: String = "light"
    @Column var address: EmbedAddress?
}

@Schema("embed_users")
struct EmbedUser {
    @ID var id: UUID
    @Column var name: String
    @Column var address: EmbedAddress?
    @Column var settings: EmbedSettings
    @Column var phones: [EmbedPhone] = []
}

@EmbeddedSchema
struct EmbedProfile {
    @Column var nickname: String? = "anon"
    @Column var userID: Int = 0
    @Column("zip") var postal: String = ""
}

@EmbeddedSchema
struct EmbedVisit {
    @Column var at: Date
}

@EmbeddedSchema
struct EmbedTag: JSONBValue {
    @Column var label: String
}

enum EmbedOuter {
    @EmbeddedSchema
    struct Inner {
        @Column var city: String
    }

    @Schema("embed_outer_rows")
    struct Row: Encodable {
        @ID var id: UUID
        @Column var name: String
    }
}

private func address(_ address: EmbedAddress?, _ params: [String: any Sendable]) -> Changeset<EmbedAddress> {
    Changeset.cast(address, params: params, permitted: ["street", "city", "postalCode"]).validateRequired(["city"])
}

private func phone(_ phone: EmbedPhone?, _ params: [String: any Sendable]) -> Changeset<EmbedPhone> {
    Changeset.cast(phone, params: params, permitted: ["number", "kind"]).validateRequired(["number"])
}

@Suite("Embedded schemas")
struct ChangesetEmbedTests {
    @Test("An embedded schema validates alone, as a form, and applies its changes")
    func form() throws {
        #expect(EmbedAddress.tableName == "")
        let invalid = address(nil, ["street": "1 Rue Haute", "city": ""])
        #expect(invalid.errors == ["city": ["can't be blank"]])
        #expect(throws: SpectroError.self) { try invalid.applyToInstance() }

        let applied = try address(nil, ["street": "1 Rue Haute", "city": "Lyon"]).applyToInstance()
        #expect(applied.street == "1 Rue Haute" && applied.city == "Lyon" && applied.postalCode == nil)
        let updated = try address(applied, ["postalCode": "69001"]).applyToInstance()
        #expect(updated.street == "1 Rue Haute" && updated.postalCode == "69001")
    }

    @Test("Embedded values encode under column names, keep nil, and decode missing keys as defaults")
    func coding() throws {
        let value = EmbedAddress(street: "Main", city: "Oslo", postalCode: "0150")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: String]
        #expect(json == ["street": "Main", "city": "Oslo", "postal_code": "0150"])
        let decoded = EmbedAddress.fromPostgresData(try value.toPostgresData())
        #expect(decoded?.city == "Oslo" && decoded?.postalCode == "0150")

        var profile = EmbedProfile()
        profile.nickname = nil
        profile.userID = 7
        let keys = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any]
        #expect(Set(keys?.keys ?? [:].keys) == ["nickname", "user_id", "zip"])
        #expect(EmbedProfile.fromPostgresData(try profile.toPostgresData())?.nickname == nil)
        #expect(try JSONDecoder().decode(EmbedProfile.self, from: Data("{}".utf8)).nickname == "anon")

        let partial = try JSONDecoder().decode(EmbedPhone.self, from: Data(#"{"number": "555"}"#.utf8))
        #expect(partial.number == "555" && partial.kind == "mobile")
        #expect(EmbedPhone.cast(partial)?.number == "555")
        #expect(EmbedPhone.cast(["number": "555"] as [String: any Sendable]) == nil)

        #expect(EmbedOuter.Inner.fromPostgresData(try EmbedOuter.Inner(city: "Rome").toPostgresData())?.city == "Rome")
        #expect(EmbedTag.fromPostgresData(try EmbedTag(label: "a").toPostgresData())?.label == "a")
        #expect(EmbedOuter.Row.tableName == "embed_outer_rows")
        #expect(try JSONSerialization.jsonObject(with: JSONEncoder().encode(EmbedOuter.Row(name: "a"))) is [String: Any])

        let at = Date(timeIntervalSince1970: 0.25)
        let stored = try EmbedVisit(at: at).toPostgresData()
        #expect(stored.jsonb.map { String(decoding: $0, as: UTF8.self) } == #"{"at":"1970-01-01T00:00:00.250Z"}"#)
        #expect(EmbedVisit.fromPostgresData(stored)?.at == at)
        #expect([String: Date].cast(["at": "1970-01-01T00:00:00Z"] as [String: any Sendable]) == ["at": Date(timeIntervalSince1970: 0)])
    }

    @Test("castEmbed reads the field's params, updates the record's value, and joins its errors")
    func one() throws {
        let invalid = Changeset<EmbedUser>.cast(nil, params: ["name": "Ana", "address": ["street": "Main"]], permitted: ["name"])
            .castEmbed(\.address, with: address)
        #expect(invalid.errors == ["address.city": ["can't be blank"]])

        var user = EmbedUser()
        user.address = EmbedAddress(street: "Main", city: "Oslo")
        let changeset = Changeset.cast(user, params: ["address": ["city": "Bergen"]], permitted: [])
            .castEmbed(\.address, with: address)
        #expect(changeset.isValid)
        #expect(changeset.getChange(\.address)??.street == "Main")
        #expect(changeset.getChange(\.address)??.city == "Bergen")

        let untouched = Changeset.cast(user, params: ["name": "Bo"], permitted: ["name"]).castEmbed(\.address, with: address)
        #expect(untouched.isValid && !untouched.changes.keys.contains("address"))

        for removal: any Sendable in [NSNull(), String?.none] {
            let removed = Changeset.cast(user, params: ["address": removal], permitted: []).castEmbed(\.address, with: address)
            #expect(removed.changes.keys.contains("address") && removed.getField(\.address) == nil)
        }
        let wrong = Changeset.cast(user, params: ["address": "Main"], permitted: []).castEmbed(\.address, with: address)
        #expect(wrong.errors == ["address": ["is invalid"]])

        // cast accepts only values of the embedded type; castEmbed replaces its error.
        let permitted = Changeset<EmbedUser>.cast(nil, params: ["address": ["city": "Oslo"]], permitted: ["address"])
        #expect(permitted.errors == ["address": ["is invalid"]])
        #expect(permitted.castEmbed(\.address, with: address).getChange(\.address)??.city == "Oslo")
    }

    @Test("castEmbed matches a list's values by primary key, adds new ones, and drops the rest")
    func many() throws {
        let kept = EmbedPhone(number: "111", kind: "work")
        var user = EmbedUser()
        user.phones = [kept, EmbedPhone(number: "222", kind: "mobile")]
        let params: [String: any Sendable] = ["phones": [["id": kept.id.uuidString, "number": "112"], ["number": "333"]]]
        let changeset = Changeset.cast(user, params: params, permitted: []).castEmbed(\.phones, with: phone)
        let phones = try #require(changeset.getChange(\.phones))
        #expect(phones.map(\.number) == ["112", "333"])
        #expect(phones[0].id == kept.id && phones[0].kind == "work")
        #expect(phones[1].id != kept.id && phones[1].kind == "mobile")

        // A cast starts from the record's values, not from an earlier put.
        let afterPut = Changeset.cast(user, params: params, permitted: [])
            .putEmbed(\.phones, [EmbedPhone(number: "0", kind: "home")])
            .castEmbed(\.phones, with: phone)
        #expect(afterPut.getChange(\.phones)?.first?.id == kept.id)

        let invalid = Changeset.cast(user, params: ["phones": [["number": "1"], ["kind": "home"]]], permitted: [])
            .castEmbed(\.phones, with: phone)
        #expect(invalid.errors == ["phones[1].number": ["can't be blank"]])
        let wrong = Changeset.cast(user, params: ["phones": ["111"]], permitted: []).castEmbed(\.phones, with: phone)
        #expect(wrong.errors == ["phones": ["is invalid"]])
    }

    @Test("Embeds nest, and a later cast or put replaces an earlier one with its errors")
    func nestingAndPuts() throws {
        let settings: [String: any Sendable] = ["theme": "dark", "address": ["street": "Main"]]
        let nested = Changeset<EmbedUser>.cast(nil, params: ["name": "Ana", "settings": settings], permitted: ["name"])
            .castEmbed(\.settings) { settings, params in
                Changeset.cast(settings, params: params, permitted: ["theme"]).castEmbed(\.address, with: address)
            }
        #expect(nested.errors == ["settings.address.city": ["can't be blank"]])

        let replaced = nested.putEmbed(\.settings, Changeset.cast(EmbedSettings(), params: ["theme": "dark"], permitted: ["theme"]))
        #expect(replaced.isValid)
        #expect(replaced.getChange(\.settings)?.theme == "dark")

        let put = replaced
            .putEmbed(\.address, EmbedAddress(street: "Side", city: "Rome"))
            .putEmbed(\.phones, [EmbedPhone(number: "9", kind: "mobile")])
        #expect(put.getChange(\.address)??.city == "Rome")
        #expect(put.getChange(\.phones)?.map(\.number) == ["9"])

        let invalidPut = replaced.putEmbed(\.phones, [phone(nil, [:])])
        #expect(invalidPut.errors == ["phones[0].number": ["can't be blank"]])
        #expect(invalidPut.putEmbed(\.phones, [EmbedPhone]()).isValid)
    }
}

extension DatabaseIntegrationTests {
@Suite("Embedded schemas in the database", .serialized)
struct EmbedDatabaseTests {
    @Test("Embeds are stored as jsonb and jsonb[], read back, and updated from JSON params")
    func storage() async throws {
        let repo = try await TestDatabase.sharedRepo()
        try await repo.executeRawSQL(#"DROP TABLE IF EXISTS "embed_users""#)
        try await repo.executeRawSQL(#"CREATE TABLE "embed_users" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "name" TEXT NOT NULL, "address" JSONB, "settings" JSONB NOT NULL DEFAULT '{}', "phones" JSONB[] NOT NULL DEFAULT '{}')"#)

        func json(_ text: String) throws -> [String: any Sendable] {
            try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: any Sendable])
        }
        let created = try json(#"{"name": "Ana", "address": {"street": "Main", "city": "Oslo"}, "settings": {"theme": "dark"}, "phones": [{"number": "111"}, {"number": "222"}]}"#)
        let inserted = try await repo.insert(
            Changeset<EmbedUser>.cast(nil, params: created, permitted: ["name"])
                .castEmbed(\.address, with: address)
                .castEmbed(\.settings) { Changeset.cast($0, params: $1, permitted: ["theme"]) }
                .castEmbed(\.phones, with: phone)
        )
        #expect(inserted.address?.city == "Oslo")
        #expect(inserted.settings.theme == "dark")
        #expect(inserted.phones.map(\.number) == ["111", "222"])

        let city = try await repo.executeRawQuery(sql: #"SELECT "address"->>'city' AS city, "phones"[1]->>'number' AS number FROM "embed_users""#, parameters: [])
        let stored = try #require(try city.first?.decode((String, String).self))
        #expect(stored.0 == "Oslo" && stored.1 == "111")

        let changed = try json(#"{"address": null, "phones": [{"id": "\#(inserted.phones[1].id.uuidString)", "number": "223"}]}"#)
        let updated = try await repo.update(
            Changeset.cast(inserted, params: changed, permitted: [])
                .castEmbed(\.address, with: address)
                .castEmbed(\.settings) { Changeset.cast($0, params: $1, permitted: ["theme"]) }
                .castEmbed(\.phones, with: phone)
        )
        let reloaded = try #require(try await repo.reload(updated))
        #expect(reloaded.address == nil)
        #expect(reloaded.phones.map(\.number) == ["223"])
        #expect(reloaded.phones.first?.id == inserted.phones[1].id)
        #expect(reloaded.settings.theme == "dark")
    }
}
}
