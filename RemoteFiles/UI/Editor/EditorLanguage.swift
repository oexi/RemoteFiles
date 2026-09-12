import Runestone
import TreeSitterBashRunestone
import TreeSitterCRunestone
import TreeSitterCPPRunestone
import TreeSitterCSSRunestone
import TreeSitterGoRunestone
import TreeSitterHTMLRunestone
import TreeSitterJavaRunestone
import TreeSitterJavaScriptRunestone
import TreeSitterJSONRunestone
import TreeSitterMarkdownRunestone
import TreeSitterPHPRunestone
import TreeSitterPythonRunestone
import TreeSitterRustRunestone
import TreeSitterSQLRunestone
import TreeSitterSwiftRunestone
import TreeSitterTOMLRunestone
import TreeSitterTSXRunestone
import TreeSitterTypeScriptRunestone
import TreeSitterYAMLRunestone

enum EditorLanguage {
    static let editableExtensions: Set<String> = [
        "txt", "log", "conf", "cfg", "ini", "md",
        "swift", "c", "h", "cpp", "cc", "cxx", "hpp",
        "py", "js", "mjs", "cjs", "ts", "tsx", "jsx",
        "html", "htm", "css", "json", "yaml", "yml", "toml",
        "sh", "bash", "zsh", "php", "java", "go", "rs", "sql"
    ]

    static func isEditable(fileName: String) -> Bool {
        editableExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    static func language(fileName: String) -> TreeSitterLanguage? {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "swift": .swift
        case "c", "h": .c
        case "cpp", "cc", "cxx", "hpp": .cpp
        case "css": .css
        case "go": .go
        case "html", "htm": .html
        case "java": .java
        case "js", "mjs", "cjs", "jsx": .javaScript
        case "json": .json
        case "md": .markdown
        case "php": .php
        case "py": .python
        case "rs": .rust
        case "sql": .sql
        case "toml": .toml
        case "ts": .typeScript
        case "tsx": .tsx
        case "yaml", "yml": .yaml
        case "sh", "bash", "zsh": .bash
        default: nil
        }
    }
}

