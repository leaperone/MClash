import Foundation

/// Redacts common credential shapes before diagnostic text leaves the Mac.
/// The in-app log remains untouched so local debugging retains full fidelity.
func redactedDiagnosticText(_ text: String) -> String {
    let replacements: [(pattern: String, template: String)] = [
        (
            #"(?i)(authorization\s*[:=]\s*bearer\s+)[^\s,;]+"#,
            "$1[REDACTED]"
        ),
        (
            #"(?i)(-secret\s+)(?:\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            "$1[REDACTED]"
        ),
        (
            #"(?i)((?:password|passwd|token|secret|api[-_]?key|access[-_]?token)\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s,;&]+)"#,
            "$1[REDACTED]"
        ),
        (
            #"(?i)([?&](?:token|key|secret|password|passwd|auth|access_token)=)[^&#\s]+"#,
            "$1[REDACTED]"
        ),
        (
            #"([A-Za-z][A-Za-z0-9+.-]*://)[^/@\s]+@"#,
            "$1[REDACTED]@"
        ),
    ]

    return replacements.reduce(text) { value, replacement in
        value.replacingOccurrences(
            of: replacement.pattern,
            with: replacement.template,
            options: .regularExpression
        )
    }
}
