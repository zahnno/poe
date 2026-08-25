// Checks the file layer without launching the app: encodings, line endings,
// refusals, kind detection, and how a linked note names itself.
//
//   swiftc Sources/Poe/Model/TextFile.swift Sources/Poe/Model/Note.swift \
//          tools/file_tests/main.swift -o /tmp/poe-file-tests && /tmp/poe-file-tests
//
// (Top-level code needs the file to be called main.swift, hence the folder.)
//
import Foundation

var failures = 0
func check(_ label: String, _ passed: Bool) {
    if !passed { failures += 1 }
    print("\(passed ? "ok  " : "FAIL") \(label)")
}

let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("poe-tf-\(getpid())")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

// Latin-1: read, edit, write — the file must stay Latin-1.
let latin = dir.appendingPathComponent("latin.txt")
try! "Café Poe\n".data(using: .isoLatin1)!.write(to: latin)
let loadedLatin = try! TextFile.read(latin)
check("latin-1 decodes", loadedLatin.text == "Café Poe\n")
check("latin-1 encoding remembered", loadedLatin.link.stringEncoding == .isoLatin1)
try! TextFile.write(loadedLatin.text + "Déjà vu\n", to: loadedLatin.link)
let latinBytes = try! Data(contentsOf: latin)
check("latin-1 stays latin-1", latinBytes.contains(0xE9) && String(data: latinBytes, encoding: .utf8) == nil)

// A UTF-8 byte-order mark is a file detail, not a character.
let bom = dir.appendingPathComponent("bom.md")
try! (Data([0xEF, 0xBB, 0xBF]) + Data("# Title\n".utf8)).write(to: bom)
check("BOM stripped", try! TextFile.read(bom).text == "# Title\n")

// CRLF in, CRLF out.
let crlf = dir.appendingPathComponent("dos.md")
try! Data("one\r\ntwo\r\n".utf8).write(to: crlf)
let loadedCRLF = try! TextFile.read(crlf)
check("CRLF normalised for the editor", loadedCRLF.text == "one\ntwo\n")
try! TextFile.write(loadedCRLF.text + "three\n", to: loadedCRLF.link)
check("CRLF restored on write", String(data: try! Data(contentsOf: crlf), encoding: .utf8) == "one\r\ntwo\r\nthree\r\n")

// Binary, oversized, and directory inputs are refused with a reason.
let binary = dir.appendingPathComponent("thing.md")
try! (Data("Poe".utf8) + Data([0x00, 0xFF])).write(to: binary)
do { _ = try TextFile.read(binary); check("binary refused", false) }
catch { check("binary refused", "\(error.localizedDescription)".contains("isn’t text")) }

let huge = dir.appendingPathComponent("huge.log")
try! Data(repeating: 0x41, count: TextFile.sizeLimit + 1).write(to: huge)
do { _ = try TextFile.read(huge); check("oversized refused", false) }
catch { check("oversized refused", "\(error.localizedDescription)".contains("Poe opens text files up to")) }

do { _ = try TextFile.read(dir); check("folder refused", false) }
catch { check("folder refused", "\(error.localizedDescription)".contains("is a folder")) }

// A file that is exactly at the limit still opens.
let edge = dir.appendingPathComponent("edge.txt")
try! Data(repeating: 0x41, count: TextFile.sizeLimit).write(to: edge)
check("at the limit still opens", (try? TextFile.read(edge))?.text.count == TextFile.sizeLimit)

// Kinds.
func kind(_ name: String) -> FileKind { FileKind.of(URL(fileURLWithPath: "/x/" + name)) }
check("md is markdown", kind("notes.md") == .markdown && kind("A.MARKDOWN") == .markdown)
check("txt is text", kind("todo.txt") == .text && kind("build.log") == .text)
check("code is code", kind("App.swift") == .code && kind("Makefile") == .code && kind(".zshrc") == .code)
check("data is data", kind("a.json") == .data && kind("b.yml") == .data && kind("c.csv") == .data)
check("markdown and text preview, code does not",
      kind("a.md").rendersMarkdown && kind("a.txt").rendersMarkdown && !kind("a.swift").rendersMarkdown && !kind("a.json").rendersMarkdown)

// Display path and note titles.
let home = FileManager.default.homeDirectoryForCurrentUser.path
check("home is abbreviated", FileLink(path: home + "/Notes/x.md").displayPath == "~/Notes/x.md")
let note = Note(text: "# Heading\nbody", file: FileLink(path: "/tmp/plan.md"))
check("linked note is titled by filename", note.title == "plan.md")
check("linked note snippet keeps line one", note.snippet.hasPrefix("# Heading"))
check("plain note is titled by first line", Note(text: "# Heading\nbody").title == "Heading")
check("note badge", note.badge == "MD" && Note(text: "x").badge == "NOTE")
check("search matches the path", note.matches("plan.md") && !note.matches("nowhere"))

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
