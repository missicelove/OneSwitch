import SwiftUI

/// Use `@ViewState` instead of `@State` everywhere in this project.
///
/// In the macOS 27 SDK, SwiftUI's `@State` is an attached macro implemented by the `SwiftUIMacros`
/// compiler plugin, which ships only with Xcode — not with the Command Line Tools this project builds
/// with. Referring to the underlying `State` property-wrapper struct through a typealias bypasses the
/// macro and behaves exactly like classic `@State`.
///
/// Also unavailable without Xcode: `#Preview`, `@Previewable`, `@Entry`, `@Animatable`.
/// Available: `@StateObject`, `@ObservedObject`, `@Binding`, `@Environment`, `@AppStorage`,
/// `@FocusState`, `@Observable` (Observation macros ship with the toolchain).
public typealias ViewState<Value> = SwiftUI.State<Value>
