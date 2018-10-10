//
//  StoreConfiguration.swift
//  Kineo
//
//  Created by Gregory Todd Williams on 10/9/18.
//

import Foundation
import SPARQLSyntax

public struct QuadStoreConfiguration {
    public enum StoreType {
        case memoryDatabase
        case filePageDatabase(String)
    }
    
    public enum StoreInitialization {
        case none
        case loadFiles(default: [String], named: [Term: String])
    }
    
    public var type: StoreType
    public var initialize: StoreInitialization
    public var languageAware: Bool
    
    public init(type: StoreType, initialize: StoreInitialization, languageAware: Bool) {
        self.type = type
        self.initialize = initialize
        self.languageAware = languageAware
    }
    
    public init(arguments args: inout [String]) throws {
        var type = StoreType.memoryDatabase
        var initialize = StoreInitialization.none
        var languageAware = false
        
        var defaultGraphs = [String]()
        var namedGraphs = [String]()
        
        let index = args.index(after: args.startIndex)
        LOOP: while true {
            if args.count <= 1 {
                break
            }
            let arg = args.remove(at: index)
            switch arg {
            case "-m":
                break
            case "-l":
                languageAware = true
            case "-d":
                defaultGraphs.append(args.remove(at: index))
            case "-g":
                namedGraphs.append(args.remove(at: index))
            default:
                type = .filePageDatabase(arg)
                break LOOP
            }
        }
        
        if !defaultGraphs.isEmpty || !namedGraphs.isEmpty {
            let named = Dictionary(uniqueKeysWithValues: namedGraphs.map { (Term(iri: $0), $0) })
            initialize = .loadFiles(default: defaultGraphs, named: named)
        }
        
        self.init(
            type: type,
            initialize: initialize,
            languageAware: languageAware
        )
    }

    public func withStore(_ handler: (QuadStoreProtocol) throws -> ()) throws {
        switch type {
        case .memoryDatabase:
            let store = MemoryQuadStore()
            if languageAware {
                let acceptLanguages = [("*", 1.0)] // can be changed later
                let lstore = try LanguageMemoryQuadStore(quadstore: store, acceptLanguages: acceptLanguages)
                try handler(lstore)
            } else {
                try handler(store)
            }
        case .filePageDatabase(let filename):
            let pageSize = 8192 // TODO: read from the database file
            guard let database = FilePageDatabase(filename, size: pageSize) else {
                warn("Failed to open database file '\(filename)'")
                exit(1)
            }
            if languageAware {
                let acceptLanguages = [("*", 1.0)] // can be changed later
                let store = try LanguagePageQuadStore(database: database, acceptLanguages: acceptLanguages)
                try handler(store)
            } else {
                let store = try PageQuadStore(database: database)
                try handler(store)
            }
        }
    }

    public func store() throws -> QuadStoreProtocol {
        var store: QuadStoreProtocol!
        try withStore { (s) in
            store = s
        }
        return store
    }
}

