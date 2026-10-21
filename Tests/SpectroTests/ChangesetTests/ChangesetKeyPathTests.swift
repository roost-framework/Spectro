import Foundation
import Testing
@testable import Spectro

enum KeyPathRole: String, DatabaseValue, Codable {
    case member, admin
}

@Schema("key_path_users")
struct KeyPathUser {
    @ID var id: UUID
    @Column var name: String
    @Column var nickname: String?
    @Column var age: Int
    @Column var role: KeyPathRole = .member
    @Column var isActive: Bool
}

@Suite("Changeset key paths")
struct ChangesetKeyPathTests {
    @Test("Key paths cast, read, change, and validate fields with their types")
    func keyPaths() {
        let params: [String: any Sendable] = ["name": "a", "nickname": "nick", "age": "17", "role": "admin", "isActive": true]
        let changeset = Changeset<KeyPathUser>.cast(nil, params: params, permitting: \.name, \.nickname, \.age, \.role)
            .validateLength(\.name, min: 2)
            .validateLength(\.nickname, max: 3)
            .validateFormat(\.name, pattern: "^[A-Z]", message: "must be capitalized")
            .validateInclusion(\.role, in: [.member])
            .validateExclusion(\.age, in: [17])
            .validateNumber(\.age, greaterThanOrEqualTo: 18)
            .validateCustom(\.age) { $0 % 2 == 0 ? nil : "must be even" }

        #expect(changeset.getChange(\.isActive) == nil)
        #expect(changeset.getChange(\.age) == 17)
        #expect(changeset.getField(\.role) == .admin)
        #expect(changeset.errors(on: \.name) == ["should be at least 2 character(s)", "must be capitalized"])
        #expect(changeset.errors(on: \.nickname) == ["should be at most 3 character(s)"])
        #expect(changeset.errors(on: \.role) == ["is invalid"])
        #expect(changeset.errors(on: \.age) == ["is reserved", "must be greater than or equal to 18.0", "must be even"])

        let changed = changeset.putChange(\.isActive, true).deleteChange(\.nickname).addError(\.isActive, message: "is locked")
        #expect(changed.getChange(\.isActive) == true)
        #expect(changed.getChange(\.nickname) == nil)
        #expect(changed.errors(on: \.isActive) == ["is locked"])
        #expect(changed.validateRequired(\.name, \.nickname).errors(on: \.nickname).last == "can't be blank")
        #expect(changed.optimisticLock(\.age).lockField == "age")

        let nilNickname = Changeset<KeyPathUser>.cast(nil, params: [:], permitting: \.nickname)
            .validateInclusion(\.nickname, in: ["x"])
            .validateCustom(\.nickname) { _ in "never runs for nil" }
        #expect(nilNickname.isValid)
    }
}
