import SwiftUI

/// `@State` without the `@State` macro, whose compiler plugin ships with Xcode but not with the
/// Command Line Tools. SwiftUI finds the nested `State` like any other dynamic property, so
/// this behaves exactly like `@State` and keeps the project buildable with `swift build` alone.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private let state: State<Value>

    init(wrappedValue: Value) {
        state = State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { state.projectedValue }
}
