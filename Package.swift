// swift-tools-version:4.0
import PackageDescription

let package = Package(
    name: "Kineo",
	products: [
		.library(name: "Kineo", targets: ["Kineo"]),
	],    
    dependencies: [
		.package(url: "https://github.com/kasei/swift-sparql-syntax.git", from: "0.0.12"),
		.package(url: "https://github.com/kasei/swift-serd.git", from: "0.0.0"),
		.package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "0.8.0"),
        .package(url: "https://github.com/vapor/vapor.git", from: "3.0.0"),
    ],
    targets: [
    	.target(
    		name: "Kineo",
			dependencies: ["CryptoSwift", "SPARQLSyntax"]
    	),
        .target(
            name: "kineo-cli",
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
            name: "kineo-endpoint",
            dependencies: ["Kineo", "SPARQLSyntax", "Vapor"]
        ),
        .testTarget(name: "KineoTests", dependencies: ["Kineo"])
    ]
)
