import ProjectDescription

// Generate with `tuist generate`. Set DEVELOPMENT_TEAM to your own Apple team ID.
let project = Project(
    name: "Securely",
    targets: [
        .target(
            name: "Securely",
            destinations: .macOS,
            product: .app,
            bundleId: "com.lalomorales22.securely",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Securely",
                "LSMinimumSystemVersion": "14.0",
                "NSRequiresAquaSystemAppearance": false,
            ]),
            sources: ["Sources/Securely/**"],
            entitlements: .file(path: "Securely.entitlements"),
            scripts: [
                .post(
                    script: """
                    set -e
                    OUT="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/securely-mcp"
                    swiftc -O "$SRCROOT/Sources/securely-mcp/main.swift" -o "$OUT"
                    if [ -n "$EXPANDED_CODE_SIGN_IDENTITY" ]; then
                      codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --options runtime "$OUT"
                    fi
                    """,
                    name: "Build and sign securely-mcp",
                    basedOnDependencyAnalysis: false
                ),
            ],
            settings: .settings(base: [
                "DEVELOPMENT_TEAM": "LH4S6Z3VYT",
                "CODE_SIGN_STYLE": "Automatic",
                "CODE_SIGN_IDENTITY": "Apple Development",
                "ENABLE_HARDENED_RUNTIME": "YES",
                "SWIFT_VERSION": "5.0",
                "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
            ])
        ),
    ]
)
