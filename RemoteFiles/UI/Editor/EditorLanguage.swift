import Foundation
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
    static let editableFileNames: Set<String> = [
        ".bash_profile", ".bashrc", ".curlrc", ".editorconfig", ".env",
        ".gitattributes", ".gitconfig", ".gitignore", ".npmrc", ".profile",
        ".vimrc", ".wgetrc", ".yarnrc", ".zlogin", ".zlogout", ".zprofile", ".zshrc",
        "Brewfile", "Dockerfile", "Gemfile", "Makefile", "Podfile", "Rakefile"
    ]

    static let editableExtensions: Set<String> = [
        "txt", "log", "conf", "cfg", "ini", "md",
        "swift", "c", "h", "cpp", "cc", "cxx", "hpp",
        "py", "js", "mjs", "cjs", "ts", "tsx", "jsx",
        "html", "htm", "css", "json", "yaml", "yml", "toml",
        "sh", "bash", "zsh", "php", "java", "go", "rs", "sql"
    ]

    static func isEditable(fileName: String) -> Bool {
        if editableFileNames.contains(fileName) { return true }
        if fileName.hasPrefix("."), fileName != ".DS_Store" {
            return true
        }
        return editableExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    static func language(fileName: String) -> TreeSitterLanguage? {
        if [
            ".bash_profile", ".bashrc", ".profile", ".zlogin", ".zlogout", ".zprofile", ".zshrc"
        ].contains(fileName) {
            return .bash
        }
        switch (fileName as NSString).pathExtension.lowercased() {
        case "swift": return .swift
        case "c", "h": return .c
        case "cpp", "cc", "cxx", "hpp": return .cpp
        case "css": return .css
        case "go": return .go
        case "html", "htm": return .html
        case "java": return .java
        case "js", "mjs", "cjs", "jsx": return .javaScript
        case "json": return .json
        case "md": return .markdown
        case "php": return .php
        case "py": return .python
        case "rs": return .rust
        case "sql": return .sql
        case "toml": return .toml
        case "ts": return .typeScript
        case "tsx": return .tsx
        case "yaml", "yml": return .yaml
        case "sh", "bash", "zsh": return .bash
        default: return nil
        }
    }
}

