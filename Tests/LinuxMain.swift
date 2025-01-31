import XCTest
@testable import KineoTests

XCTMain([
	testCase(ConfigurationTest.allTests),
	testCase(GraphAPITest.allTests),
	testCase(LanguageMemoryQuadStoreTest.allTests),
	testCase(NTriplesSerializationTest.allTests),
	testCase(QuadStoreGraphDescriptionTest.allTests),
	testCase(QueryEvaluationPerformanceTest.allTests),
	testCase(QueryParserTest.allTests),
	testCase(QueryRewritingTest.allTests),
	testCase(SerializationPerformanceTest.allTests),
	testCase(TestStore_SimpleQueryEvaluationTest.allTests),
	testCase(TestStore_QueryPlanEvaluationTest.allTests),
	testCase(SPARQLContentNegotiatorTest.allTests),
	testCase(MemoryStore_SPARQLEvaluationTest.allTests),
	testCase(MemoryStore_SPARQLEvaluationTest.allTests),
	testCase(SPARQLJSONSyntaxTest.allTests),
	testCase(SPARQLSyntaxTest.allTests),
	testCase(SPARQLTSVSyntaxParserTest.allTests),
	testCase(SPARQLTSVSyntaxSerializerTest.allTests),
	testCase(SPARQLXMLSyntaxTest.allTests),
	testCase(TermIdentityMapTest.allTests),
	testCase(TurtleSerializationTest.allTests),
])
