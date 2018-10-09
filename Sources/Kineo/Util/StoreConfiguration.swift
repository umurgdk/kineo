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
    
    public init(arguments: [String]) throws {
        var args = arguments
        
        var type = StoreType.memoryDatabase
        var initialize = StoreInitialization.none
        var languageAware = false
        
        var defaultGraphs = [String]()
        var namedGraphs = [String]()
        
        LOOP: while true {
            let arg = args.removeFirst()
            switch arg {
            case "-m":
                break
            case "-l":
                languageAware = true
            case "-d":
                defaultGraphs.append(args.removeFirst())
            case "-g":
                namedGraphs.append(args.removeFirst())
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
}
