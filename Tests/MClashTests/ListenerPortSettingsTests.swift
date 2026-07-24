import Testing
@testable import MClashApp

@Suite("Listener port settings")
struct ListenerPortSettingsTests {
    @Test("Mixed profile and custom modes disable separate listeners")
    func producesOverrideSemantics() {
        var draft = ListenerPortSettingsDraft(
            overrides: RuntimePortOverrides(),
            profileMixedPort: nil
        )

        draft.mixed.mode = .custom
        draft.mixed.customValue = "19081"

        let applied = draft.applying(to: .empty)
        #expect(applied.ports.port == 0)
        #expect(applied.ports.socksPort == 0)
        #expect(applied.ports.mixedPort == 19_081)
    }

    @Test("Invalid custom ports remain visible as field-specific errors")
    func rejectsInvalidCustomPorts() {
        var draft = ListenerPortSettingsDraft(
            overrides: RuntimePortOverrides(),
            profileMixedPort: nil
        )
        draft.mixed.mode = .custom
        draft.mixed.customValue = "70000"

        #expect(draft.validationMessage == "Mixed: Enter a port from 1 to 65535.")
    }

    @Test("Editing common listeners preserves advanced runtime overrides")
    func preservesAdvancedOverrides() {
        let original = RuntimeOverrides(
            ports: RuntimePortOverrides(redirPort: 7_892, tproxyPort: 7_893),
            allowLAN: true,
            ipv6: false,
            sniffing: true,
            logLevel: "warning",
            prependRules: ["MATCH,DIRECT"]
        )
        var draft = ListenerPortSettingsDraft(
            overrides: original.ports,
            profileMixedPort: nil
        )
        draft.mixed.mode = .custom
        draft.mixed.customValue = "17892"

        let updated = draft.applying(to: original)
        #expect(updated.ports.mixedPort == 17_892)
        #expect(updated.ports.redirPort == 7_892)
        #expect(updated.ports.tproxyPort == 7_893)
        #expect(updated.allowLAN == true)
        #expect(updated.ipv6 == false)
        #expect(updated.sniffing == true)
        #expect(updated.logLevel == "warning")
        #expect(updated.prependRules == ["MATCH,DIRECT"])
    }

    @Test("Resetting the common listeners does not clear their draft context")
    func resetsToProfile() {
        var draft = ListenerPortSettingsDraft(
            overrides: RuntimePortOverrides(port: 18_080, socksPort: 18_081, mixedPort: 18_082),
            profileMixedPort: nil
        )

        draft.useProfileForAll()

        #expect(draft.mixed.mode == .profile)
        let applied = draft.applying(to: RuntimeOverrides(ports: RuntimePortOverrides(
            port: 18_080,
            socksPort: 18_081,
            mixedPort: 18_082
        )))
        #expect(applied.ports.port == 0)
        #expect(applied.ports.socksPort == 0)
        #expect(applied.ports.mixedPort == nil)
    }

    @Test("Advanced reset can preserve only common listener ports")
    func advancedResetPreservesOnlyCommonPorts() {
        let original = RuntimePortOverrides(
            port: 7_890,
            socksPort: 7_891,
            redirPort: 7_892,
            tproxyPort: 7_893,
            mixedPort: 7_894
        )
        let common = RuntimePortOverrides(
            port: original.port,
            socksPort: original.socksPort,
            mixedPort: original.mixedPort
        )

        #expect(common.port == 7_890)
        #expect(common.socksPort == 7_891)
        #expect(common.mixedPort == 7_894)
        #expect(common.redirPort == nil)
        #expect(common.tproxyPort == nil)
    }
}
