import Testing
@testable import MClashApp

@Suite("Listener port settings")
struct ListenerPortSettingsTests {
    @Test("Profile, custom, and off modes produce explicit override semantics")
    func producesOverrideSemantics() {
        var draft = ListenerPortSettingsDraft(
            overrides: RuntimePortOverrides(),
            profileHTTPPort: 7_890,
            profileSOCKSPort: 7_891,
            profileMixedPort: nil
        )

        draft.http.mode = .profile
        draft.socks.mode = .custom
        draft.socks.customValue = "19081"
        draft.mixed.mode = .off

        let applied = draft.applying(to: .empty)
        #expect(applied.ports.port == nil)
        #expect(applied.ports.socksPort == 19_081)
        #expect(applied.ports.mixedPort == 0)
    }

    @Test("Duplicate enabled listener ports are rejected inline")
    func rejectsDuplicatePorts() {
        var draft = ListenerPortSettingsDraft(
            overrides: RuntimePortOverrides(),
            profileHTTPPort: nil,
            profileSOCKSPort: nil,
            profileMixedPort: nil
        )
        draft.http.mode = .custom
        draft.http.customValue = "18080"
        draft.socks.mode = .off
        draft.mixed.mode = .custom
        draft.mixed.customValue = "18080"

        #expect(draft.validationMessage == "HTTP and Mixed cannot both use port 18080.")
    }

    @Test("Invalid custom ports remain visible as field-specific errors")
    func rejectsInvalidCustomPorts() {
        var draft = ListenerPortSettingsDraft(
            overrides: RuntimePortOverrides(),
            profileHTTPPort: nil,
            profileSOCKSPort: nil,
            profileMixedPort: nil
        )
        draft.http.mode = .custom
        draft.http.customValue = "70000"

        #expect(draft.validationMessage == "HTTP: Enter a port from 1 to 65535.")
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
            profileHTTPPort: 7_890,
            profileSOCKSPort: 7_891,
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
            profileHTTPPort: nil,
            profileSOCKSPort: nil,
            profileMixedPort: nil
        )

        draft.useProfileForAll()

        #expect(draft.http.mode == .profile)
        #expect(draft.socks.mode == .profile)
        #expect(draft.mixed.mode == .profile)
        let applied = draft.applying(to: RuntimeOverrides(ports: RuntimePortOverrides(
            port: 18_080,
            socksPort: 18_081,
            mixedPort: 18_082
        )))
        #expect(applied.ports.port == nil)
        #expect(applied.ports.socksPort == nil)
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
