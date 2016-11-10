//
//  Query.swift
//  Kineo
//
//  Created by Gregory Todd Williams on 7/8/16.
//  Copyright © 2016 Gregory Todd Williams. All rights reserved.
//

import Foundation

open class SimpleQueryEvaluator<Q : QuadStoreProtocol> {
    var store : Q
    var defaultGraph : Term
    var freshVarNumber : Int
    public init(store : Q, defaultGraph : Term) {
        self.store = store
        self.defaultGraph = defaultGraph
        self.freshVarNumber = 1
    }
    
    private func freshVariable() -> Node {
        let n = freshVarNumber
        freshVarNumber += 1
        return .variable(".v\(n)", binding: true)
    }
    func evaluateUnion(_ patterns : [Algebra], activeGraph : Term) throws -> AnyIterator<TermResult> {
        var iters = try patterns.map { try self.evaluate(algebra: $0, activeGraph: activeGraph) }
        return AnyIterator {
            repeat {
                if iters.count == 0 {
                    return nil
                }
                let i = iters[0]
                guard let item = i.next() else { iters.remove(at: 0); continue }
                return item
            } while true
        }
    }
    
    func evaluateJoin(lhs lhsAlgebra: Algebra, rhs rhsAlgebra: Algebra, left : Bool, activeGraph : Term) throws -> AnyIterator<TermResult> {
        var seen = [Set<String>]()
        for pattern in [lhsAlgebra, rhsAlgebra] {
            seen.append(pattern.inscope)
        }
        
        while seen.count > 1 {
            let first   = seen.popLast()!
            let next    = seen.popLast()!
            let inter   = first.intersection(next)
            seen.append(inter)
        }
        
        let intersection = seen.popLast()!
        if intersection.count > 0 {
//            warn("# using hash join on: \(intersection)")
//            warn("### \(lhsAlgebra)")
//            warn("### \(rhsAlgebra)")
            let joinVariables = Array(intersection)
            let lhs = try self.evaluate(algebra: lhsAlgebra, activeGraph: activeGraph)
            let rhs = try self.evaluate(algebra: rhsAlgebra, activeGraph: activeGraph)
            return pipelinedHashJoin(joinVariables: joinVariables, lhs: lhs, rhs: rhs, left: left)
        }
        
        var patternResults = [[TermResult]]()
        for pattern in [lhsAlgebra, rhsAlgebra] {
            let results     = try self.evaluate(algebra: pattern, activeGraph: activeGraph)
            patternResults.append(Array(results))
        }
        
        var results = [TermResult]()
        nestedLoopJoin(patternResults, left: left) { (result) in
            results.append(result)
        }
        return AnyIterator(results.makeIterator())
    }
    
    func evaluateLeftJoin(lhs : Algebra, rhs : Algebra, expression expr: Expression, activeGraph : Term) throws -> AnyIterator<TermResult> {
        let i = try evaluateJoin(lhs: lhs, rhs: rhs, left: true, activeGraph: activeGraph)
        return AnyIterator {
            repeat {
                guard let result = i.next() else { return nil }
                if let term = try? expr.evaluate(result: result) {
                    if case .some(true) = try? term.ebv() {
                        return result
                    }
                }
            } while true
        }
    }
    
    func evaluateCount<S : Sequence>(results : S, expression keyExpr : Expression, distinct : Bool) -> Term? where S.Iterator.Element == TermResult {
        if distinct {
            let terms = results.map { try? keyExpr.evaluate(result: $0) }.flatMap { $0 }
            let unique = Set(terms)
            return Term(integer: unique.count)
        } else {
            var count = 0
            for result in results {
                if let _ = try? keyExpr.evaluate(result: result) {
                    count += 1
                }
            }
            return Term(integer: count)
        }
    }
    
    func evaluateCountAll<S : Sequence>(results : S) -> Term? where S.Iterator.Element == TermResult {
        var count = 0
        for _ in results {
            count += 1
        }
        return Term(integer: count)
    }
    
    func evaluateAvg<S : Sequence>(results : S, expression keyExpr : Expression, distinct : Bool) -> Term? where S.Iterator.Element == TermResult {
        var doubleSum : Double = 0.0
        let integer = TermType.datatype("http://www.w3.org/2001/XMLSchema#integer")
        var resultingType : TermType? = integer
        var count = 0
        
        var terms = results.map { try? keyExpr.evaluate(result: $0) }.flatMap { $0 }
        if distinct {
            terms = Array(Set(terms))
        }
        
        for term in terms {
            if term.isNumeric {
                count += 1
                resultingType = resultingType?.resultType(op: "+", operandType: term.type)
                doubleSum += term.numericValue
            }
        }
        
        doubleSum /= Double(count)
        resultingType = resultingType?.resultType(op: "/", operandType: integer)
        if let type = resultingType {
            if let n = Term(numeric: doubleSum, type: type) {
                return n
            } else {
                // cannot create a numeric term with this combination of value and type
            }
        } else {
            warn("*** Cannot determine resulting numeric datatype for AVG operation")
        }
        return nil
    }

    func evaluateSum<S : Sequence>(results : S, expression keyExpr : Expression, distinct : Bool) -> Term? where S.Iterator.Element == TermResult {
        var runningSum : Numeric = .integer(0)
        if distinct {
            let terms = results.map { try? keyExpr.evaluate(result: $0) }.flatMap { $0 }.sorted()
            let unique = Set(terms)
            if unique.count == 0 {
                return nil
            }
            for term in unique {
                if let numeric = term.numeric {
                    runningSum = runningSum + numeric
                }
            }
            return runningSum.term
        } else {
            var count = 0
            for result in results {
                if let term = try? keyExpr.evaluate(result: result) {
                    count += 1
                    if let numeric = term.numeric {
                        runningSum = runningSum + numeric
                    }
                }
            }
            if count == 0 {
                return nil
            }
            return runningSum.term
        }
    }
    
    func evaluateGroupConcat<S : Sequence>(results : S, expression keyExpr : Expression, separator: String, distinct : Bool) -> Term? where S.Iterator.Element == TermResult {
        var terms = results.map { try? keyExpr.evaluate(result: $0) }.flatMap { $0 }
        if distinct {
            terms = Array(Set(terms))
        }
        
        if terms.count == 0 {
            return nil
        }
        
        let values = terms.map { $0.value }
        let type = terms.first!.type
        let c = values.joined(separator: separator)
        return Term(value: c, type: type)
    }
    
    func evaluateSinglePipelinedAggregation(algebra child: Algebra, groups: [Expression], aggregation agg: Aggregation, variable name: String, activeGraph : Term) throws -> AnyIterator<TermResult> {
        let i = try self.evaluate(algebra: child, activeGraph: activeGraph)
        var numericGroups = [String:Numeric]()
        var termGroups = [String:Term]()
        var groupCount = [String:Int]()
        var groupBindings = [String:[String:Term]]()
        for result in i {
            let group = groups.map { (expr) -> Term? in return try? expr.evaluate(result: result) }
            let groupKey = "\(group)"
            if let value = termGroups[groupKey] {
                switch agg {
                case .min(let keyExpr):
                    if let term = try? keyExpr.evaluate(result: result) {
                        termGroups[groupKey] = min(value, term)
                    }
                case .max(let keyExpr):
                    if let term = try? keyExpr.evaluate(result: result) {
                        termGroups[groupKey] = max(value, term)
                    }
                case .sample(_):
                    break
                case .groupConcat(let keyExpr, let sep, false):
                    guard case .datatype(_) = value.type else { fatalError("Unexpected term in generating GROUP_CONCAT value") }
                    let string = value.value
                    if let term = try? keyExpr.evaluate(result: result) {
                        let updated = string + sep + term.value
                        termGroups[groupKey] = Term(value: updated, type: value.type)
                    }
                default:
                    fatalError("unexpected pipelined evaluation for \(agg)")
                }
            } else if let value = numericGroups[groupKey] {
                switch agg {
                case .countAll:
                    numericGroups[groupKey] = value + .integer(1)
                case .avg(let keyExpr, false):
                    if let term = try? keyExpr.evaluate(result: result), let c = groupCount[groupKey] {
                        if let n = term.numeric {
                            numericGroups[groupKey] = value + n
                            groupCount[groupKey] = c + 1
                        }
                    }
                case .count(let keyExpr, false):
                    if let _ = try? keyExpr.evaluate(result: result) {
                        numericGroups[groupKey] = value + .integer(1)
                    }
                case .sum(let keyExpr, false):
                    if let term = try? keyExpr.evaluate(result: result) {
                        if let n = term.numeric {
                            numericGroups[groupKey] = value + n
                        }
                    }
                default:
                    fatalError("unexpected pipelined evaluation for \(agg)")
                }
            } else {
                switch agg {
                case .countAll:
                    numericGroups[groupKey] = .integer(1)
                case .avg(let keyExpr, false):
                    if let term = try? keyExpr.evaluate(result: result) {
                        if term.isNumeric {
                            numericGroups[groupKey] = term.numeric
                            groupCount[groupKey] = 1
                        }
                    }
                case .count(let keyExpr, false):
                    if let _ = try? keyExpr.evaluate(result: result) {
                        numericGroups[groupKey] = .integer(1)
                    }
                case .sum(let keyExpr, false):
                    if let term = try? keyExpr.evaluate(result: result) {
                        if term.isNumeric {
                            numericGroups[groupKey] = term.numeric
                        }
                    }
                case .min(let keyExpr):
                    if let term = try? keyExpr.evaluate(result: result) {
                        termGroups[groupKey] = term
                    }
                case .max(let keyExpr):
                    if let term = try? keyExpr.evaluate(result: result) {
                        termGroups[groupKey] = term
                    }
                case .sample(let keyExpr):
                    if let term = try? keyExpr.evaluate(result: result) {
                        termGroups[groupKey] = term
                    }
                case .groupConcat(let keyExpr, _, false):
                    if let term = try? keyExpr.evaluate(result: result) {
                        switch term.type {
                        case .datatype(_):
                            termGroups[groupKey] = term
                        default:
                            termGroups[groupKey] = Term(value: term.value, type: .datatype("http://www.w3.org/2001/XMLSchema#string"))
                        }
                    }
                default:
                    fatalError("unexpected pipelined evaluation for \(agg)")
                }
                var bindings = [String:Term]()
                for (g, term) in zip(groups, group) {
                    if case .node(.variable(let name, true)) = g {
                        if let term = term {
                            bindings[name] = term
                        }
                    }
                }
                groupBindings[groupKey] = bindings
            }
        }
        // TODO: handle special case where there are no groups (no input rows led to no groups being created);
        //       in this case, counts should return a single result with { $name=0 }
        var a = numericGroups.makeIterator()
        return AnyIterator {
            guard let pair = a.next() else { return nil }
            let (groupKey, v) = pair
            var value = v
            if case .avg(_) = agg {
                guard let count = groupCount[groupKey] else { fatalError("Failed to find expected group data during aggregation") }
                value = v / Numeric.double(Double(count))
            }
            
            guard var bindings = groupBindings[groupKey] else { fatalError("Unexpected missing aggregation group template") }
            bindings[name] = value.term
            return TermResult(bindings: bindings)
        }
    }
    
    func evaluateWindow(algebra child: Algebra, groups: [Expression], functions: [(WindowFunction, [Algebra.SortComparator], String)], activeGraph: Term) throws -> AnyIterator<TermResult> {
        let i = try self.evaluate(algebra: child, activeGraph: activeGraph)
        var groupBuckets = [String:[TermResult]]()
        for result in i {
            let group = groups.map { (expr) -> Term? in return try? expr.evaluate(result: result) }
            let groupKey = "\(group)"
            if groupBuckets[groupKey] == nil {
                groupBuckets[groupKey] = [result]
                var bindings = [String:Term]()
                for (g, term) in zip(groups, group) {
                    if case .node(.variable(let name, true)) = g {
                        if let term = term {
                            bindings[name] = term
                        }
                    }
                }
            } else {
                groupBuckets[groupKey]?.append(result)
            }
        }
        
        var groups = Array(groupBuckets.values)
        for (f, comparators, name) in functions {
            let results = groups.map { (results) -> [TermResult] in
                var newResults = [TermResult]()
                for (n, result) in _sortResults(results, comparators: comparators).enumerated() {
                    var r = result
                    switch f {
                    case .rowNumber:
                        r.extend(variable: name, value: Term(integer: n))
                    case .rank:
                        // TODO: assign the same rank to rows with equal comparator values
                        r.extend(variable: name, value: Term(integer: n))
                    }
                    newResults.append(r)
                }
                return newResults
            }
            groups = results
        }
        
        let results = groups.flatMap { $0 }
        return AnyIterator(results.makeIterator())
    }

    private func alp(term : Term, path : PropertyPath, graph: Node) throws -> AnyIterator<Term> {
        var v = Set<Term>()
        try alp(term: term, path: path, seen: &v, graph: graph)
        return AnyIterator(v.makeIterator())
    }
    
    private func alp(term x : Term, path : PropertyPath, seen v : inout Set<Term>, graph: Node) throws {
        guard !v.contains(x) else { return }
        v.insert(x)
        let pvar = freshVariable()
        for result in try evaluatePath(subject: .bound(x), object: pvar, graph: graph, path: path) {
            if let n = result[pvar] {
                try alp(term: n, path: path, seen: &v, graph: graph)
            }
        }
    }
    
    func evaluatePath(subject: Node, object: Node, graph: Node, path: PropertyPath) throws -> AnyIterator<TermResult> {
        switch path {
        case .link(let predicate):
            let quad = QuadPattern(subject: subject, predicate: .bound(predicate), object: object, graph: graph)
            return try store.results(matching: quad)
        case .inv(let ipath):
            return try evaluatePath(subject: object, object: subject, graph: graph, path: ipath)
        case .nps(let iris):
            return try evaluateNPS(subject: subject, object: object, graph: graph, not: iris)
        case .alt(let lhs, let rhs):
            let i = try evaluatePath(subject: subject, object: object, graph: graph, path: lhs)
            let j = try evaluatePath(subject: subject, object: object, graph: graph, path: rhs)
            var iters = [i,j]
            return AnyIterator {
                repeat {
                    if iters.count == 0 {
                        return nil
                    }
                    let i = iters[0]
                    guard let item = i.next() else { iters.remove(at: 0); continue }
                    return item
                } while true
            }
            
        case .seq(let lhs, let rhs):
            let jvar = freshVariable()
            guard case .variable(let jvarname, _) = jvar else { fatalError(
                ) }
            let i = try evaluatePath(subject: subject, object: jvar, graph: graph, path: lhs)
            let j = try evaluatePath(subject: jvar, object: object, graph: graph, path: rhs)
            return pipelinedHashJoin(joinVariables: [jvarname], lhs: i, rhs: j)
        case .star(let pp):
            switch (subject, object) {
            case (.bound(let t), .variable(let oname, binding: _)):
                let i = try alp(term: t, path: path, graph: graph)
                return AnyIterator {
                    guard let t = i.next() else { return nil }
                    return TermResult(bindings: [oname: t])
                }
            case (.variable(_), .bound(_)):
                let ipath : PropertyPath = .star(.inv(pp))
                return try evaluatePath(subject: object, object: subject, graph: graph, path: ipath)
            case (.bound(let t), .bound(let oterm)):
                var v = Set<Term>()
                try alp(term: t, path: path, seen: &v, graph: graph)
                
                var results = [TermResult]()
                if v.contains(oterm) {
                    results.append(TermResult(bindings: [:]))
                }
                return AnyIterator(results.makeIterator())
            case (.variable(let sname, binding: _), .variable(_)):
                var results = [TermResult]()
                for t in store.graphNodeTerms() {
                    let i = try evaluatePath(subject: .bound(t), object: object, graph: graph, path: pp)
                    let j = i.map {
                        $0.extended(variable: sname, value: t)
                    }
                    results.append(contentsOf: j)
                }
                return AnyIterator(results.makeIterator())
            default:
                fatalError("Unexpected case found for * property path")
            }
        case .plus(let pp):
            switch (subject, object) {
            case (.bound(_), .variable(let oname, binding: _)):
                let pvar = freshVariable()
                var v = Set<Term>()
                for result in try evaluatePath(subject: subject, object: pvar, graph: graph, path: pp) {
                    if let n = result[pvar] {
                        try alp(term: n, path: path, seen: &v, graph: graph)
                    }
                }
                
                var i = v.makeIterator()
                return AnyIterator {
                    guard let t = i.next() else { return nil }
                    return TermResult(bindings: [oname: t])
                }
            case (.variable(_), .bound(_)):
                let ipath : PropertyPath = .plus(.inv(pp))
                return try evaluatePath(subject: object, object: subject, graph: graph, path: ipath)
            case (.bound(_), .bound(let oterm)):
                let pvar = freshVariable()
                var v = Set<Term>()
                for result in try evaluatePath(subject: subject, object: pvar, graph: graph, path: pp) {
                    if let n = result[pvar] {
                        try alp(term: n, path: path, seen: &v, graph: graph)
                    }
                }
                
                var results = [TermResult]()
                if v.contains(oterm) {
                    results.append(TermResult(bindings: [:]))
                }
                return AnyIterator(results.makeIterator())
            case (.variable(let sname, binding: _), .variable(_)):
                var results = [TermResult]()
                for t in store.graphNodeTerms() {
                    let i = try evaluatePath(subject: .bound(t), object: object, graph: graph, path: pp)
                    let j = i.map {
                        $0.extended(variable: sname, value: t)
                    }
                    results.append(contentsOf: j)
                }
                return AnyIterator(results.makeIterator())
            default:
                fatalError("Unexpected case found for + property path")
            }
        case .zeroOrOne(_):
            fatalError("TODO: ZeroOrOne paths are not implemented yet")
        }
    }
    
    func evaluateNPS(subject: Node, object: Node, graph: Node, not iris: [Term]) throws -> AnyIterator<TermResult> {
        let predicate = self.freshVariable()
        let quad = QuadPattern(subject: subject, predicate: predicate, object: object, graph: graph)
        let i = try store.results(matching: quad)
        // TODO: this can be made more efficient by adding an NPS function to the store,
        //       and allowing it to do the filtering based on a IDResult objects before
        //       materializing the terms
        let set = Set(iris)
        var keys = [String]()
        for node in [subject, object] {
            if case .variable(let name, true) = node {
                keys.append(name)
            }
        }
        return AnyIterator {
            repeat {
                guard let r = i.next() else { return nil }
                guard let p = r[predicate] else { continue }
                guard !set.contains(p) else { continue }
                return r.projected(variables: keys)
            } while true
        }
    }

    func evaluateAggregation(algebra child: Algebra, groups: [Expression], aggregations aggs: [(Aggregation, String)], activeGraph : Term) throws -> AnyIterator<TermResult> {
        let i = try self.evaluate(algebra: child, activeGraph: activeGraph)
        var groupBuckets = [String:[TermResult]]()
        var groupBindings = [String:[String:Term]]()
        for result in i {
            let group = groups.map { (expr) -> Term? in return try? expr.evaluate(result: result) }
            let groupKey = "\(group)"
            if groupBuckets[groupKey] == nil {
                groupBuckets[groupKey] = [result]
                var bindings = [String:Term]()
                for (g, term) in zip(groups, group) {
                    if case .node(.variable(let name, true)) = g {
                        if let term = term {
                            bindings[name] = term
                        }
                    }
                }
                groupBindings[groupKey] = bindings
            } else {
                groupBuckets[groupKey]?.append(result)
            }
        }
        var a = groupBuckets.makeIterator()
        return AnyIterator {
            guard let pair = a.next() else { return nil }
            let (groupKey, results) = pair
            guard var bindings = groupBindings[groupKey] else { fatalError("Unexpected missing aggregation group template") }
            for (agg, name) in aggs {
                switch agg {
                case .countAll:
                    if let n = self.evaluateCountAll(results: results) {
                        bindings[name] = n
                    }
                case .count(let keyExpr, let distinct):
                    if let n = self.evaluateCount(results: results, expression: keyExpr, distinct: distinct) {
                        bindings[name] = n
                    }
                case .sum(let keyExpr, let distinct):
                    if let n = self.evaluateSum(results: results, expression: keyExpr, distinct: distinct) {
                        bindings[name] = n
                    }
                case .avg(let keyExpr, let distinct):
                    if let n = self.evaluateAvg(results: results, expression: keyExpr, distinct: distinct) {
                        bindings[name] = n
                    }
                case .min(let keyExpr):
                    let terms = results.map { try? keyExpr.evaluate(result: $0) }.flatMap { $0 }
                    if terms.count > 0 {
                        let n = terms.reduce(terms.first!) { min($0, $1) }
                        bindings[name] = n
                    }
                case .max(let keyExpr):
                    let terms = results.map { try? keyExpr.evaluate(result: $0) }.flatMap { $0 }
                    if terms.count > 0 {
                        let n = terms.reduce(terms.first!) { max($0, $1) }
                        bindings[name] = n
                    }
                case .sample(let keyExpr):
                    let terms = results.map { try? keyExpr.evaluate(result: $0) }.flatMap { $0 }
                    if let n = terms.first {
                        bindings[name] = n
                    }
                case .groupConcat(let keyExpr, let sep, let distinct):
                    if let n = self.evaluateGroupConcat(results: results, expression: keyExpr, separator: sep, distinct: distinct) {
                        bindings[name] = n
                    }
                }
            }
            return TermResult(bindings: bindings)
        }
    }
    
    private func _sortResults(_ results : [TermResult], comparators: [Algebra.SortComparator]) -> [TermResult] {
        let s = results.sorted { (a,b) -> Bool in
            for (ascending, expr) in comparators {
                guard var lhs = try? expr.evaluate(result: a) else { return true }
                guard var rhs = try? expr.evaluate(result: b) else { return false }
                if !ascending {
                    (lhs, rhs) = (rhs, lhs)
                }
                if lhs < rhs {
                    return true
                } else if lhs > rhs {
                    return false
                }
            }
            return false
        }
        return s
    }

    public func evaluate(algebra : Algebra, activeGraph : Term) throws -> AnyIterator<TermResult> {
        switch algebra {
        case .unionIdentity:
            let results = [TermResult]()
            return AnyIterator(results.makeIterator())
        case .joinIdentity:
            let results = [TermResult(bindings: [:])]
            return AnyIterator(results.makeIterator())
        case .table(_, let results):
            return AnyIterator(results.makeIterator())
        case .triple(let t):
            let quad = QuadPattern(subject: t.subject, predicate: t.predicate, object: t.object, graph: .bound(activeGraph))
            return try store.results(matching: quad)
        case .quad(let quad):
            return try store.results(matching: quad)
        case .innerJoin(let lhs, let rhs):
            return try self.evaluateJoin(lhs: lhs, rhs: rhs, left: false, activeGraph: activeGraph)
        case .leftOuterJoin(let lhs, let rhs, let expr):
            return try self.evaluateLeftJoin(lhs: lhs, rhs: rhs, expression: expr, activeGraph: activeGraph)
        case .union(let lhs, let rhs):
            return try self.evaluateUnion([lhs, rhs], activeGraph: activeGraph)
        case .project(let child, let vars):
            let i = try self.evaluate(algebra: child, activeGraph: activeGraph)
            return AnyIterator {
                guard let result = i.next() else { return nil }
                return result.projected(variables: vars)
            }
        case .namedGraph(let child, let graph):
            if case .bound(let g) = graph {
                return try evaluate(algebra: child, activeGraph: g)
            } else {
                guard case .variable(let gv, let bind) = graph else { fatalError("Unexpected node found where variable required") }
                var iters = try store.graphs().filter { $0 != defaultGraph }.map { ($0, try evaluate(algebra: child, activeGraph: $0)) }
                return AnyIterator {
                    repeat {
                        if iters.count == 0 {
                            return nil
                        }
                        let (graph, i) = iters[0]
                        guard var result = i.next() else { iters.remove(at: 0); continue }
                        if bind {
                            result.extend(variable: gv, value: graph)
                        }
                        return result
                    } while true
                }
            }
        case .slice(let child, let offset, let limit):
            let i = try self.evaluate(algebra: child, activeGraph: activeGraph)
            if let offset = offset {
                for _ in 0..<offset {
                    _ = i.next()
                }
            }
            
            if let limit = limit {
                var seen = 0
                return AnyIterator {
                    guard seen < limit else { return nil }
                    guard let item = i.next() else { return nil }
                    seen += 1
                    return item
                }
            } else {
                return i
            }
        case .extend(let child, let expr, let name):
            let i = try self.evaluate(algebra: child, activeGraph: activeGraph)
            
            if expr.isNumeric {
                return AnyIterator {
                    guard var result = i.next() else { return nil }
                    if let num = try? expr.numericEvaluate(result: result) {
                        result.extend(variable: name, value: num.term)
                    }
                    return result
                }
            } else {
                return AnyIterator {
                    guard var result = i.next() else { return nil }
                    if let term = try? expr.evaluate(result: result) {
                        result.extend(variable: name, value: term)
                    }
                    return result
                }
            }
        case .order(let child, let orders):
            let results = try Array(self.evaluate(algebra: child, activeGraph: activeGraph))
            let s = _sortResults(results, comparators: orders)
            return AnyIterator(s.makeIterator())
        case .aggregate(let child, let groups, let aggs):
            if aggs.count == 1 {
                let (agg, name) = aggs[0]
                switch agg {
                case .sum(_, false), .count(_, false), .countAll, .avg(_, false), .min(_), .max(_), .groupConcat(_, _, false), .sample(_):
                    return try evaluateSinglePipelinedAggregation(algebra: child, groups: groups, aggregation: agg, variable: name, activeGraph: activeGraph)
                default:
                    break
                }
            }
            return try evaluateAggregation(algebra: child, groups: groups, aggregations: aggs, activeGraph: activeGraph)
        case .window(let child, let groups, let funcs):
            return try evaluateWindow(algebra: child, groups: groups, functions: funcs, activeGraph: activeGraph)
        case .filter(let child, let expr):
            let i = try self.evaluate(algebra: child, activeGraph: activeGraph)
            return AnyIterator {
                repeat {
                    guard let result = i.next() else { return nil }
                    if let term = try? expr.evaluate(result: result) {
                        if case .some(true) = try? term.ebv() {
                            return result
                        }
                    }
                } while true
            }
        case .path(let s, let path, let o):
            return try evaluatePath(subject: s, object: o, graph: .bound(activeGraph), path: path)
        case .distinct(let child):
            let i = try self.evaluate(algebra: child, activeGraph: activeGraph)
            var seen = Set<TermResult>()
            return AnyIterator {
                repeat {
                    guard let result = i.next() else { return nil }
                    guard !seen.contains(result) else { continue }
                    seen.insert(result)
                    return result
                } while true
            }
        case .bgp(_), .minus(_, _), .describe(_), .ask(_), .construct(_), .service(_):
            fatalError("Unimplemented: \(algebra)")
        }
    }

    public func effectiveVersion(matching algebra: Algebra, activeGraph : Term) throws -> Version? {
        switch algebra {
        case .joinIdentity, .unionIdentity:
            return 0
        case .table(_, _):
            return 0
        case .path(_, _, _):
            let s : Node = .variable("s", binding: true)
            let p : Node = .variable("p", binding: true)
            let o : Node = .variable("o", binding: true)
            let quad = QuadPattern(subject: s, predicate: p, object: o, graph: .bound(activeGraph))
            return try store.effectiveVersion(matching: quad)
        case .triple(let t):
            let quad = QuadPattern(subject: t.subject, predicate: t.predicate, object: t.object, graph: .bound(activeGraph))
            return try store.effectiveVersion(matching: quad)
        case .quad(let quad):
            return try store.effectiveVersion(matching: quad)
        case .describe(let child, let nodes):
            guard var mtime = try effectiveVersion(matching: child, activeGraph: activeGraph) else { return nil }
            for node in nodes {
                let quad = QuadPattern(subject: node, predicate: .variable("p", binding: true), object: .variable("o", binding: true), graph: .bound(activeGraph))
                guard let qmtime = try store.effectiveVersion(matching: quad) else { return nil }
                mtime = max(mtime, qmtime)
            }
            return mtime
        case .construct(let child, let triples):
            let quads = triples.map { QuadPattern(subject: $0.subject, predicate: $0.predicate, object: $0.object, graph: .bound(activeGraph)) }
            let mtimes = try quads.map { try store.effectiveVersion(matching: $0) }.flatMap { $0 } // TODO: nil should propogate outwards, instead of being dropped by flatMap
            guard let mtime = try effectiveVersion(matching: child, activeGraph: activeGraph) else { return nil }
            return mtimes.reduce(mtime) { max($0, $1) }
        case .innerJoin(let lhs, let rhs), .leftOuterJoin(let lhs, let rhs, _), .union(let lhs, let rhs), .minus(let lhs, let rhs):
            guard let lhsmtime = try effectiveVersion(matching: lhs, activeGraph: activeGraph) else { return nil }
            guard let rhsmtime = try effectiveVersion(matching: rhs, activeGraph: activeGraph) else { return lhsmtime }
            return max(lhsmtime, rhsmtime)
        case .namedGraph(let child, let graph):
            if case .bound(let g) = graph {
                return try effectiveVersion(matching: child, activeGraph: g)
            } else {
                fatalError("Unimplemented: effectiveVersion(.namedGraph(_), )")
            }
        case .distinct(let child), .project(let child, _), .slice(let child, _, _), .extend(let child, _, _), .order(let child, _), .filter(let child, _), .ask(let child):
            return try effectiveVersion(matching: child, activeGraph: activeGraph)
        case .aggregate(let child, _, _):
            return try effectiveVersion(matching: child, activeGraph: activeGraph)
        case .window(let child, _, _):
            return try effectiveVersion(matching: child, activeGraph: activeGraph)
        case .bgp(let children):
            guard children.count > 0 else { return nil }
            var mtime : Version = 0
            for t in children {
                let quad = QuadPattern(subject: t.subject, predicate: t.predicate, object: t.object, graph: .bound(activeGraph))
                guard let triplemtime = try store.effectiveVersion(matching: quad) else { continue }
                mtime = max(mtime, triplemtime)
            }
            return mtime
        case .service(_):
            return nil
        }
    }
    
}

public func pipelinedHashJoin<R : ResultProtocol>(joinVariables : [String], lhs : AnyIterator<R>, rhs : AnyIterator<R>, left : Bool = false) -> AnyIterator<R> {
    var table = [R:[R]]()
//    warn(">>> filling hash table")
    var count = 0
    for result in rhs {
        count += 1
        let key = result.projected(variables: joinVariables)
        if let results = table[key] {
            table[key] = results + [result]
        } else {
            table[key] = [result]
        }
    }
//    warn(">>> done (\(count) results in \(Array(table.keys).count) buckets)")
    
    var buffer = [R]()
    return AnyIterator {
        repeat {
            if buffer.count > 0 {
                return buffer.remove(at: 0)
            }
            guard let result = lhs.next() else { return nil }
            var joined = false
            let key = result.projected(variables: joinVariables)
            if let results = table[key] {
                for lhs in results {
                    if let j = lhs.join(result) {
                        joined = true
                        buffer.append(j)
                    }
                }
            }
            if left && !joined {
                buffer.append(result)
            }
        } while true
    }
}

public func nestedLoopJoin<R : ResultProtocol>(_ results : [[R]], left : Bool = false, cb : (R) -> ()) {
    var patternResults = results
    while patternResults.count > 1 {
        let rhs = patternResults.popLast()!
        let lhs = patternResults.popLast()!
        let finalPass = patternResults.count == 0
        var joinedResults = [R]()
        for lresult in lhs {
            var joined = false
            for rresult in rhs {
                if let j = lresult.join(rresult) {
                    joined = true
                    if finalPass {
                        cb(j)
                    } else {
                        joinedResults.append(j)
                    }
                }
            }
            if left && !joined {
                if finalPass {
                    cb(lresult)
                } else {
                    joinedResults.append(lresult)
                }
            }
        }
        patternResults.append(joinedResults)
    }
}
