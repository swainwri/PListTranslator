//
//  ContentView.swift
//  PListTranslator
//
//  Created by Steve Wainwright on 16/07/2026.
//

import SwiftUI
import Translation
import UniformTypeIdentifiers

enum LocalizationFileType {
    case plist
    case strings
}

enum PlistPathComponent: Hashable {
    case key(String)
    case index(Int)
}

struct TranslationItem: Identifiable {
    let id = UUID()
    let key: String
    let path: [PlistPathComponent]?   // exact location in the plist tree
    let comment: String?     // nil for plist entries that don't have one
    let original: String
    var translated: String?
}

enum ImportFormat: String, CaseIterable, Identifiable {
    case plist = "Plist"
    case strings = "Strings"
    var id: String { rawValue }
}


struct ContentView: View {
    
    @State private var format: ImportFormat = .plist

    @State private var showImporter = false
    @State private var plistStringsURL: URL?
    @State private var locale = "th"

    @State private var items: [TranslationItem] = []
    @State private var configuration: TranslationSession.Configuration?
    
    // User-configurable set of keys to translate
    @State private var targetKeys: Set<String> = ["itemTitle"]
    @State private var targetKeysInput: String = "itemTitle"

    @State private var selectedText = ""
    @State private var showTranslation = false
    @State private var selectedIndex: Int?

    struct TranslationLanguage: Identifiable {
        let id: String
        let name: String
    }

    let languages = [
        TranslationLanguage(id: "th", name: "Thai"),
        TranslationLanguage(id: "fr", name: "French"),
        TranslationLanguage(id: "it", name: "Italian"),
        TranslationLanguage(id: "de", name: "German"),
        TranslationLanguage(id: "es", name: "Spanish"),
        TranslationLanguage(id: "ja", name: "Japanese")
    ]
    
    var currentFileName: String {
        plistStringsURL?.lastPathComponent ?? "No file loaded"
    }

    var body: some View {
        VStack {
            HStack {
                Picker("Import format", selection: $format) {
                    ForEach(ImportFormat.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: format) { _, _ in
                    plistStringsURL = nil
                }
                
                Spacer()
                
                Picker("Target language", selection: $locale) {
                    ForEach(languages) { language in
                        Text(language.name).tag(language.id)
                    }
                }
            }
            .padding()
            
            HStack {
                if format == .plist {
                    TextField("Keys to translate (comma-separated)", text: $targetKeysInput)
                        .onChange(of: targetKeysInput) { _, newValue in
                            targetKeys = Set(
                                targetKeysInput
                                    .split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty }
                            )
                        }
                }
                else {
                    // .strings needs no extra field — key/value/comment are structural, not user-specified
                    Spacer()
                }
            }.padding()
            HStack {
                Text(currentFileName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                
                Spacer()
                
                if format == .plist {
                    Button("Open plist") {
                        showImporter = true
                    }
                }
                else {
                    Button("Open strings") {
                        showImporter = true
                    }
                }
                
            }
            .padding()
            HStack {
                
                Button("Translate All") {
                    startBatchTranslation()
                }
                .disabled(items.isEmpty)

                if plistStringsURL != nil {
                    if format == .plist {
                        Button("Save translated plist") {
                            savePlist()
                        }
                        .disabled(items.isEmpty)
                    }
                    else if format == .strings {
                        Button("Save translated Strings") {
                            saveStrings()
                        }
                        .disabled(items.isEmpty)
                    }
                }
            }
            .padding()

            List {
                ForEach(items.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(items[index].original)
                            .font(.headline)
                        if let translated = items[index].translated {
                            Text(translated)
                                .foregroundStyle(.green)
                        }

                        Button("Translate") {
                            selectedIndex = index
                            selectedText = items[index].original
                            showTranslation = true
                        }

                    }
                    .padding(.vertical, 8)
                }
            }

        }
        .frame(minWidth: 600, minHeight: 500)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: format == .plist ? [.propertyList] : [UTType(filenameExtension: "strings") ?? .plainText]
        ) { result in
            switch result {
                case .success(let url):
                    switch format {
                        case .plist:
                            loadPlist(url)
                        case .strings:
                            loadStrings(url)
                    }

                case .failure(let error):
                    print(error)
                }
        }

        .translationPresentation(
            isPresented: $showTranslation,
            text: selectedText
        ) { translatedText in
            if let index = selectedIndex {
                items[index].translated = translatedText
            }
        }
        
        // Attach once, anywhere in the hierarchy that's always present
        .translationTask(configuration) { session in
            await performTranslation(session: session)
        }
        .id(configuration == nil ? "empty" : "\(locale)-\(items.count)")
    }
    
    // MARK: - Batch Translation
    
    func startBatchTranslation() {
        // Setting this triggers the .translationTask above to run.
        // If the language pack isn't installed, the system shows
        // its own download prompt automatically.
        print("startBatchTranslation called, items count: \(items.count)")
        configuration?.invalidate()
        configuration = nil

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            configuration = TranslationSession.Configuration(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: locale))
            print("configuration set to: \(String(describing: configuration))")
        }
    }
    
    func performTranslation(session: TranslationSession) async {
        let pending = items.enumerated().filter { $0.element.translated == nil }
        print("performTranslation called, pending count: \(pending.count)")
        if !pending.isEmpty {
            let requests = pending.map {
                TranslationSession.Request(sourceText: $0.element.original)
            }
            
            do {
                let responses = try await session.translations(from: requests)
                print("received \(responses.count) responses")
                for (offset, response) in responses.enumerated() {
                    let originalIndex = pending[offset].offset
                    items[originalIndex].translated = response.targetText
                }
            }
            catch {
                print("translation error: \(error)")
            }
        }
    }
    
    func ensureLanguageInstalled() async -> Bool {
        let availability = LanguageAvailability()
        let status = await availability.status(
            from: Locale.Language(identifier: "en"),
            to: Locale.Language(identifier: locale)
        )
        switch status {
            case .installed:
                return true
            case .supported:
                // Not installed yet — the .translationTask flow below will prompt for it
                return false
            case .unsupported:
                return false
            @unknown default:
                return false
        }
    }


    // MARK: - Load plist

    func loadPlist(_ url: URL) {

        plistStringsURL = url
        
        let accessGranted = url.startAccessingSecurityScopedResource()

        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)

            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            items.removeAll()
            extractTitles(plist)
        }
        catch {
            print(error)
        }
    }
    
    func extractTitles(_ object: Any, path: [PlistPathComponent] = []) {
        if let dictionary = object as? [String: Any] {
            for key in targetKeys {
                if let title = dictionary[key] as? String {
                    items.append(TranslationItem(key: key, path: path + [.key(key)], comment: nil, original: title))
                }
            }
            for (key, value) in dictionary {
                extractTitles(value, path: path + [.key(key)])
            }
        }
        if let array = object as? [Any] {
            for (index, element) in array.enumerated() {
                extractTitles(element, path: path + [.index(index)])
            }
        }
    }

    // MARK: - Save plist

    func savePlist() {
        if let plistStringsURL {
            if plistStringsURL.startAccessingSecurityScopedResource() {
                defer {
                    plistStringsURL.stopAccessingSecurityScopedResource()
                }
                
                do {
                    let data = try Data(contentsOf: plistStringsURL)
                    var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                    replaceTitles(&plist)
                    //            let outputURL = plistURL.deletingPathExtension().appendingPathExtension("translated.plist")
                    let outputData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                    
                    plistStringsURL.stopAccessingSecurityScopedResource() // done reading, before showing panel
                    
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = plistStringsURL.deletingPathExtension().appendingPathExtension("translated.plist") .lastPathComponent
                    panel.directoryURL = plistStringsURL.deletingLastPathComponent()
                    panel.allowedContentTypes = [.propertyList]
                    
                    if panel.runModal() == .OK, let outputURL = panel.url {
                        try outputData.write(to: outputURL)
                        print("Saved:")
                        print(outputURL.path)
                    }
                }
                catch {
                    print(error)
                }
            }
            else {
                print("Cannot access file")
            }
        }
    }
    
    func setValue(_ value: Any, at path: [PlistPathComponent], in object: inout Any) {
        guard let first = path.first else { return }
        let rest = Array(path.dropFirst())

        switch first {
        case .key(let k):
            var dict = object as? [String: Any] ?? [:]
            if rest.isEmpty {
                dict[k] = value
            } else {
                var child = dict[k] ?? [String: Any]()
                setValue(value, at: rest, in: &child)
                dict[k] = child
            }
            object = dict

        case .index(let i):
            var array = object as? [Any] ?? []
            guard i < array.count else { return }
            if rest.isEmpty {
                array[i] = value
            } else {
                var child = array[i]
                setValue(value, at: rest, in: &child)
                array[i] = child
            }
            object = array
        }
    }

    func replaceTitles(_ plist: inout Any) {
        for item in items {
            // translated (or original as fallback) at the existing key
            if let path = item.path {
                setValue(item.translated ?? item.original, at: path, in: &plist)
                
                // English reference at key_en, same location
                guard let lastComponent = path.last, case .key(let originalKey) = lastComponent else { continue }
                let referencePath = Array(path.dropLast()) + [.key(originalKey + "_en")]
                setValue(item.original, at: referencePath, in: &plist)
            }
        }
    }
    
    // MARK: - Parse Strings
    
    struct StringsEntry {
        let key: String
        let value: String
        let comment: String?
    }
    
    func loadStrings(_ url: URL) {
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let entries = parseStringsFile(at: url.path)
            
        items = entries.map { entry in
            TranslationItem(key: entry.key,path: nil, comment: entry.comment, original: entry.value)
        }
        plistStringsURL = url 
    }

    private func parseStringsFile(at path: String) -> [StringsEntry] {
        
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }

        // Matches: optional /* comment */ then "key" = "value";
        let pattern = #"(?:/\*\s*(.*?)\s*\*/\s*)?"([^"]+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }

        let nsRange = NSRange(content.startIndex..., in: content)
        let matches = regex.matches(in: content, range: nsRange)

        return matches.compactMap { match in
            guard
                let keyRange = Range(match.range(at: 2), in: content),
                let valueRange = Range(match.range(at: 3), in: content)
            else { return nil }

            let key = String(content[keyRange])
            let value = String(content[valueRange])
            let comment: String? = {
                guard match.range(at: 1).location != NSNotFound,
                      let commentRange = Range(match.range(at: 1), in: content) else { return nil }
                return String(content[commentRange])
            }()

            return StringsEntry(key: key, value: value, comment: comment)
        }
    }
    
    // MARK: - Save Strings
    
    func saveStrings() {
        if let plistStringsURL {
            if plistStringsURL.startAccessingSecurityScopedResource() {
                defer {
                    plistStringsURL.stopAccessingSecurityScopedResource()
                }
                
                do {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = plistStringsURL.deletingPathExtension().appendingPathExtension("translated.strings") .lastPathComponent
                    panel.directoryURL = plistStringsURL.deletingLastPathComponent()
                    panel.allowedContentTypes = [UTType(filenameExtension: "strings") ?? .plainText]
                    
                    if panel.runModal() == .OK, let outputURL = panel.url {
                        try writeStringsFile(items: items, to: outputURL.path)
                        print("Saved:")
                        print(outputURL.path)
                    }
                }
                catch {
                    print(error)
                }
            }
            else {
                print("Cannot access file")
            }
        }
    }
    
    func writeStringsFile(items: [TranslationItem], to path: String) throws {
        var output = ""
        for item in items {
            if let comment = item.comment {
                output += "/* \(comment) */\n"
            }
            let value = (item.translated ?? item.original).replacingOccurrences(of: "\"", with: "\\\"")
            output += "\"\(item.key)\" = \"\(value)\";\n\n"
        }
        try output.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

#Preview {
    ContentView()
}

