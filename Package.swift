// swift-tools-version:5.2
import PackageDescription

let package = Package(
    name: "Kineo",
    platforms: [.macOS(.v10_15)],
	products: [
		.library(name: "Kineo", targets: ["Kineo"])
	],    
    dependencies: [
		.package(name: "SPARQLSyntax", url: "https://github.com/kasei/swift-sparql-syntax.git", .upToNextMinor(from: "0.1.1")),
		.package(name: "Cserd", url: "https://github.com/kasei/swift-serd.git", .upToNextMinor(from: "0.0.4")),
		.package(name: "CryptoSwift", url: "https://github.com/krzyzanowskim/CryptoSwift.git", .upToNextMinor(from: "1.0.0")),
		.package(name: "URITemplate", url: "https://github.com/kylef/URITemplate.swift.git", .upToNextMinor(from: "3.0.0")),
		.package(name: "SQLite.swift", url: "https://github.com/stephencelis/SQLite.swift.git", .upToNextMinor(from: "0.11.5")),
    ],
    targets: [
    	.target(
    		name: "Kineo",
			dependencies: [
				"CryptoSwift",
				"SPARQLSyntax",
				"URITemplate",
				.product(name: "serd", package: "Cserd"),
				.product(name: "SQLite", package: "SQLite.swift"),
			]
    	),
        .target(
            name: "kineo-dawg-test",
            dependencies: ["Kineo", "SPARQLSyntax"]
        ),
        .target(
            name: "kineo-test",
            dependencies: ["Kineo", "SPARQLSyntax"]
        ),
        .testTarget(name: "KineoTests", dependencies: ["Kineo"])
    ]
)
