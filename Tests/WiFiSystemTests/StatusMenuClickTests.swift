import Testing
import WiFiSystem

@Suite struct StatusMenuClickTests {
    @Test func rightClickIsMenu() { #expect(isStatusMenuClick(rightButton: true, control: false, command: false)) }
    @Test func controlLeftClickIsMenu() { #expect(isStatusMenuClick(rightButton: false, control: true, command: false)) }
    @Test func plainLeftClickIsNotMenu() { #expect(!isStatusMenuClick(rightButton: false, control: false, command: false)) }
    @Test func commandLeftClickIsNotMenu() {
        #expect(!isStatusMenuClick(rightButton: false, control: false, command: true))
        #expect(!isStatusMenuClick(rightButton: false, control: true, command: true))
    }
    @Test func rightClickWithModifiersIsMenu() { #expect(isStatusMenuClick(rightButton: true, control: true, command: true)) }
}
