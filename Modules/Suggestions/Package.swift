// swift-tools-version:6.2
import PackageDescription

let package = Package(
	name: "Suggestions",
	platforms: [.macOS(.v15), .iOS(.v17)],
	products: [
		.library(
			name: "Suggestions",
			type: .dynamic,
			targets: ["Suggestions"])
	],
	dependencies: [
		.package(path: "../RSDatabase"),
		.package(path: "../CloudKitSync")
	],
	targets: [
		.target(
			name: "Suggestions",
			dependencies: [
				"RSDatabase",
				"CloudKitSync"
			],
			swiftSettings: [
				.enableUpcomingFeature("NonisolatedNonsendingByDefault"),
				.enableUpcomingFeature("InferIsolatedConformances"),
				.unsafeFlags(["-warnings-as-errors"])
			]
		),
		.testTarget(
			name: "SuggestionsTests",
			dependencies: ["Suggestions"],
			swiftSettings: [.swiftLanguageMode(.v6)]
		)
	]
)
