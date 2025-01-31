//
//  Query.swift
//  Kineo
//
//  Created by Gregory Todd Williams on 7/8/16.
//  Copyright © 2016 Gregory Todd Williams. All rights reserved.
//

import Foundation
import SPARQLSyntax

fileprivate struct SortElem {
    var result: SPARQLResultSolution<Term>
    var terms: [Term?]
}

// swiftlint:disable cyclomatic_complexity
// swiftlint:disable:next type_body_length
public protocol SimpleQueryEvaluatorProtocol: QueryEvaluatorProtocol {
    var dataset: Dataset { get }
    var ee: ExpressionEvaluator { get }
    
    var verbose: Bool { get }
    
    func freshVariable() -> Node
    func evaluate(query: Query) throws -> QueryResult<[SPARQLResultSolution<Term>], [Triple]>
    func evaluate(query: Query, activeGraph: Term?) throws -> QueryResult<[SPARQLResultSolution<Term>], [Triple]>
    func evaluate(algebra: Algebra, activeGraph: Term?) throws -> AnyIterator<SPARQLResultSolution<Term>>
    func evaluateTable(columns names: [Node], rows: [[Term?]]) throws -> AnyIterator<SPARQLResultSolution<Term>>
    func evaluateSlice(_ i: AnyIterator<SPARQLResultSolution<Term>>, offset: Int?, limit: Int?) throws -> AnyIterator<SPARQLResultSolution<Term>>
    func evaluateExtend(_ i: AnyIterator<SPARQLResultSolution<Term>>, expression expr: Expression, name: String) throws -> AnyIterator<SPARQLResultSolution<Term>>
    func evaluateFilter(_ i: AnyIterator<SPARQLResultSolution<Term>>, expression expr: Expression, activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>>
    func evaluateMinus(_ l: AnyIterator<SPARQLResultSolution<Term>>, _ r: [SPARQLResultSolution<Term>]) throws -> AnyIterator<SPARQLResultSolution<Term>>
    func evaluate(algebra: Algebra, activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>>
    func effectiveVersion(matching query: Query) throws -> Version?
    func effectiveVersion(matching algebra: Algebra, activeGraph: Term) throws -> Version?
    func evaluateUnion(_ patterns: [Algebra], activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>>
    func evaluateJoin(lhs lhsAlgebra: Algebra, rhs rhsAlgebra: Algebra, left: Bool, activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>>
    func evaluate(diff lhs: Algebra, _ rhs: Algebra, expression expr: Expression, activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>>
    func evaluateLeftJoin(lhs: Algebra, rhs: Algebra, expression expr: Expression, activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>>
    func evaluate(algebra: Algebra, endpoint: URL, silent: Bool, activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>>
    func evaluateCount<S: Sequence>(results: S, expression keyExpr: Expression, distinct: Bool) -> Term? where S.Iterator.Element == SPARQLResultSolution<Term>
    func evaluateCountAll<S: Sequence>(results: S) -> Term? where S.Iterator.Element == SPARQLResultSolution<Term>
    func evaluateAvg<S: Sequence>(results: S, expression keyExpr: Expression, distinct: Bool) -> Term? where S.Iterator.Element == SPARQLResultSolution<Term>
    func evaluateSum<S: Sequence>(results: S, expression keyExpr: Expression, distinct: Bool) -> Term? where S.Iterator.Element == SPARQLResultSolution<Term>
    func evaluateGroupConcat<S: Sequence>(results: S, expression keyExpr: Expression, separator: String, distinct: Bool) -> Term? where S.Iterator.Element == SPARQLResultSolution<Term>
    func evaluateWindow(algebra child: Algebra, function: Algebra.WindowFunctionMapping, activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>>
    func evaluatePath(subject: Node, object: Node, graph: Term, path: PropertyPath) throws -> AnyIterator<SPARQLResultSolution<Term>>
    func evaluateAggregation(algebra child: Algebra, groups: [Expression], aggregations aggs: Set<Algebra.AggregationMapping>, activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>>
    func evaluateSort<S: Sequence>(_ results: S, comparators: [Algebra.SortComparator]) -> [SPARQLResultSolution<Term>] where S.Element == SPARQLResultSolution<Term>
    func resultsAreEqual(_ a : SPARQLResultSolution<Term>, _ b : SPARQLResultSolution<Term>, usingComparators: [Algebra.SortComparator]) -> Bool
    
    func evaluate(bgp: [TriplePattern], activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>>
    
    func evaluate(quad: QuadPattern) throws -> AnyIterator<SPARQLResultSolution<Term>>
    func evaluate(algebra: Algebra, inGraph: Node) throws -> AnyIterator<SPARQLResultSolution<Term>>
    func evaluateGraphTerms(in: Term) -> AnyIterator<Term>
    func triples(describing term: Term) throws -> AnyIterator<Triple>
}

extension SimpleQueryEvaluatorProtocol {
    public func evaluate(query original: Query) throws -> QueryResult<[SPARQLResultSolution<Term>], [Triple]> {
        let rewriter = SPARQLQueryRewriter()
        let query = try rewriter.simplify(query: original)
//        if verbose {
//            if query != original {
//                print("=========================================================")
//                print(original.serialize())
//                print("==>>>")
//                print(query.serialize())
//                print("---------------------------------------------------------")
//            }
//        }
        return try evaluate(query: query, activeGraph: nil)
    }
    
    public func evaluate(query: Query, activeGraph: Term?) throws -> QueryResult<[SPARQLResultSolution<Term>], [Triple]> {
        let algebra = query.algebra
        self.ee.base = query.base
        let iter = try self.evaluate(algebra: algebra, activeGraph: activeGraph)
        let results = Array(iter) // OPTIMIZE:
        switch query.form {
        case .ask:
            if results.isEmpty {
                return QueryResult.boolean(false)
            } else {
                return QueryResult.boolean(true)
            }
        case .select:
            let variables = query.projectedVariables
            let r : QueryResult<[SPARQLResultSolution<Term>], [Triple]> = QueryResult.bindings(variables, results)
            return r
        case .construct(let template):
            let t = triples(from: results, with: template)
            return QueryResult.triples(t)
        case .describe(let nodes):
            let iters = try nodes.map { try triples(describing: $0, from: results) }
            let t = Array(iters.joined())
            return QueryResult.triples(t)
        }
    }
    
    public func evaluate(query: Query, activeGraph: Term?, resultHandler: (PushQueryResult) -> ()) throws {
        let algebra = query.algebra
        self.ee.base = query.base
        let iter = try self.evaluate(algebra: algebra, activeGraph: activeGraph)
        switch query.form {
        case .ask:
            let results = Array(iter)
            resultHandler(.boolean(results.isEmpty ? false : true))
        case .select:
            let variables = query.projectedVariables
            iter.forEach { (r) in
                resultHandler(.binding(variables, r))
            }
        case .construct(let template):
            iter.forEach {
                self.triples(from: [$0], with: template).lazy.forEach {
                    resultHandler(.triple($0))
                }
            }
        case .describe(let nodes):
            iter.forEach { (r) in
                nodes.forEach { (node) in
                    if let triplesIterator = try? triples(describing: node, from: [r]) {
                        triplesIterator.forEach { (triple) in
                            resultHandler(.triple(triple))
                        }
                    }
                }
            }
        }
    }
    
    public func evaluate(algebra: Algebra, activeGraph: Term? = nil) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        var iterators = [AnyIterator<SPARQLResultSolution<Term>>]()
        let graphs : [Term]
        if let g = activeGraph {
            graphs = [g]
        } else {
            graphs = dataset.defaultGraphs
        }
        if graphs.isEmpty {
            print("*** There is no active graph during algebra evaluation:")
            print("*** \(algebra.serialize())")
        }
        for activeGraph in graphs {
            let i = try evaluate(algebra: algebra, activeGraph: activeGraph)
            iterators.append(i)
        }
        let j = iterators.joined()
        return AnyIterator(j.makeIterator())
    }
    
    public func evaluateTable(columns names: [Node], rows: [[Term?]]) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        var results = [SPARQLResultSolution<Term>]()
        for row in rows {
            var bindings = [String:Term]()
            for (node, term) in zip(names, row) {
                guard case .variable(let name, _) = node else {
                    Logger.shared.error("Unexpected variable generated during table evaluation")
                    throw QueryError.evaluationError("Unexpected variable generated during table evaluation")
                }
                if let term = term {
                    bindings[name] = term
                }
            }
            let result = SPARQLResultSolution<Term>(bindings: bindings)
            results.append(result)
        }
        return AnyIterator(results.makeIterator())
    }
    
    public func evaluateSlice(_ i: AnyIterator<SPARQLResultSolution<Term>>, offset: Int?, limit: Int?) throws -> AnyIterator<SPARQLResultSolution<Term>> {
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
    }
    
    public func evaluateExtend(_ i: AnyIterator<SPARQLResultSolution<Term>>, expression expr: Expression, name: String) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        if expr.isNumeric {
            return AnyIterator {
                guard var result = i.next() else { return nil }
                do {
                    let num = try self.ee.numericEvaluate(expression: expr, result: result)
                    try result.extend(variable: name, value: num.term)
                } catch let err {
                    if self.verbose {
                        print(err)
                    }
                }
                return result
            }
        } else {
            return AnyIterator {
                guard var result = i.next() else { return nil }
                do {
                    let term = try self.ee.evaluate(expression: expr, result: result)
                    try result.extend(variable: name, value: term)
                } catch let err {
                    if self.verbose {
                        print(err)
                    }
                }
                return result
            }
        }
    }
    
    public func evaluateFilter(_ i: AnyIterator<SPARQLResultSolution<Term>>, expression expr: Expression, activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        return AnyIterator {
            repeat {
                guard let result = i.next() else { return nil }
                self.ee.nextResult()
                do {
                    let term = try self.ee.evaluate(expression: expr, result: result, activeGraph: activeGraph) { (algebra, graph) throws in
                        return try self.evaluate(algebra: algebra, activeGraph: graph)
                    }
                    //                        print("filter \(term) <- \(expr)")
                    let ebv = try? term.ebv()
                    if case .some(true) = ebv {
                        return result
                    }
                } catch let err {
                    //                        print("filter error: \(err) ; \(expr)")
                    if self.verbose {
                        print("filter error: \(err) ; \(expr)")
                    }
                }
            } while true
        }
    }
    
    public func evaluateMinus(_ l: AnyIterator<SPARQLResultSolution<Term>>, _ r: [SPARQLResultSolution<Term>]) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        return AnyIterator {
            while true {
                var candidateOK = true
                guard let candidate = l.next() else { return nil }
                for result in r {
                    let domainIntersection = Set(candidate.keys).intersection(result.keys)
                    let disjoint = (domainIntersection.count == 0)
                    let compatible = !(candidate.join(result) == nil)
                    if !(disjoint || !compatible) {
                        candidateOK = false
                        break
                    }
                }
                if candidateOK {
                    return candidate
                }
            }
        }
    }
    
    public func evaluate(algebra: Algebra, activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        switch algebra {
        // don't require access to the underlying store:
        case let .subquery(q):
            let result = try evaluate(query: q, activeGraph: activeGraph)
            guard case let .bindings(_, seq) = result else { throw QueryError.evaluationError("Unexpected results type from subquery: \(result)") }
            return AnyIterator(seq.makeIterator())
        case .unionIdentity:
            let results = [SPARQLResultSolution<Term>]()
            return AnyIterator(results.makeIterator())
        case .joinIdentity:
            let results = [SPARQLResultSolution<Term>(bindings: [:])]
            return AnyIterator(results.makeIterator())
        case let .table(names, rows):
            return try evaluateTable(columns: names, rows: rows)
        case let .innerJoin(lhs, rhs):
            return try self.evaluateJoin(lhs: lhs, rhs: rhs, left: false, activeGraph: activeGraph)
        case let .leftOuterJoin(lhs, rhs, expr):
            return try self.evaluateLeftJoin(lhs: lhs, rhs: rhs, expression: expr, activeGraph: activeGraph)
        case .union:
            let branches = algebra.unionBranches()
            return try self.evaluateUnion(branches, activeGraph: activeGraph)
        case let .project(child, vars):
            let i = try self.evaluate(algebra: child, activeGraph: activeGraph)
            return AnyIterator {
                guard let result = i.next() else { return nil }
                return result.projected(variables: vars)
            }
        case let .slice(child, offset, limit):
            let i = try self.evaluate(algebra: child, activeGraph: activeGraph)
            return try evaluateSlice(i, offset: offset, limit: limit)
        case let .extend(child, expr, name):
            self.ee.nextResult()
            let i = try self.evaluate(algebra: child, activeGraph: activeGraph)
            return try evaluateExtend(i, expression: expr, name: name)
        case let .order(child, orders):
            let results = try self.evaluate(algebra: child, activeGraph: activeGraph)
            let s = evaluateSort(results, comparators: orders)
            return AnyIterator(s.makeIterator())
        case let .aggregate(child, groups, aggs):
            if aggs.count == 1 {
                let aggMap = aggs.first!
                switch aggMap.aggregation {
                case .sum(_, false), .count(_, false), .countAll, .avg(_, false), .min(_), .max(_), .groupConcat(_, _, false), .sample(_):
                    return try evaluateSinglePipelinedAggregation(algebra: child, groups: groups, aggregation: aggMap.aggregation, variable: aggMap.variableName, activeGraph: activeGraph)
                default:
                    break
                }
            }
            return try evaluateAggregation(algebra: child, groups: groups, aggregations: aggs, activeGraph: activeGraph)
        case let .window(child, funcs):
            if funcs.count == 1 {
                let f = funcs.first!
                return try evaluateWindow(algebra: child, function: f, activeGraph: activeGraph)
            } else {
                let windows : Algebra = funcs.reduce(child) { Algebra.window($0, [$1]) }
                return try evaluate(algebra: windows, activeGraph: activeGraph)
            }
        case let .filter(child, expr):
            let i = try self.evaluate(algebra: child, activeGraph: activeGraph)
            return try evaluateFilter(i, expression: expr, activeGraph: activeGraph)
        case let .reduced(child):
            let i = try self.evaluate(algebra: child, activeGraph: activeGraph)
            var last: SPARQLResultSolution<Term>? = nil
            return AnyIterator {
                repeat {
                    guard let result = i.next() else { return nil }
                    if let l = last, l == result {
                        last = result
                        continue
                    }
                    last = result
                    return result
                } while true
            }
        case let .distinct(child):
            let i = try self.evaluate(algebra: child, activeGraph: activeGraph)
            var seen = Set<SPARQLResultSolution<Term>>()
            return AnyIterator {
                repeat {
                    guard let result = i.next() else { return nil }
                    guard !seen.contains(result) else { continue }
                    seen.insert(result)
                    return result
                } while true
            }
        case .bgp(let patterns):
            return try evaluate(bgp: patterns, activeGraph: activeGraph)
        case let .minus(lhs, rhs):
            let l = try self.evaluate(algebra: lhs, activeGraph: activeGraph)
            let r = try Array(self.evaluate(algebra: rhs, activeGraph: activeGraph))
            return try evaluateMinus(l, r)
        case let .service(endpoint, algebra, silent):
            return try evaluate(algebra: algebra, endpoint: endpoint, silent: silent, activeGraph: activeGraph)
        case let .namedGraph(child, .bound(g)):
            return try evaluate(algebra: child, activeGraph: g)
        case let .triple(t):
            let quad = QuadPattern(subject: t.subject, predicate: t.predicate, object: t.object, graph: .bound(activeGraph))
            return try evaluate(algebra: .quad(quad), activeGraph: activeGraph)
            
            
        // requires access to the underlying store:
        case let .quad(quad):
            return try evaluate(quad: quad)
        case let .path(s, path, o):
            return try evaluatePath(subject: s, object: o, graph: activeGraph, path: path)
        case let .namedGraph(child, graph):
            return try evaluate(algebra: child, inGraph: graph)
        }
    }
    
    // NOTE: this is a lazy version of union that hides thrown exceptions in order to delay evaluation
    //       the non-lazy version is commented below
    public func evaluateUnion(_ _patterns: [Algebra], activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        var patterns = _patterns
        var currentIterator: AnyIterator<SPARQLResultSolution<Term>>? = nil
        return AnyIterator { () -> SPARQLResultSolution<Term>? in
            do {
                repeat {
                    if let _ = currentIterator {
                        guard let item = currentIterator!.next() else { currentIterator = nil; continue }
                        return item
                    } else {
                        guard let algebra = patterns.first else {
                            return nil
                        }
                        patterns.removeFirst()
                        currentIterator = try self.evaluate(algebra: algebra, activeGraph: activeGraph)
                    }
                } while true
            } catch let error {
                print("*** error in union evaluation: \(error)")
                return nil
            }
        }
    }
//    public func evaluateUnion(_ patterns: [Algebra], activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>> {
//        var iters = try patterns.lazy.map { try self.evaluate(algebra: $0, activeGraph: activeGraph) }
//        return AnyIterator {
//            repeat {
//                if iters.count == 0 {
//                    return nil
//                }
//                let i = iters[0]
//                guard let item = i.next() else { iters.remove(at: 0); continue }
//                return item
//            } while true
//        }
//    }
    
    public func evaluateJoin(lhs lhsAlgebra: Algebra, rhs rhsAlgebra: Algebra, left: Bool, activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>> {
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
        let boundVariables = lhsAlgebra.necessarilyBound.intersection(rhsAlgebra.necessarilyBound)
        //        if intersection != boundVariables {
        //            print("================")
        //            print(lhsAlgebra.serialize())
        //            print(rhsAlgebra.serialize())
        //            print("Necessarily bound variables: \(boundVariables)")
        //            print("Hash join key variables: \(intersection)")
        //        }
        
        if intersection.count > 0 {
            //            warn("# using hash join on: \(intersection)")
            //            warn("### \(lhsAlgebra)")
            //            warn("### \(rhsAlgebra)")
            let joinVariables = intersection
            let lhs = try self.evaluate(algebra: lhsAlgebra, activeGraph: activeGraph)
            let rhs = try self.evaluate(algebra: rhsAlgebra, activeGraph: activeGraph)
            if joinVariables == boundVariables {
                //                print("using optimized hash-join algorithm based on necessarily-bound variables")
                return pipelinedHashJoin(boundJoinVariables: boundVariables, lhs: lhs, rhs: rhs, left: left)
            } else {
                //                print("using fallback hash-join algorithm that will handle results with unbound join variables")
                return pipelinedHashJoin(joinVariables: joinVariables, lhs: lhs, rhs: rhs, left: left)
            }
        }
        
        var patternResults = [[SPARQLResultSolution<Term>]]()
        for pattern in [lhsAlgebra, rhsAlgebra] {
            let results     = try self.evaluate(algebra: pattern, activeGraph: activeGraph)
            patternResults.append(Array(results))
        }
        
        var results = [SPARQLResultSolution<Term>]()
        nestedLoopJoin(patternResults, left: left) { (result) in
            results.append(result)
        }
        return AnyIterator(results.makeIterator())
    }
    
    public func evaluate(diff lhs: Algebra, _ rhs: Algebra, expression expr: Expression, activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        let i = try evaluate(algebra: lhs, activeGraph: activeGraph)
        let r = try Array(evaluate(algebra: rhs, activeGraph: activeGraph))
        return AnyIterator {
            repeat {
                guard let result = i.next() else { return nil }
                var ok = true
                for candidate in r {
                    if let j = result.join(candidate) {
                        self.ee.nextResult()
                        if let term = try? self.ee.evaluate(expression: expr, result: j) {
                            if case .some(true) = try? term.ebv() {
                                ok = false
                                break
                            }
                        }
                    }
                }
                
                if ok {
                    return result
                }
            } while true
        }
    }
    
    public func evaluateLeftJoin(lhs: Algebra, rhs: Algebra, expression expr: Expression, activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        let i = try evaluate(algebra: .filter(.innerJoin(lhs, rhs), expr), activeGraph: activeGraph)
        let d = try evaluate(diff: lhs, rhs, expression: expr, activeGraph: activeGraph)
        let results = Array(i) + Array(d)
        return AnyIterator(results.makeIterator())
    }
    
    public func evaluate(algebra: Algebra, endpoint: URL, silent: Bool, activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        let client = SPARQLClient(endpoint: endpoint, silent: silent)
        do {
            let s = SPARQLSerializer(prettyPrint: true)
            guard let q = try? Query(form: .select(.star), algebra: algebra) else {
                throw QueryError.evaluationError("Failed to serialize SERVICE algebra into SPARQL string")
            }
            let tokens = try q.sparqlTokens()
            let query = s.serialize(tokens)
            let r = try client.execute(query)
            switch r {
            case let .bindings(_, seq):
                return AnyIterator(seq.makeIterator())
            default:
                throw QueryError.evaluationError("SERVICE request did not return bindings")
            }
        } catch let e {
            throw QueryError.evaluationError("SERVICE error: \(e)")
        }
    }
    
    public func evaluateCount<S: Sequence>(results: S, expression keyExpr: Expression, distinct: Bool) -> Term? where S.Iterator.Element == SPARQLResultSolution<Term> {
        if distinct {
            let terms = results.map { try? self.ee.evaluate(expression: keyExpr, result: $0) }.compactMap { $0 }
            let unique = Set(terms)
            return Term(integer: unique.count)
        } else {
            var count = 0
            for result in results {
                do {
                    let _ = try self.ee.evaluate(expression: keyExpr, result: result)
                    count += 1
                } catch let err {
                    if self.verbose {
                        print(err)
                    }
                }
            }
            return Term(integer: count)
        }
    }

    public func evaluateAggregation<S: Sequence>(_ agg: Aggregation, group results: S) -> Term? where S.Iterator.Element == SPARQLResultSolution<Term> {
        switch agg {
        case .countAll:
            if let n = self.evaluateCountAll(results: results) {
                return n
            }
        case .count(let keyExpr, let distinct):
            if let n = self.evaluateCount(results: results, expression: keyExpr, distinct: distinct) {
                return n
            }
        case .sum(let keyExpr, let distinct):
            if let n = self.evaluateSum(results: results, expression: keyExpr, distinct: distinct) {
                return n
            }
        case .avg(let keyExpr, let distinct):
            if let n = self.evaluateAvg(results: results, expression: keyExpr, distinct: distinct) {
                return n
            }
        case .min(let keyExpr):
            let terms = results.map { try? self.ee.evaluate(expression: keyExpr, result: $0) }.compactMap { $0 }
            if terms.count > 0 {
                let n = terms.reduce(terms.first!) { min($0, $1) }
                return n
            }
        case .max(let keyExpr):
            let terms = results.map { try? self.ee.evaluate(expression: keyExpr, result: $0) }.compactMap { $0 }
            if terms.count > 0 {
                let n = terms.reduce(terms.first!) { max($0, $1) }
                return n
            }
        case .sample(let keyExpr):
            let terms = results.map { try? self.ee.evaluate(expression: keyExpr, result: $0) }.compactMap { $0 }
            if let n = terms.first {
                return n
            }
        case .groupConcat(let keyExpr, let sep, let distinct):
            if let n = self.evaluateGroupConcat(results: results, expression: keyExpr, separator: sep, distinct: distinct) {
                return n
            }
        }
        return nil
    }
    
    public func evaluateCountAll<S: Sequence>(results: S) -> Term? where S.Iterator.Element == SPARQLResultSolution<Term> {
        var count = 0
        for _ in results {
            count += 1
        }
        return Term(integer: count)
    }
    
    public func evaluateAvg<S: Sequence>(results: S, expression keyExpr: Expression, distinct: Bool) -> Term? where S.Iterator.Element == SPARQLResultSolution<Term> {
        var doubleSum: Double = 0.0
        let integer = TermType.datatype(.integer)
        var resultingType: TermType? = integer
        var count = 0
        
        var terms = results.map { try? self.ee.evaluate(expression: keyExpr, result: $0) }.compactMap { $0 }
        if distinct {
            terms = Set(terms).sorted()
        }
        
        for term in terms {
            if term.isNumeric {
                count += 1
                resultingType = resultingType?.resultType(for: "+", withOperandType: term.type)
                doubleSum += term.numericValue
            } else {
                return nil
            }
        }
        
        doubleSum /= Double(count)
        resultingType = resultingType?.resultType(for: "/", withOperandType: integer)
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
    
    public func evaluateSum<S: Sequence>(results: S, expression keyExpr: Expression, distinct: Bool) -> Term? where S.Iterator.Element == SPARQLResultSolution<Term> {
        var runningSum = NumericValue.integer(0)
        if distinct {
            let terms = results.map { try? self.ee.evaluate(expression: keyExpr, result: $0) }.compactMap { $0 }.sorted()
            let unique = Set(terms)
            if unique.count == 0 {
                return nil
            }
            for term in unique {
                if let numeric = term.numeric {
                    runningSum = runningSum + numeric
                } else {
                    return nil
                }
            }
            return runningSum.term
        } else {
            var count = 0
            for result in results {
                if let term = try? self.ee.evaluate(expression: keyExpr, result: result) {
                    count += 1
                    if let numeric = term.numeric {
                        runningSum = runningSum + numeric
                    } else {
                        return nil
                    }
                }
            }
            if count == 0 {
                return nil
            }
            return runningSum.term
        }
    }
    
    public func evaluateGroupConcat<S: Sequence>(results: S, expression keyExpr: Expression, separator: String, distinct: Bool) -> Term? where S.Iterator.Element == SPARQLResultSolution<Term> {
        var terms = results.map { try? self.ee.evaluate(expression: keyExpr, result: $0) }.compactMap { $0 }
        if distinct {
            terms = Set(terms).sorted()
        }
        
        if terms.count == 0 {
            return nil
        }
        
        let values = terms.map { $0.value }
        let type = terms.first!.type
        let c = values.joined(separator: separator)
        return Term(value: c, type: type)
    }
    
    internal func evaluateSinglePipelinedAggregation(algebra child: Algebra, groups: [Expression], aggregation agg: Aggregation, variable name: String, activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        let i = try self.evaluate(algebra: child, activeGraph: activeGraph)
        var numericGroups = [String:NumericValue]()
        var termGroups = [String:Term]()
        var groupCount = [String:Int]()
        var groupErrors = [String:Error]()
        var groupBindings = [String:[String:Term]]()
        for result in i {
            let group = groups.map {
                (expr) -> Term? in
                return try? self.ee.evaluate(expression: expr, result: result)
            }
            let groupKey = "\(group)"
            
            do {
                if let value = termGroups[groupKey] {
                    switch agg {
                    case .min(let keyExpr):
                        let term = try self.ee.evaluate(expression: keyExpr, result: result)
                        termGroups[groupKey] = min(value, term)
                    case .max(let keyExpr):
                        let term = try self.ee.evaluate(expression: keyExpr, result: result)
                        termGroups[groupKey] = max(value, term)
                    case .sample(_):
                        break
                    case .groupConcat(let keyExpr, let sep, false):
                        guard case .datatype(_) = value.type else {
                            Logger.shared.error("Unexpected term in generating GROUP_CONCAT value")
                            throw QueryError.evaluationError("Unexpected term in generating GROUP_CONCAT value")
                        }
                        let string = value.value
                        let term = try self.ee.evaluate(expression: keyExpr, result: result)
                        let updated = string + sep + term.value
                        termGroups[groupKey] = Term(value: updated, type: value.type)
                    default:
                        Logger.shared.error("unexpected pipelined evaluation for \(agg)")
                        throw QueryError.evaluationError("unexpected pipelined evaluation for \(agg)")
                    }
                } else if let value = numericGroups[groupKey] {
                    switch agg {
                    case .countAll:
                        numericGroups[groupKey] = value + .integer(1)
                    case .avg(let keyExpr, false):
                        let term = try self.ee.evaluate(expression: keyExpr, result: result)
                        if let n = term.numeric {
                            numericGroups[groupKey] = value + n
                            groupCount[groupKey, default: 0] += 1
                        } else {
                            groupErrors[groupKey] = QueryError.evaluationError("Non-numeric term in numeric aggregation (\(term))")
                        }
                    case .count(let keyExpr, false):
                        let _ = try self.ee.evaluate(expression: keyExpr, result: result)
                        numericGroups[groupKey] = value + .integer(1)
                    case .sum(let keyExpr, false):
                        let term = try self.ee.evaluate(expression: keyExpr, result: result)
                        if let n = term.numeric {
                            numericGroups[groupKey] = value + n
                        } else {
                            groupErrors[groupKey] = QueryError.evaluationError("Non-numeric term in numeric aggregation (\(term))")
                        }
                    default:
                        Logger.shared.error("unexpected pipelined evaluation for \(agg)")
                        throw QueryError.evaluationError("unexpected pipelined evaluation for \(agg)")
                    }
                } else {
                    switch agg {
                    case .countAll:
                        numericGroups[groupKey] = .integer(1)
                    case .avg(let keyExpr, false):
                        let term = try self.ee.evaluate(expression: keyExpr, result: result)
                        if term.isNumeric {
                            numericGroups[groupKey] = term.numeric
                            groupCount[groupKey] = 1
                        } else {
                            groupErrors[groupKey] = QueryError.evaluationError("Non-numeric term in numeric aggregation (\(term))")
                        }
                    case .count(let keyExpr, false):
                        let _ = try self.ee.evaluate(expression: keyExpr, result: result)
                        numericGroups[groupKey] = .integer(1)
                    case .sum(let keyExpr, false):
                        let term = try self.ee.evaluate(expression: keyExpr, result: result)
                        if term.isNumeric {
                            numericGroups[groupKey] = term.numeric
                        } else {
                            groupErrors[groupKey] = QueryError.evaluationError("Non-numeric term in numeric aggregation (\(term))")
                        }
                    case .min(let keyExpr):
                        let term = try self.ee.evaluate(expression: keyExpr, result: result)
                        termGroups[groupKey] = term
                    case .max(let keyExpr):
                        let term = try self.ee.evaluate(expression: keyExpr, result: result)
                        termGroups[groupKey] = term
                    case .sample(let keyExpr):
                        let term = try self.ee.evaluate(expression: keyExpr, result: result)
                        termGroups[groupKey] = term
                    case .groupConcat(let keyExpr, _, false):
                        let term = try self.ee.evaluate(expression: keyExpr, result: result)
                        switch term.type {
                        case .datatype(_):
                            termGroups[groupKey] = term
                        default:
                            termGroups[groupKey] = Term(string: term.value)
                        }
                    default:
                        Logger.shared.error("unexpected pipelined evaluation for \(agg)")
                        throw QueryError.evaluationError("unexpected pipelined evaluation for \(agg)")
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
            } catch let e {
                Logger.shared.warn("*** error evaluating aggregate expression: \(e)")
            }
        }
        
        if numericGroups.count == 0 && termGroups.count == 0 {
            if groups.isEmpty {
                // special case where there are no groups (no input rows led to no groups being created);
                // TODO: make sure this works the same as the more general code in evaluateAggregation(algebra:groups:aggregations:activeGraph:)
                switch agg {
                case .avg, .count, .countAll, .sum:
                    // in this case, counts should return a single result with { $name=0 }
                    let result = SPARQLResultSolution<Term>(bindings: [name: Term(integer: 0)])
                    return AnyIterator([result].makeIterator())
                default:
                    // the non-numeric aggregates don't produce a value on an empty resultset
                    let result = SPARQLResultSolution<Term>(bindings: [:])
                    return AnyIterator([result].makeIterator())
                }
            }
            return AnyIterator([].makeIterator())
        }
        
        var a = numericGroups.makeIterator()
        let numericIterator : AnyIterator<SPARQLResultSolution<Term>> = AnyIterator {
            guard let pair = a.next() else { return nil }
            let (groupKey, v) = pair
            var value = v
            if case .avg = agg {
                guard let count = groupCount[groupKey] else {
                    Logger.shared.error("Failed to find expected group data during aggregation")
                    fatalError("Failed to find expected group data during aggregation")
                }
                value = v / NumericValue.integer(count)
            }
            
            guard var bindings = groupBindings[groupKey] else {
                Logger.shared.error("Unexpected missing aggregation group template")
                fatalError("Unexpected missing aggregation group template")
            }
            if let error = groupErrors[groupKey] {
                print("*** error binding aggregate to ?\(name): \(error)")
            } else {
                bindings[name] = value.term
            }
            return SPARQLResultSolution<Term>(bindings: bindings)
        }
        var b = termGroups.makeIterator()
        let termIterator : AnyIterator<SPARQLResultSolution<Term>> = AnyIterator {
            guard let pair = b.next() else { return nil }
            let (groupKey, term) = pair
            guard var bindings = groupBindings[groupKey] else {
                Logger.shared.error("Unexpected missing aggregation group template")
                fatalError("Unexpected missing aggregation group template")
            }
            if let error = groupErrors[groupKey] {
                print("*** error binding aggregate to ?\(name): \(error)")
            } else {
                bindings[name] = term
            }
            return SPARQLResultSolution<Term>(bindings: bindings)
        }
        
        return AnyIterator {
            if let r = numericIterator.next() {
                return r
            } else {
                return termIterator.next()
            }
        }
    }
    
    public func evaluateWindow(algebra child: Algebra, function windowMap: Algebra.WindowFunctionMapping, activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        let i = try self.evaluate(algebra: child, activeGraph: activeGraph)
        var groupBuckets = [String:[SPARQLResultSolution<Term>]]()
        let application = windowMap.windowApplication
        let partitions = application.partition
        for result in i {
            let group = partitions.map { (expr) -> Term? in return try? self.ee.evaluate(expression: expr, result: result) }
            let groupKey = "\(group)"
            if groupBuckets[groupKey] == nil {
                groupBuckets[groupKey] = [result]
                var bindings = [String:Term]()
                for (g, term) in zip(partitions, group) {
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
        let f = application.windowFunction
        let comparators = application.comparators
        let frame = application.frame
        guard frame.type == .rows else {
            throw QueryError.evaluationError("RANGE window frames are not implemented")
        }
        
        let name = windowMap.variableName
        let results = try groups.map { (results) -> [SPARQLResultSolution<Term>] in
            var newResults = [SPARQLResultSolution<Term>]()
            let sorted = comparators.isEmpty ? results : evaluateSort(results, comparators: comparators)

            switch f {
            case .aggregation(let agg):
                do {
                    var w = try frame.startRowsRange()
                    for result in sorted {
                        let range = w.indices(relativeTo: sorted)
                        let group = sorted[range]
                        var r = result
                        if let term = self.evaluateAggregation(agg, group: group) {
                            try? r.extend(variable: name, value: term)
                        }
                        newResults.append(r)
                        w.slide(by: 1)
                    }
                } catch {}
            case .rowNumber:
                // ROW_NUMBER ignores any specified window frame
                for (n, result) in sorted.enumerated() {
                    var r = result
                    try? r.extend(variable: name, value: Term(integer: n+1))
                    newResults.append(r)
                }
            case .rank, .denseRank:
                // RANK ignores any specified window frame
                if sorted.count > 0 {
                    var increment = 1
                    var last = sorted.first!
                    var n = 0
                    
                    try? last.extend(variable: name, value: Term(integer: n+1))
                    newResults.append(last)
                    
                    for result in sorted.dropFirst() {
                        var r = result
                        if !resultsAreEqual(r, last, usingComparators: comparators) {
                            n += increment
                            increment = 1
                        } else if application.windowFunction == .rank {
                            increment += 1
                        }
                        try? r.extend(variable: name, value: Term(integer: n+1))
                        newResults.append(r)
                        last = result
                    }
                }
            case .ntile(let n):
                // NTILE ignores any specified window frame
                if sorted.count > 0 {
                    var last = sorted.first!
                    
                    var row = 1
                    try? last.extend(variable: name, value: Term(integer: 1))
                    newResults.append(last)
                    
                    for result in sorted.dropFirst() {
                        var r = result
                        if !resultsAreEqual(r, last, usingComparators: comparators) {
                            row += 1
                        }
                        
                        let peerGroupsCount = Set(sorted.map { self.comparisonTerms(from: $0, using: comparators) }).count
                        let nSize = peerGroupsCount / n
                        let nLarge = peerGroupsCount - n*nSize
                        let iSmall = nLarge * (nSize+1)
                        let iRow = row-1
                        let q: Int
                        if iRow < iSmall {
                            q = 1 + iRow/(nSize+1)
                        } else {
                            q = 1 + nLarge + (iRow-iSmall)/nSize
                        }
                        
                        try? r.extend(variable: name, value: Term(integer: q))
                        newResults.append(r)
                        last = result
                    }
                }
            case .custom(_, _):
                throw QueryError.evaluationError("Extension window functions are not supported")
            }
            
            return newResults
        }
        groups = results
        
        let windowResults = groups.flatMap { $0 }
        return AnyIterator(windowResults.makeIterator())
    }
    
    internal func alp(term: Term, path: PropertyPath, graph: Term) throws -> AnyIterator<Term> {
        var v = Set<Term>()
        try alp(term: term, path: path, seen: &v, graph: graph)
        return AnyIterator(v.makeIterator())
    }

    internal func alp(term: Term, path: PropertyPath, seen: inout Set<Term>, graph: Term) throws {
        var termBuffer = [term]
        while !termBuffer.isEmpty {
            let term = termBuffer.removeLast()
            guard !seen.contains(term) else { continue }
            seen.insert(term)
            let pvar = freshVariable()
            for result in try evaluatePath(subject: .bound(term), object: pvar, graph: graph, path: path) {
                if let n = result[pvar] {
                    termBuffer.append(n)
                }
            }
        }
    }
    
    public func evaluatePath(subject: Node, object: Node, graph: Term, path: PropertyPath) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        switch path {
        case .link(let predicate):
            let quad = QuadPattern(subject: subject, predicate: .bound(predicate), object: object, graph: .bound(graph))
            return try evaluate(quad: quad)
        case .inv(let ipath):
            return try evaluatePath(subject: object, object: subject, graph: graph, path: ipath)
        case .nps(let iris):
            return try evaluateNPS(subject: subject, object: object, graph: graph, not: iris)
        case let .alt(lhs, rhs):
            let i = try evaluatePath(subject: subject, object: object, graph: graph, path: lhs)
            let j = try evaluatePath(subject: subject, object: object, graph: graph, path: rhs)
            var iters = [i, j]
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
            
        case let .seq(lhs, rhs):
            let jvar = freshVariable()
            guard case .variable(let jvarname, _) = jvar else {
                Logger.shared.error("Unexpected variable generated during path evaluation")
                throw QueryError.evaluationError("Unexpected variable generated during path evaluation")
            }
            let lhsIter = try evaluatePath(subject: subject, object: jvar, graph: graph, path: lhs)
            let rhsIter = try evaluatePath(subject: jvar, object: object, graph: graph, path: rhs)
            let i = pipelinedHashJoin(joinVariables: [jvarname], lhs: lhsIter, rhs: rhsIter)
                .map { $0.removing(variables: Set([jvarname])) }
            return AnyIterator(i.makeIterator())
        case .plus(let pp):
            switch (subject, object) {
            case (.bound, .variable(let oname, binding: _)):
                let pvar = freshVariable()
                var v = Set<Term>()
                for result in try evaluatePath(subject: subject, object: pvar, graph: graph, path: pp) {
                    if let n = result[pvar] {
                        try alp(term: n, path: pp, seen: &v, graph: graph)
                    }
                }
                
                var i = v.makeIterator()
                return AnyIterator {
                    guard let t = i.next() else { return nil }
                    let r = SPARQLResultSolution<Term>(bindings: [oname: t])
                    return r
                }
            case (.variable, .bound):
                let ipath: PropertyPath = .plus(.inv(pp))
                return try evaluatePath(subject: object, object: subject, graph: graph, path: ipath)
            case (.bound, .bound(let oterm)):
                let pvar = freshVariable()
                var v = Set<Term>()
                for result in try evaluatePath(subject: subject, object: pvar, graph: graph, path: pp) {
                    if let n = result[pvar] {
                        try alp(term: n, path: pp, seen: &v, graph: graph)
                    }
                }
                
                var results = [SPARQLResultSolution<Term>]()
                if v.contains(oterm) {
                    results.append(SPARQLResultSolution<Term>(bindings: [:]))
                }
                return AnyIterator(results.makeIterator())
            case (.variable(let sname, binding: _), .variable):
                var results = [SPARQLResultSolution<Term>]()
                for t in evaluateGraphTerms(in: graph) {
                    let i = try evaluatePath(subject: .bound(t), object: object, graph: graph, path: pp)
                    let j = i.map {
                        $0.extended(variable: sname, value: t) ?? $0
                    }
                    results.append(contentsOf: j)
                }
                return AnyIterator(results.makeIterator())
            }
        case .star(let pp):
            switch (subject, object) {
            case (.bound(let t), .variable(let oname, binding: _)):
                let i = try alp(term: t, path: pp, graph: graph)
                return AnyIterator {
                    guard let o = i.next() else { return nil }
                    let r = SPARQLResultSolution<Term>(bindings: [oname: o])
                    return r
                }
            case (.variable, .bound):
                let ipath: PropertyPath = .star(.inv(pp))
                return try evaluatePath(subject: object, object: subject, graph: graph, path: ipath)
            case (.bound(let t), .bound(let oterm)):
                var v = Set<Term>()
                try alp(term: t, path: path, seen: &v, graph: graph)
                
                var results = [SPARQLResultSolution<Term>]()
                if v.contains(oterm) {
                    results.append(SPARQLResultSolution<Term>(bindings: [:]))
                }
                return AnyIterator(results.makeIterator())
            case let (.variable(sname, binding: _), .variable):
                var results = [SPARQLResultSolution<Term>]()
                for t in evaluateGraphTerms(in: graph) {
                    let i = try evaluatePath(subject: .bound(t), object: object, graph: graph, path: path)
                    let j = i.map {
                        $0.extended(variable: sname, value: t) ?? $0
                    }
                    results.append(contentsOf: j)
                }
                return AnyIterator(results.makeIterator())
            }
        case .zeroOrOne(let pp):
            switch (subject, object) {
            case (.bound(let x), .variable(let oname, binding: _)):
                // eval(Path(X:term, ZeroOrOnePath(P), Y:var)) = { (Y, yn) | yn = X or {(Y, yn)} in eval(Path(X,P,Y)) }
                var results = Set<SPARQLResultSolution<Term>>()
                results.insert(SPARQLResultSolution<Term>(bindings: [oname: x]))
                let i = try evaluatePath(subject: subject, object: object, graph: graph, path: pp)
                results.formUnion(i)
                return AnyIterator(results.makeIterator())
            case (.variable(let sname, binding: _), .bound(let y)):
                // eval(Path(X:var, ZeroOrOnePath(P), Y:term)) = { (X, xn) | xn = Y or {(X, xn)} in eval(Path(X,P,Y)) }
                var results = Set<SPARQLResultSolution<Term>>()
                results.insert(SPARQLResultSolution<Term>(bindings: [sname: y]))
                let i = try evaluatePath(subject: subject, object: object, graph: graph, path: pp)
                results.formUnion(i)
                return AnyIterator(results.makeIterator())
            case (.bound(let s), .bound(let o)) where s == o:
                let results = [SPARQLResultSolution<Term>(bindings: [:])]
                return AnyIterator(results.makeIterator())
            case (.bound, .bound):
                // eval(Path(X:term, ZeroOrOnePath(P), Y:term)) =
                //     { {} } if X = Y or eval(Path(X,P,Y)) is not empty
                //     { } othewise
                var results = [SPARQLResultSolution<Term>]()
                let i = try evaluatePath(subject: subject, object: object, graph: graph, path: pp)
                if let _ = i.next() {
                    results.append(SPARQLResultSolution<Term>(bindings: [:]))
                }
                return AnyIterator(results.makeIterator())
            case (.variable(let sname, binding: _), .variable(let oname, binding: _)):
                // eval(Path(X:var, ZeroOrOnePath(P), Y:var)) = { (X, xn) (Y, yn) | either (yn in nodes(G) and xn = yn) or {(X,xn), (Y,yn)} in eval(Path(X,P,Y)) }
                var results = [SPARQLResultSolution<Term>]()
                for t in evaluateGraphTerms(in: graph) {
                    results.append(SPARQLResultSolution<Term>(bindings: [sname: t, oname: t]))
                }
                let i = try evaluatePath(subject: subject, object: object, graph: graph, path: pp)
                results.append(contentsOf: i)
                return AnyIterator(results.makeIterator())
            }
        }
    }
    
    internal func evaluateNPS(subject: Node, object: Node, graph: Term, not iris: [Term]) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        let predicate = self.freshVariable()
        let quad = QuadPattern(subject: subject, predicate: predicate, object: object, graph: .bound(graph))
        let i = try evaluate(quad: quad)
        // OPTIMIZE: this can be made more efficient by adding an NPS function to the store,
        //           and allowing it to do the filtering based on a SPARQLResultSolution<UInt64> objects before
        //           materializing the terms
        let set = Set(iris)
        var keys = Set<String>()
        for node in [subject, object] {
            if case .variable(let name, true) = node {
                keys.insert(name)
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
    
    public func evaluateAggregation(algebra child: Algebra, groups: [Expression], aggregations aggs: Set<Algebra.AggregationMapping>, activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        let i = try self.evaluate(algebra: child, activeGraph: activeGraph)
        var groupBuckets = [String:[SPARQLResultSolution<Term>]]()
        var groupBindings = [String:[String:Term]]()
        
        for result in i {
            let group = groups.map { (expr) -> Term? in return try? self.ee.evaluate(expression: expr, result: result) }
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
        if groups.count == 0 && groupBuckets.count == 0 {
            groupBuckets[""] = []
            groupBindings[""] = [:]
        }
        var a = groupBuckets.makeIterator()
        return AnyIterator { () -> SPARQLResultSolution<Term>? in
            guard let pair = a.next() else { return nil }
            let (groupKey, results) = pair
            guard var bindings = groupBindings[groupKey] else {
                Logger.shared.error("Unexpected missing aggregation group template")
                fatalError("Unexpected missing aggregation group template")
            }
            for aggMap in aggs {
                let agg = aggMap.aggregation
                let name = aggMap.variableName
                if let term = self.evaluateAggregation(agg, group: results) {
                    bindings[name] = term
                }
            }
            return SPARQLResultSolution<Term>(bindings: bindings)
        }
    }
    
    private func comparisonTerms(from term: SPARQLResultSolution<Term>, using comparators: [Algebra.SortComparator]) -> [Term?] {
        let terms = comparators.map { (cmp) -> Term? in
            return try? self.ee.evaluate(expression: cmp.expression, result: term)
        }
        return terms
    }
    
    public func resultsAreEqual(_ a : SPARQLResultSolution<Term>, _ b : SPARQLResultSolution<Term>, usingComparators comparators: [Algebra.SortComparator]) -> Bool {
        if comparators.isEmpty {
            return a == b
        }
        for cmp in comparators {
            guard var lhs = try? self.ee.evaluate(expression: cmp.expression, result: a) else { return true }
            guard var rhs = try? self.ee.evaluate(expression: cmp.expression, result: b) else { return false }
            if !cmp.ascending {
                (lhs, rhs) = (rhs, lhs)
            }
            if lhs < rhs {
                return false
            } else if lhs > rhs {
                return false
            }
        }
        return true
    }
    
    public func evaluateSort<S: Sequence>(_ results: S, comparators: [Algebra.SortComparator]) -> [SPARQLResultSolution<Term>] where S.Element == SPARQLResultSolution<Term> {
        let elements = results.map { (r) -> SortElem in
            let terms = comparators.map { (cmp) in
                try? self.ee.evaluate(expression: cmp.expression, result: r)
            }
            return SortElem(result: r, terms: terms)
        }
        
        let sorted = elements.sorted { (a, b) -> Bool in
            let pairs = zip(a.terms, b.terms)
            
            for (cmp, pair) in zip(comparators, pairs) {
                if (pair.0 == pair.1) { continue }
                guard let lhs = pair.0 else { return true }
                guard let rhs = pair.1 else { return false }

                var sorted = lhs < rhs
                if !cmp.ascending {
                    sorted = !sorted
                }
                return sorted
            }
            return false
        }
        
        return sorted.map { $0.result }
    }
    
    public func evaluate(bgp patterns: [TriplePattern], activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        let bgp: Algebra = .bgp(patterns)
        let projection = bgp.inscope
        let triples : [Algebra] = patterns.map { $0.bindingAllVariables }.map { .triple($0) }
        let join: Algebra = triples.reduce(.joinIdentity) { .innerJoin($0, $1) }
        let algebra: Algebra = .project(join, projection)
        return try evaluate(algebra: algebra, activeGraph: activeGraph)
    }
    
    public func triples<S : Sequence>(describing node: Node, from results: S) throws -> AnyIterator<Triple> where S.Element == SPARQLResultSolution<Term> {
        switch node {
        case .bound(let term):
            return try triples(describing: term)
        case .variable(let name, binding: _):
            let iters = try results.compactMap { (result) throws -> AnyIterator<Triple>? in
                if let term = result[name] {
                    return try triples(describing: term)
                } else {
                    return nil
                }
            }
            return AnyIterator(iters.joined().makeIterator())
        }
    }
    
    public func triples<S : Sequence>(from results: S, with template: [TriplePattern]) -> [Triple] where S.Element == SPARQLResultSolution<Term> {
        var triples = Set<Triple>()
        for r in results {
            for tp in template {
                do {
                    let replaced = try tp.replace { (n) -> Node? in
                        guard case .variable(let name, _) = n else { return nil }
                        if let t = r[name] {
                            return .bound(t)
                        }
                        return nil
                    }
                    if let ground = replaced.ground {
                        triples.insert(ground)
                    }
                } catch {}
            }
        }
        return Array(triples)
    }
}

open class SimpleQueryEvaluator<Q: QuadStoreProtocol>: SimpleQueryEvaluatorProtocol {
    public var store: Q
    public var dataset: Dataset
    public var ee: ExpressionEvaluator
    public let supportedLanguages: [QueryLanguage] = [.sparqlQuery10, .sparqlQuery11]
    public let supportedFeatures: [QueryEngineFeature] = [.basicFederatedQuery]

    internal var freshVarNumber: Int
    public var verbose: Bool

    public init(store: Q, dataset: Dataset, verbose: Bool = false) {
        self.store = store
        self.dataset = dataset
        self.freshVarNumber = 1
        self.verbose = verbose
        self.ee = ExpressionEvaluator()
    }
    
    convenience public init(store: Q, defaultGraph: Term, verbose: Bool = false) {
        let dataset = store.dataset(withDefault: defaultGraph)
        self.init(store: store, dataset: dataset, verbose: verbose)
    }
    
    public func freshVariable() -> Node {
        let n = freshVarNumber
        freshVarNumber += 1
        return .variable(".v\(n)", binding: true)
    }
    
    public func triples(describing term: Term) throws -> AnyIterator<Triple> {
        let qp = QuadPattern(
            subject: .bound(term),
            predicate: .variable("p", binding: true),
            object: .variable("o", binding: true),
            graph: .variable("g", binding: true))
        let quads = try store.quads(matching: qp)
        let triples = quads.map { $0.triple }
        return AnyIterator(triples.makeIterator())
    }
    
    
    public func evaluate(bgp patterns: [TriplePattern], activeGraph: Term) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        if let s = store as? BGPQuadStoreProtocol {
            return try s.results(matching: patterns, in: activeGraph)
        } else {
            let bgp: Algebra = .bgp(patterns)
            let projection = bgp.inscope
            let triples : [Algebra] = patterns.map { $0.bindingAllVariables }.map { .triple($0) }
            let join: Algebra = triples.reduce(.joinIdentity) { .innerJoin($0, $1) }
            let algebra: Algebra = .project(join, projection)

            let a = try SPARQLQueryRewriter.shared.simplify(algebra: algebra)
            return try evaluate(algebra: a, activeGraph: activeGraph)
        }
    }
    
    public func evaluate(quad: QuadPattern) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        return try store.results(matching: quad)
    }

    public func effectiveVersion(matching query: Query) throws -> Version? {
        let algebra = query.algebra
        var version : Version? = nil
        for activeGraph in dataset.defaultGraphs {
            guard let mtime = try effectiveVersion(matching: algebra, activeGraph: activeGraph) else { return nil }
            if case .describe(let nodes) = query.form {
                for node in nodes {
                    let quad = QuadPattern(subject: node, predicate: .variable("p", binding: true), object: .variable("o", binding: true), graph: .bound(activeGraph))
                    guard let qmtime = try store.effectiveVersion(matching: quad) else { return nil }
                    if let v = version {
                        version = max(v, mtime, qmtime)
                    } else {
                        version = max(mtime, qmtime)
                    }
                }
            } else {
                if let v = version {
                    version = max(v, mtime)
                } else {
                    version = mtime
                }
            }
        }
        return version
    }
    
    public func effectiveVersion(algebra child: Algebra, inGraph graph: Node) throws -> Version? {
        guard case .variable = graph else {
            Logger.shared.error("Unexpected variable found during named graph evaluation")
            throw QueryError.evaluationError("Unexpected variable found during named graph evaluation")
        }
        let defaultGraphs = Set(dataset.defaultGraphs)
        let x = try store.graphs().filter { !defaultGraphs.contains($0) }.map { ($0, try effectiveVersion(matching: child, activeGraph: $0)) }.compactMap { $0.1 }
        guard !x.isEmpty else { return nil }
        let v = x.reduce(x.first!) { max($0, $1) }
        return v
    }

    public func effectiveVersion(matching algebra: Algebra, activeGraph: Term) throws -> Version? {
        switch algebra {
        // don't require access to the underlying store:
        case .joinIdentity, .unionIdentity:
            return 0
        case .table(_, _):
            return 0
        case let .innerJoin(lhs, rhs), let .leftOuterJoin(lhs, rhs, _), let .union(lhs, rhs), let .minus(lhs, rhs):
            guard let lhsmtime = try effectiveVersion(matching: lhs, activeGraph: activeGraph) else { return nil }
            guard let rhsmtime = try effectiveVersion(matching: rhs, activeGraph: activeGraph) else { return lhsmtime }
            return max(lhsmtime, rhsmtime)
        case let .namedGraph(child, graph):
            if case .bound(let g) = graph {
                return try effectiveVersion(matching: child, activeGraph: g)
            } else {
                return try effectiveVersion(algebra: child, inGraph: graph)
            }
        case .distinct(let child), .reduced(let child), .project(let child, _), .slice(let child, _, _), .extend(let child, _, _), .order(let child, _), .filter(let child, _):
            return try effectiveVersion(matching: child, activeGraph: activeGraph)
        case .aggregate(let child, _, _):
            return try effectiveVersion(matching: child, activeGraph: activeGraph)
        case .window(let child, _):
            return try effectiveVersion(matching: child, activeGraph: activeGraph)
        case .service:
            return nil
        case .triple(let t):
            let quad = QuadPattern(subject: t.subject, predicate: t.predicate, object: t.object, graph: .bound(activeGraph))
            return try effectiveVersion(matching: .quad(quad), activeGraph: activeGraph)
            
            
        // requires access to the underlying store:
        case .path(_, _, _):
            let s: Node = .variable("s", binding: true)
            let p: Node = .variable("p", binding: true)
            let o: Node = .variable("o", binding: true)
            let quad = QuadPattern(subject: s, predicate: p, object: o, graph: .bound(activeGraph))
            return try store.effectiveVersion(matching: quad)
        case .quad(let quad):
            return try store.effectiveVersion(matching: quad)
        case .bgp(let children):
            guard children.count > 0 else { return nil }
            var mtime: Version = 0
            for t in children {
                let quad = QuadPattern(subject: t.subject, predicate: t.predicate, object: t.object, graph: .bound(activeGraph))
                guard let triplemtime = try store.effectiveVersion(matching: quad) else { continue }
                mtime = max(mtime, triplemtime)
            }
            return mtime
        case .subquery(let q):
            return try effectiveVersion(matching: q)
        }
    }

    public func evaluate(algebra child: Algebra, inGraph graph: Node) throws -> AnyIterator<SPARQLResultSolution<Term>> {
        guard case .variable(let gv, let bind) = graph else {
            Logger.shared.error("Unexpected variable found during named graph evaluation")
            throw QueryError.evaluationError("Unexpected variable found during named graph evaluation")
        }
        let defaultGraphs = Set(dataset.defaultGraphs)
        var iters = try store.graphs().filter { !defaultGraphs.contains($0) }.map { ($0, try evaluate(algebra: child, activeGraph: $0)) }
        return AnyIterator {
            repeat {
                if iters.count == 0 {
                    return nil
                }
                let (graph, i) = iters[0]
                guard var result = i.next() else { iters.remove(at: 0); continue }
                if bind {
                    do {
                        try result.extend(variable: gv, value: graph)
                    } catch {
                        continue
                    }
                }
                return result
            } while true
        }
    }

    public func evaluateGraphTerms(in graph: Term) -> AnyIterator<Term> {
        return store.graphTerms(in: graph)
    }
}

public func pipelinedHashJoin<R: ResultProtocol>(boundJoinVariables joinVariables: Set<String>, lhs: AnyIterator<R>, rhs: AnyIterator<R>, left: Bool = false) -> AnyIterator<R> {
    // This version differs from pipelinedHashJoin(joinVariables:lhs:rhs:left:) in that the join variables are guaranteed to be bound; thus, we don't have to worry about handling results that are compatible, but don't have all the join variables bound.
    let pairs = rhs.map { (result) -> (R,[R]) in
        let key = result.projected(variables: joinVariables)
        return (key, [result])
    }
    let table = Dictionary(pairs) { $0 + $1 }
    var buffer = [R]()
    return AnyIterator {
        repeat {
            if buffer.count > 0 {
                let r = buffer.remove(at: 0)
                return r
            }
            guard let result = lhs.next() else { return nil }
            var joined = false
            let bucket = result.projected(variables: joinVariables)
            if let results = table[bucket] {
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

public func pipelinedHashJoin<R: ResultProtocol>(joinVariables: Set<String>, lhs: AnyIterator<R>, rhs: AnyIterator<R>, left: Bool = false) -> AnyIterator<R> {
    var table = [R:[R]]()
    var unboundTable = [R]()
//    warn(">>> filling hash table")
    var count = 0
    for result in rhs {
        count += 1
        let key = result.projected(variables: joinVariables)
        if key.keys.count != joinVariables.count {
            unboundTable.append(result)
        } else {
            if let results = table[key] {
                table[key] = results + [result]
            } else {
                table[key] = [result]
            }
        }
    }
//    warn(">>> done (\(count) results in \(Array(table.keys).count) buckets)")

    var buffer = [R]()
    return AnyIterator {
        repeat {
            if buffer.count > 0 {
                let r = buffer.remove(at: 0)
                return r
            }
            guard let result = lhs.next() else { return nil }
            var joined = false
            let key = result.projected(variables: joinVariables)
            var buckets = [R]()
            if key.keys.count != joinVariables.count {
                for bucket in table.keys {
                    if let _ = bucket.join(result) {
                        buckets.append(bucket)
                    }
                }
            } else {
                buckets.append(key)
            }
            for bucket in buckets {
                if let results = table[bucket] {
                    for lhs in results {
                        if let j = lhs.join(result) {
                            joined = true
                            buffer.append(j)
                        }
                    }
                }
            }
            for lhs in unboundTable {
                if let j = lhs.join(result) {
                    joined = true
                    buffer.append(j)
                }
            }
            if left && !joined {
                buffer.append(result)
            }
        } while true
    }
}

public func nestedLoopJoin<R: ResultProtocol>(_ results: [[R]], left: Bool = false, cb callback: (R) -> ()) {
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
                        callback(j)
                    } else {
                        joinedResults.append(j)
                    }
                }
            }
            if left && !joined {
                if finalPass {
                    callback(lresult)
                } else {
                    joinedResults.append(lresult)
                }
            }
        }
        patternResults.append(joinedResults)
    }
}
