import XCTest
import Foundation
import Kineo

// swiftlint:disable type_body_length
class RDFTest: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }
    
    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
        super.tearDown()
    }
    
    func testConstructorInteger() {
        let t = Term(integer: 7)
        XCTAssertEqual(t.value, "7")
    }
    
    func testConstructorDecimal() {
        let t = Term(decimal: 7.1)
        XCTAssertEqual(t.value, "7.100000")
    }
    
    func testConstructorFloat() {
        let t = Term(float: -70.1)
        XCTAssertEqual(t.value, "-7.01E1")
    }
    
    func testConstructorFloat2() {
        let t = Term(float: -0.701, exponent: 1)
        XCTAssertEqual(t.value, "-7.01E0")
    }
    
    func testConstructorDouble() {
        let t = Term(double: 700.1)
        XCTAssertEqual(t.value, "7.001E2")
    }
    
    func testConstructorDouble2() {
        let t = Term(double: 7001.0, exponent: -1)
        XCTAssertEqual(t.value, "7.001E2")
    }
    
    func testConstructorDouble3() {
        let t = Term(double: 0.00123)
        XCTAssertEqual(t.value, "1.23E-3")
    }

}
