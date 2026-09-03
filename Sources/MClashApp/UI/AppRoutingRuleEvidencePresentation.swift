import Foundation
import MClashNetworkShared

struct AppRoutingRuleEvidencePresentation: Equatable {
    struct Row: Equatable, Identifiable {
        let title: String
        let value: String

        var id: String { title }
    }

    let summary: String
    let rows: [Row]
    let consequence: String?
    let symbol: String

    static func make(for activity: AppRoutingActivity) -> Self {
        guard let evidence = activity.ruleEvidence else {
            return Self(
                summary: AppLocalization.string(
                    "This activity was recorded before detailed match evidence was available."
                ),
                rows: [],
                consequence: legacyConsequence(for: activity),
                symbol: "questionmark.circle"
            )
        }

        switch evidence.outcome {
        case .matchedRule:
            return Self(
                summary: AppLocalization.string(
                    "These are the exact alternatives that matched inside each rule field. The fields themselves were combined with AND."
                ),
                rows: matchedRows(evidence),
                consequence: nil,
                symbol: "checkmark.seal.fill"
            )
        case .builtInBypass:
            return Self(
                summary: builtInBypassSummary(evidence.builtInBypassReason),
                rows: [],
                consequence: AppLocalization.string(
                    "The built-in safety rule took precedence over user rules and sent the flow Direct."
                ),
                symbol: "shield.checkered"
            )
        case .defaultDirect:
            return Self(
                summary: AppLocalization.string("No enabled App Routing rule matched this flow."),
                rows: [],
                consequence: AppLocalization.string("The built-in default applied Direct routing."),
                symbol: "arrow.right.circle"
            )
        case .captureDisabled:
            return Self(
                summary: AppLocalization.string("App Routing was disabled when this flow arrived."),
                rows: [],
                consequence: AppLocalization.string(
                    "Rules were not evaluated and the flow was handed back to macOS."
                ),
                symbol: "pause.circle"
            )
        case .configurationUnavailable:
            return Self(
                summary: AppLocalization.string(
                    "The Network Extension could not load a validated rule snapshot."
                ),
                rows: [],
                consequence: AppLocalization.string(
                    "Rules were not evaluated and the flow was handed back to macOS (fail-open)."
                ),
                symbol: "doc.badge.exclamationmark"
            )
        case .contextUnavailable:
            return Self(
                summary: contextUnavailableSummary(evidence.contextUnavailableReason),
                rows: [],
                consequence: AppLocalization.string(
                    "The source or destination could not be trusted as complete, so rules were not evaluated and the flow was handed back to macOS (fail-open)."
                ),
                symbol: "person.crop.circle.badge.questionmark"
            )
        }
    }

    private static func matchedRows(_ evidence: CaptureRuleDecisionEvidence) -> [Row] {
        [
            evidence.source.map {
                Row(title: AppLocalization.string("Source"), value: sourceDescription($0))
            },
            evidence.destination.map {
                Row(title: AppLocalization.string("Destination"), value: destinationDescription($0))
            },
            evidence.transportProtocol.map {
                Row(title: AppLocalization.string("Protocol"), value: protocolDescription($0))
            },
            evidence.destinationPort.map {
                Row(title: AppLocalization.string("Port"), value: portDescription($0))
            },
        ].compactMap { $0 }
    }

    private static func sourceDescription(_ source: RuleSourceMatchEvidence) -> String {
        switch source {
        case .unconstrained:
            AppLocalization.string("Any application or process (no source condition)")
        case let .application(application):
            joined(
                AppLocalization.string(
                    "Exact signed application identity (code-signing requirement verified)"
                ),
                labeled("Bundle", application.bundleIdentifier),
                labeled("Signing ID", application.signingIdentifier),
                labeled("Team", application.teamIdentifier)
            )
        case let .applicationIdentifierPattern(pattern):
            AppLocalization.format(
                "Identifier pattern %@ matched the %@; this is a name/pattern match, not an exact signature identity",
                quoted(pattern.pattern),
                fieldName(pattern.matchedField)
            )
        case let .executable(executable):
            joined(
                assuranceDescription(executable.assurance),
                executable.canonicalPath
            )
        case let .processInstance(process):
            joined(
                AppLocalization.format(
                    "Process %@",
                    String(process.processIdentifier)
                ),
                assuranceDescription(process.assurance),
                process.canonicalExecutablePath
            )
        case let .userID(userID):
            AppLocalization.format(
                "Exact user ID %@; this identifies the account, not one signed application",
                String(userID)
            )
        }
    }

    private static func destinationDescription(_ destination: RuleDestinationMatchEvidence) -> String {
        switch destination {
        case .unconstrained:
            AppLocalization.string("Any host or IP (no destination condition)")
        case let .ip(address):
            AppLocalization.format("Exact IP %@", address.presentation)
        case let .network(network):
            AppLocalization.format("CIDR %@", network.presentation)
        case let .host(host):
            switch host.kind {
            case .exact:
                AppLocalization.format("Exact host %@", host.value)
            case .suffix:
                AppLocalization.format(
                    "Host suffix %@ (the base host or a subdomain)",
                    host.value
                )
            }
        case let .hostPattern(pattern):
            AppLocalization.format("Hostname pattern %@", quoted(pattern.pattern))
        }
    }

    private static func protocolDescription(_ transportProtocol: RuleProtocolMatchEvidence) -> String {
        switch transportProtocol {
        case .unconstrained:
            AppLocalization.string("TCP or UDP (no protocol condition)")
        case let .exact(value):
            AppLocalization.format("Exact protocol %@", value.rawValue.uppercased())
        }
    }

    private static func portDescription(_ port: RulePortMatchEvidence) -> String {
        switch port {
        case .unconstrained:
            AppLocalization.string("Any destination port (no port condition)")
        case let .range(range) where range.lowerBound == range.upperBound:
            AppLocalization.format(
                "Exact destination port %@",
                String(range.lowerBound)
            )
        case let .range(range):
            AppLocalization.format(
                "Destination port range %@–%@",
                String(range.lowerBound),
                String(range.upperBound)
            )
        }
    }

    private static func assuranceDescription(_ assurance: RuleSourceIdentityAssurance) -> String {
        switch assurance {
        case .verifiedCodeSignatureRequirement:
            AppLocalization.string("Exact signed application identity")
        case .identifierPattern:
            AppLocalization.string("Application identifier pattern")
        case .exactExecutablePath:
            AppLocalization.string("Exact executable path only (no signature or hash constraint)")
        case .exactExecutablePathAndCodeSignatureRequirement:
            AppLocalization.string("Exact executable path and verified code-signing requirement")
        case .exactExecutablePathAndSHA256:
            AppLocalization.string("Exact executable path and SHA-256")
        case .exactExecutablePathCodeSignatureRequirementAndSHA256:
            AppLocalization.string(
                "Exact executable path, verified code-signing requirement, and SHA-256"
            )
        case .exactAuditToken:
            AppLocalization.string("Exact running process identity verified by audit token")
        case .exactProcessStartTimeAndExecutablePath:
            AppLocalization.string("Exact PID, process start time, and executable path")
        case .exactUserIdentifier:
            AppLocalization.string("Exact user ID")
        }
    }

    private static func fieldName(_ field: RuleApplicationIdentifierField) -> String {
        switch field {
        case .bundleIdentifier: AppLocalization.string("bundle identifier")
        case .signingIdentifier: AppLocalization.string("signing identifier")
        case .executableName: AppLocalization.string("executable name")
        }
    }

    private static func contextUnavailableSummary(
        _ reason: RuleContextUnavailableReason?
    ) -> String {
        switch reason {
        case .missingSourceApplicationAuditToken:
            AppLocalization.string("macOS did not provide a source application audit token.")
        case .sourceIdentityResolutionFailed:
            AppLocalization.string(
                "The source process identity or its code signature could not be resolved."
            )
        case .sourceIdentityAuditTokenMismatch:
            AppLocalization.string(
                "The resolved process identity did not belong to the flow's audit token."
            )
        case .sourceSigningIdentifierMismatch:
            AppLocalization.string(
                "The flow metadata signing identifier disagreed with the verified running code."
            )
        case .emptyRemoteHost:
            AppLocalization.string("The flow did not provide a destination host.")
        case .invalidRemotePort:
            AppLocalization.string("The flow did not provide a valid destination port.")
        case .unsupportedRemoteEndpoint:
            AppLocalization.string(
                "The flow used a destination endpoint type that App Routing cannot match."
            )
        case nil:
            AppLocalization.string("The trusted rule context was unavailable.")
        }
    }

    private static func builtInBypassSummary(_ reason: BuiltInBypassReason?) -> String {
        switch reason {
        case .trustedMClashComponent:
            AppLocalization.string("The source is an exactly verified MClash component.")
        case .loopback:
            AppLocalization.string("The destination is a loopback address.")
        case .linkLocal:
            AppLocalization.string("The destination is a link-local address.")
        case .multicast:
            AppLocalization.string("The destination is a multicast address.")
        case .unspecifiedAddress:
            AppLocalization.string("The destination is an unspecified address.")
        case nil:
            AppLocalization.string("A built-in safety bypass matched this flow.")
        }
    }

    private static func legacyConsequence(for activity: AppRoutingActivity) -> String {
        switch activity.cause {
        case .contextUnavailable:
            AppLocalization.string(
                "Rules were not evaluated and the flow was handed back to macOS (fail-open)."
            )
        case .captureDisabled, .configurationUnavailable:
            AppLocalization.string("The flow was handed back to macOS without a rule match.")
        case .rule, .outboundUnavailable:
            AppLocalization.string("The recorded rule ID and outcome remain available above.")
        }
    }

    private static func labeled(_ label: String, _ value: String?) -> String? {
        value.map { AppLocalization.format("%@ %@", AppLocalization.string(label), $0) }
    }

    private static func joined(_ values: String?...) -> String {
        values.compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " · ")
    }

    private static func quoted(_ value: String) -> String {
        "“\(value)”"
    }
}
