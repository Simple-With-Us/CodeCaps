import Foundation

// Mirror the iOS widget parse-path sources into the WidgetParseTests build.
// The iOS companion is built by xcodebuild, not SPM, so these files live
// outside the package's source roots; copying them at build time keeps one
// source of truth with zero committed duplication.
// Usage: WidgetParseMirrorTool <packageDir> <outputDir> <relative-path>...
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: WidgetParseMirrorTool <packageDir> <outputDir> <relative-path>...\n".utf8))
    exit(2)
}
let packageDir = args[0]
let outputDir = args[1]
let fm = FileManager.default
try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
for rel in args.dropFirst(2) {
    let src = packageDir + "/" + rel
    let dst = outputDir + "/" + URL(fileURLWithPath: rel).lastPathComponent
    try? fm.removeItem(atPath: dst)
    do {
        try fm.copyItem(atPath: src, toPath: dst)
    } catch {
        FileHandle.standardError.write(Data("WidgetParseMirrorTool: cannot copy \(rel): \(error)\n".utf8))
        exit(1)
    }
}
