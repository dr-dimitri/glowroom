import Testing
@testable import PicEdit

@Suite("Asset-bound raw metadata tag editor")
struct MetadataTagEditorTests {
    @Test func returnAndSubsequentTagSurviveOwnSaves() {
        var editor = MetadataTagEditorState()
        #expect(editor.edit("ErsterTag\n") == ["ErsterTag"])
        editor.synchronize(["ErsterTag"])
        #expect(editor.text == "ErsterTag\n")
        #expect(editor.edit(editor.text + "ZweiterTag\n") == ["ErsterTag", "ZweiterTag"])
        editor.synchronize(["ErsterTag", "ZweiterTag"])
        #expect(editor.text == "ErsterTag\nZweiterTag\n")
    }
    @Test func normalizationPreservesRawTextWhileAnActualExternalChangeResynchronizes() {
        var editor = MetadataTagEditorState()
        _ = editor.edit(" Licht \nlicht\n")
        editor.synchronize(["Licht"])
        #expect(editor.text == " Licht \nlicht\n")
        editor.synchronize(["Wasser"])
        #expect(editor.text == "Wasser")
        #expect(MetadataTagEditorState.parse("") == [])
    }
}
