import Testing
@testable import MClashApp

@Suite("Diagnostic text redaction")
struct DiagnosticTextRedactorTests {
    @Test("Redacts common credentials while preserving surrounding diagnostics")
    func redactsCredentials() {
        let source = """
        Authorization: Bearer controller-value
        mihomo -secret local-secret-value -d /tmp
        password: \"profile-password\"
        GET https://example.com/sub?token=subscription-token&name=test
        socks5://user:pass@example.com:1080
        """

        let redacted = redactedDiagnosticText(source)

        #expect(!redacted.contains("controller-value"))
        #expect(!redacted.contains("local-secret-value"))
        #expect(!redacted.contains("profile-password"))
        #expect(!redacted.contains("subscription-token"))
        #expect(!redacted.contains("user:pass"))
        #expect(redacted.contains("example.com"))
        #expect(redacted.contains("name=test"))
        #expect(redacted.contains("[REDACTED]"))
    }

    @Test("Does not rewrite ordinary routing text")
    func preservesOrdinaryText() {
        let source = "Rule MATCH selected Proxy-A for example.com:443"
        #expect(redactedDiagnosticText(source) == source)
    }
}
