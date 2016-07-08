//
//  main.swift
//  Kineo
//
//  Created by Gregory Todd Williams on 6/24/16.
//  Copyright © 2016 Gregory Todd Williams. All rights reserved.
//

import Foundation
import Kineo

public func warn(_ items: String...) {
    for string in items {
        fputs(string, stderr)
        fputs("\n", stderr)
    }
}

func setup(database : FilePageDatabase, startTime : UInt64) throws {
    try database.update(version: startTime) { (m) in
        do {
            _ = try QuadStore.create(mediator: m)
        } catch let e {
            print("*** \(e)")
            throw DatabaseUpdateError.Rollback
        }
    }
}

func parse(database : FilePageDatabase, filename : String, startTime : UInt64) throws -> Int {
    let reader  = FileReader(filename: filename)
    let parser  = NTriplesParser(reader: reader)
#if os (OSX)
    guard let path = NSURL(fileURLWithPath: filename).absoluteString else { throw DatabaseError.DataError("Not a valid graph path: \(filename)") }
#else
    let path = NSURL(fileURLWithPath: filename).absoluteString
#endif
    let graph   = Term(value: path, type: .iri)
    
    var count   = 0
    let quads = parser.makeIterator().map { (triple) -> Quad in
        count += 1
        return Quad(subject: triple.subject, predicate: triple.predicate, object: triple.object, graph: graph)
    }
    print("\r\(quads.count) triples parsed")
    
    let version = startTime
    try database.update(version: version) { (m) in
        do {
            let store = try QuadStore.create(mediator: m)
            try store.load(quads: quads)
        } catch let e {
            print("*** \(e)")
            throw DatabaseUpdateError.Rollback
        }
    }
    return count
}

func hashJoin(joinVariables : [String], lhs : [Result], rhs : [Result], cb : @noescape (Result) -> ()) {
    var table = [Int:[Result]]()
    for result in lhs {
        let hashes = joinVariables.map { result[$0]?.hashValue ?? 0 }
        let hash = hashes.reduce(0, combine: { $0 ^ $1 })
        if let results = table[hash] {
            table[hash] = results + [result]
        } else {
            table[hash] = [result]
        }
    }
    
    for result in rhs {
        let hashes = joinVariables.map { result[$0]?.hashValue ?? 0 }
        let hash = hashes.reduce(0, combine: { $0 ^ $1 })
        if let results = table[hash] {
            for lhs in results {
                if let j = lhs.join(result) {
                    cb(j)
                }
            }
        }
    }
}


func nestedLoopJoin(_ results : [[Result]], cb : @noescape (Result) -> ()) {
    var patternResults = results
    while patternResults.count > 1 {
        let rhs = patternResults.popLast()!
        let lhs = patternResults.popLast()!
        let finalPass = patternResults.count == 0
        var joined = [Result]()
        for lresult in lhs {
            for rresult in rhs {
                if let j = lresult.join(rresult) {
                    if finalPass {
                        cb(j)
                    } else {
                        joined.append(j)
                    }
                }
            }
        }
        patternResults.append(joined)
    }
}

func query(database : FilePageDatabase, filename : String) throws -> Int {
    let reader      = FileReader(filename: filename)
    let parser      = NTriplesPatternParser(reader: reader)
    let patterns    = Array(parser.patternIterator())
    
    var count       = 0
    try database.read { (m) in
        do {
            let store       = try QuadStore(mediator: m)
            if patterns.count == 2 {
                var seen = [Set<String>]()
                for pattern in patterns {
                    var variables = Set<String>()
                    for node in [pattern.subject, pattern.predicate, pattern.object, pattern.graph] {
                        if case .variable(let name) = node {
                            variables.insert(name)
                        }
                    }
                    seen.append(variables)
                }
                
                while seen.count > 1 {
                    let first   = seen.popLast()!
                    let next    = seen.popLast()!
                    let inter   = first.intersection(next)
                    seen.append(inter)
                }
                
                let intersection = seen.popLast()!
                if intersection.count > 0 {
//                    warn("# using hash join on: \(intersection)")
                    let joinVariables = Array(intersection)
                    let lhs = Array(try store.results(matching: patterns[0]))
                    let rhs = Array(try store.results(matching: patterns[1]))
                    hashJoin(joinVariables: joinVariables, lhs: lhs, rhs: rhs) { (result) in
                        count += 1
                        print("- \(result)")
                    }
                    return
                }
            }
            
//            warn("# resorting to nested loop join")
            if patterns.count > 0 {
                var patternResults = [[Result]]()
                for pattern in patterns {
                    let results     = try store.results(matching: pattern)
                    patternResults.append(Array(results))
                }
                
                nestedLoopJoin(patternResults) { (result) in
                    count += 1
                    print("- \(result)")
                }
            }
        } catch let e {
            print("*** \(e)")
        }
    }
    return count
}

func serialize(database : FilePageDatabase) throws -> Int {
    var count = 0
    try database.read { (m) in
        do {
            let store = try QuadStore(mediator: m)
            var lastGraph : Term? = nil
            for quad in store {
                let s = quad.subject
                let p = quad.predicate
                let o = quad.object
                count += 1
                if quad.graph != lastGraph {
                    print("# GRAPH: \(quad.graph)")
                    lastGraph = quad.graph
                }
                print("\(s) \(p) \(o) .")
            }
        } catch let e {
            print("*** \(e)")
        }
    }
    return count
}

func output(database : FilePageDatabase) throws -> Int {
    try database.read { (m) in
        guard let store = try? QuadStore(mediator: m) else { return }
        for (k,v) in store.id {
            warn("\(k) -> \(v)")
        }
    }
    return try serialize(database: database)
}

func match(database : FilePageDatabase) throws -> Int {
    var count = 0
    let parser = NTriplesPatternParser(reader: "")
    try database.read { (m) in
        guard let store = try? QuadStore(mediator: m) else { return }
        guard let pattern = parser.parsePattern(line: "?s <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> ?name ?graph") else { return }
        guard let quads = try? store.quads(matching: pattern) else { return }
        for quad in quads {
            count += 1
            print("- \(quad)")
        }
    }
    return count
}

let args = Process.arguments
let pname = args[0]
var pageSize = 4096
guard args.count >= 2 else {
    print("Usage: \(pname) database.db load rdf.nt")
    print("       \(pname) database.db query query.q")
    print("       \(pname) database.db")
    print("")
    exit(1)
}
let filename = args[1]
guard let database = FilePageDatabase(filename, size: pageSize) else { print("Failed to open \(filename)"); exit(1) }
let startTime = getCurrentDateSeconds()
var count = 0

if args.count > 2 {
    try setup(database: database, startTime: startTime)
    let op = args[2]
    if op == "load" {
        for rdf in args.suffix(from: 3) {
            warn("parsing \(rdf)")
            count = try parse(database: database, filename: rdf, startTime: startTime)
        }
    } else if op == "query" {
        let qfile = args[3]
        count = try query(database: database, filename: qfile)
    } else if op == "index" {
        let index = args[3]
        try database.update(version: startTime) { (m) in
            do {
                let store = try QuadStore.create(mediator: m)
                try store.addQuadIndex(index)
            } catch let e {
                print("*** \(e)")
                throw DatabaseUpdateError.Rollback
            }
            print("Added index: \(index)")
        }
    } else {
        warn("Unrecognized operation: '\(op)'")
        exit(1)
    }
} else {
//    count = try output(database: database)
    count = try serialize(database: database)
}

let endTime = getCurrentDateSeconds()
let elapsed = endTime - startTime
let tps = Double(count) / Double(elapsed)
warn("elapsed time: \(elapsed)s (\(tps)/s)")


