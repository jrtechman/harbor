import SwiftUI

/// Drop-in replacement for @State that doesn't need the SwiftUI macro plugin
/// (which only ships with full Xcode, not the Command Line Tools).
@propertyWrapper
struct Local<Value>: DynamicProperty {
    final class Box: ObservableObject {
        @Published var value: Value
        init(_ v: Value) { value = v }
    }
    @StateObject private var box: Box
    init(wrappedValue: Value) { _box = StateObject(wrappedValue: Box(wrappedValue)) }
    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
    var projectedValue: Binding<Value> {
        let b = box
        return Binding(get: { b.value }, set: { b.value = $0 })
    }
}
