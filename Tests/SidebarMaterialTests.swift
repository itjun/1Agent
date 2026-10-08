import Foundation

@main
enum SidebarMaterialTests {
    static func main() {
        let suite = "SidebarMaterialTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(SidebarMaterial.load(from: defaults) == .liquidGlass)
        for material in SidebarMaterial.allCases {
            defaults.set(material.rawValue, forKey: SidebarMaterial.storageKey)
            precondition(SidebarMaterial.load(from: defaults) == material)
            for supported in [false, true] {
                for reduced in [false, true] {
                    let expected: SidebarMaterial = material == .liquidGlass && supported && !reduced ? .liquidGlass : .solid
                    precondition(material.effective(supportsGlass: supported, reduceTransparency: reduced) == expected)
                    // Accessibility and capability fallback never overwrite the user's choice.
                    precondition(SidebarMaterial.load(from: defaults) == material)
                }
            }
        }
        defaults.set("invalid", forKey: SidebarMaterial.storageKey)
        precondition(SidebarMaterial.load(from: defaults) == .defaultValue)
        print("ok: sidebar material defaults, persistence and capability/accessibility fallback")
    }
}
