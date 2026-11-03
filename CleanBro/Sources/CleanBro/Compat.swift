import SwiftUI

/// The macOS 27 SDK declares `@State` as a macro whose plugin ships only with
/// full Xcode. Using the property wrapper through an alias keeps the app
/// buildable with the Command Line Tools alone.
typealias StateVar<Value> = SwiftUI.State<Value>
