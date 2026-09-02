import Foundation
import Testing
@testable import MClashApp
import MClashNetworkShared

@Suite("Connector-neutral flow observations")
struct MihomoFlowObservationAdapterTests {
    @Test("projects legacy connection fields without losing route evidence")
    func projectsConnection() throws {
        let data = Data(
            #"{
              "id":"legacy-1",
              "metadata":{
                "network":"tcp",
                "destinationIP":"1.1.1.1",
                "destinationPort":"443",
                "host":"example.com",
                "process":"Safari",
                "processPath":"/Applications/Safari.app/Contents/MacOS/Safari",
                "inboundName":"mixed-in"
              },
              "upload":-4,
              "download":12,
              "start":"2026-07-16T08:00:00.123456+08:00",
              "chains":["CUNOE-Proxy","US-01"],
              "providerChains":["provider-a"],
              "rule":"DOMAIN-SUFFIX",
              "rulePayload":"example.com"
            }"#.utf8
        )
        let connection = try JSONDecoder().decode(MihomoConnection.self, from: data)
        let observation = MihomoFlowObservationAdapter.observation(
            for: connection,
            state: .completed,
            endedAt: Date(timeIntervalSince1970: 123)
        )

        #expect(observation.id == "legacy-1")
        #expect(observation.destinationHost == "example.com")
        #expect(observation.destinationIP == "1.1.1.1")
        #expect(observation.destinationPort == 443)
        #expect(observation.process == "Safari")
        #expect(observation.routeChain == ["CUNOE-Proxy", "US-01"])
        #expect(observation.providerChain == ["provider-a"])
        #expect(observation.connector == "US-01")
        #expect(observation.uploadBytes == 0)
        #expect(observation.downloadBytes == 12)
        #expect(observation.state == .completed)
        #expect(observation.route == .relay)
        #expect(observation.endedAt == Date(timeIntervalSince1970: 123))
    }

    @Test("native observations are serializable for future runtime transport")
    func roundTripsNativeObservation() throws {
        let source = FlowRelayObservation(
            id: "native-1",
            network: "udp",
            destinationHost: "api.example.com",
            destinationPort: 443,
            connector: "hysteria2",
            uploadBytes: 7,
            downloadBytes: 9,
            state: .active,
            route: .relay
        )
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(FlowRelayObservation.self, from: data)
        #expect(decoded == source)
    }
}
