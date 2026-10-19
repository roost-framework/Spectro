import Foundation
import Testing
@testable import Spectro

@Suite("Binary text collation")
struct BinaryCollationTests {
    @Test("Text predicates preserve qualification, bindings, and nullable semantics")
    func predicates() {
        let plain = QueryField<String>(name: "odd\"name", tableName: "items")
        let field = plain.binaryCollated()
        let value = "e\u{301}' ?"
        let conditions = [field == value, field != value, field < value, field <= value,
                          field > value, field >= value, field.in([value])]
        for condition in conditions {
            #expect(condition.sql.hasPrefix(#"("items"."odd""name" COLLATE "C")"#))
            #expect(condition.parameters.count == 1)
            #expect(condition.parameters[0].string?.utf8.elementsEqual(value.utf8) == true)
        }
        #expect(!(plain == value).sql.contains("COLLATE"))
        #expect((field.binaryCollated() == value).sql == (field == value).sql)
        let optional = QueryField<String?>(name: "text", tableName: "items").binaryCollated()
        #expect(optional.isNull().sql == #"("items"."text" COLLATE "C") IS NULL"#)
        #expect((optional == value).parameters.first?.string == value)
    }
}
