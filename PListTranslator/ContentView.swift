//
//  ContentView.swift
//  PListTranslator
//
//  Created by Steve Wainwright on 16/07/2026.
//

import SwiftUI
import Translation
import UniformTypeIdentifiers

enum PlistPathComponent: Hashable {
    case key(String)
    case index(Int)
}

struct TranslationItem: Identifiable {
    let id = UUID()
    let key: String
    let path: [PlistPathComponent]   // exact location in the plist tree
    let original: String
    var translated: String?
}


struct ContentView: View {

    @State private var showImporter = false
    @State private var plistURL: URL?
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
        plistURL?.lastPathComponent ?? "No file loaded"
    }

    var body: some View {
        VStack {
            HStack {
                Picker("Target language", selection: $locale) {
                    ForEach(languages) { language in
                        Text(language.name)
                            .tag(language.id)
                    }
                }
                
                Spacer()
                
                TextField("Keys to translate (comma-separated)", text: $targetKeysInput)
                    .onChange(of: targetKeysInput) { _, newValue in
                        targetKeys = Set(
                            targetKeysInput
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                        )
                    }
                
                Text(currentFileName)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                
                Spacer()
                
                Button("Open plist") {
                    showImporter = true
                }
                
                
            }
            .padding()
            HStack {
                
                Button("Translate All") {
                    startBatchTranslation()
                }
                .disabled(items.isEmpty)

                if plistURL != nil {
                    Button("Save translated plist") {
                        savePlist()
                    }
                    .disabled(items.isEmpty)
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
            allowedContentTypes: [
                UTType.propertyList
            ]
        ) { result in
            switch result {
                case .success(let url):
                    loadPlist(url)

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

        plistURL = url
        
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
                    items.append(TranslationItem(key: key, path: path + [.key(key)], original: title))
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
        if let plistURL {
            if plistURL.startAccessingSecurityScopedResource() {
                defer {
                    plistURL.stopAccessingSecurityScopedResource()
                }
                
                do {
                    let data = try Data(contentsOf: plistURL)
                    var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                    replaceTitles(&plist)
                    //            let outputURL = plistURL.deletingPathExtension().appendingPathExtension("translated.plist")
                    let outputData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                    
                    plistURL.stopAccessingSecurityScopedResource() // done reading, before showing panel
                    
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = plistURL.deletingPathExtension().appendingPathExtension("translated.plist") .lastPathComponent
                    panel.directoryURL = plistURL.deletingLastPathComponent()
                    panel.allowedContentTypes = [.propertyList]
                    
                    if panel.runModal() == .OK, let outputURL = panel.url {
                        try outputData.write(to: outputURL)
                        print("Saved:")
                        print(outputURL.path)
                    }
                    //            try outputData.write(to: outputURL)
                    //            print("Saved:")
                    //            print(outputURL.path)
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
            setValue(item.translated ?? item.original, at: item.path, in: &plist)

            // English reference at key_en, same location
            guard let lastComponent = item.path.last, case .key(let originalKey) = lastComponent else { continue }
            let referencePath = Array(item.path.dropLast()) + [.key(originalKey + "_en")]
            setValue(item.original, at: referencePath, in: &plist)
        }
    }
    
}

#Preview {
    ContentView()
}

