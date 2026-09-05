# Product

## Product Category

Native macOS network routing and proxy controller.

## Users

MClash is primarily for the Leaperone team and other technically fluent macOS users who already understand Clash-style profiles, proxy groups, and routing modes. They use it throughout the day as infrastructure, not as a consumer onboarding experience.

## Product Purpose

MClash provides a dependable, native macOS routing runtime and control surface. It owns entrances, DNS, rules, groups, node selection, traffic inspection, and lifecycle; imported Profiles supply node connection records only. Success means the app starts ready to use, keeps network state recoverable, explains every route, and never exposes compatibility-engine maintenance as a normal user task.

## Brand Personality

Native, calm, precise. MClash should feel like a focused Apple utility: familiar at first glance, technically trustworthy under sustained use, and quiet when the network is healthy.

## Anti-references

- Cross-platform WebView dashboards that feel like a website placed inside a desktop window.
- Consumer VPN interfaces dominated by maps, neon gradients, oversized connect buttons, or promotional decoration.
- Dense configuration surfaces that expose internal file paths and maintenance operations as normal user choices.

## Design Principles

- The runtime is infrastructure: MClash owns it, verifies it, and keeps compatibility connectors out of normal user decisions.
- A Profile is a replaceable node source, never the active routing configuration.
- Use macOS conventions before inventing custom controls.
- Put current network state and recovery actions ahead of decorative metrics.
- Make advanced information available progressively without making the primary workflow feel technical.
- Every proxy or core state transition must have a safe, understandable failure state.

## Accessibility & Inclusion

Follow the system light/dark appearance, accent color, increased contrast, reduced transparency, and reduced motion settings. All controls require keyboard navigation and useful VoiceOver labels. Status must never be communicated by color alone.
