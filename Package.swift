// swift-tools-version:4.2
import PackageDescription

let package = Package(
    name: "Kineo",
	products: [
		.library(name: "Kineo", targets: ["Kineo"]),
	],    
    dependencies: [
		.package(url: "https://github.com/kasei/swift-sparql-syntax.git", .branch("sparql-12")),
		.package(url: "https://github.com/kasei/swift-serd.git", .upToNextMinor(from: "0.0.3")),
		.package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", .upToNextMinor(from: "1.0.0")),
		.package(url: "https://github.com/kasei/URITemplate.git", .upToNextMinor(from: "2.0.10")),
//		.package(url: "https://github.com/stephencelis/SQLite.swift.git", .upToNextMajor(from: "0.11.5")),
		.package(url: "https://github.com/kasei/SQLite.swift.git", .branch("fix-swift-4")),
    ],
    targets: [
    	.target(
    		name: "Kineo",
			dependencies: ["CryptoSwift", "SPARQLSyntax", "URITemplate", "serd", "SQLite"]
    	),
        .target(
            name: "kineo-cli",
            dependencies: ["Kineo", "SPARQLSyntax"]
        ),
        .target(
            name: "kineo-client",
            dependencies: ["Kineo", "SPARQLSyntax"]
        ),
        .target(
            name: "kineo-dawg-test",
            dependencies: ["Kineo", "SPARQLSyntax"]
        ),
        .target(
            name: "kineo-parse",
            dependencies: ["Kineo", "SPARQLSyntax"]
        ),
        .target(
            name: "kineo-test",
            dependencies: ["Kineo", "SPARQLSyntax"]
        ),
        .testTarget(name: "KineoTests", dependencies: ["Kineo"])
    ]
)
