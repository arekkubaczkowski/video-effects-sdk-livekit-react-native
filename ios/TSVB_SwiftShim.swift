//  TSVB_SwiftShim.swift
@preconcurrency import TSVB

// This file serves as a Swift module shim for TSVB.xcframework.
// It ensures that CocoaPods generates a proper Swift module target
// named `TSVB-SDK` (Swift import name becomes `TSVB_SDK`).
// It ensures that ExpoModulesProvider.swift can `import TSVB_SDK` successfully.