import AppKit

@main
struct FileIconTests {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: "Resources/FileIconCatalog.json"))
        let catalog = try JSONDecoder().decode(FileIconCatalog.self, from: data)
        let cases = [
            "server.jar": "java", "SERVER.WAR": "java", "service.ear": "java",
            "report.PDF": "pdf", "报告.docx": "word", "预算.xlsx": "excel",
            "介绍.pptx": "powerpoint", "计划.xmind": "xmind", "script.py": "python",
            "index.js": "javascript", "index.ts": "typescript", "view.jsx": "react-javascript",
            "view.tsx": "react-typescript", "types.d.ts": "typescript-definition",
            "types.d.mts": "typescript-definition", "main.go": "go", "main.rs": "rust",
            "View.swift": "swift", "Dockerfile": "docker", "Dockerfile.production": "docker",
            "docker-compose.prod.yaml": "docker", "pom.xml": "maven", "package.json": "npm",
            "Cargo.toml": "cargo", "go.mod": "go-package", "tsconfig.app.json": "tsconfig",
            ".gitignore": "git", ".env.local": "environment", "logs.tar.zst": "archive",
            "notes.odt": "writer", "data.csv": "csv", ".notes.pdf": "pdf", ".pdf": "file",
            "no-extension": "file", "unknown.unknown": "file", "constructor": "file",
            "__proto__": "file", "": "file",
        ]
        for (name, expected) in cases {
            precondition(catalog.icon(for: name) == expected, "Incorrect icon for \(name)")
        }
        print("File icon filename regressions: \(cases.count) passed")

        // Optional integration gate: every named asset must render from the installed app.
        if let path = CommandLine.arguments.dropFirst().first {
            let bundle = Bundle(path: path)!
            let installedData = try Data(contentsOf: bundle.url(forResource: "FileIconCatalog", withExtension: "json")!)
            precondition(installedData == data, "Installed catalog differs from source")
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let icons = object["icons"] as! [String: Any]
            for id in icons.keys {
                guard let image = bundle.image(forResource: "FileIcon-\(id)") else {
                    fatalError("Missing compiled image: \(id)")
                }
                precondition(image.isValid, "Invalid compiled image: \(id)")
            }
            print("Installed image assets: \(icons.count) loaded successfully")
        }
    }
}
