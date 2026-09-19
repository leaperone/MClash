# Product

## Product Category

Native macOS network routing and proxy controller.

## Users

MClash serves ordinary macOS users first. Adding nodes and connecting must work without editing a configuration file or knowing core terminology. Users can open advanced routing and diagnostic controls when they need them.

## Product Purpose

MClash owns node sources, groups, rules, DNS and traffic observation. Bundled Xray executes proxy connections. Success means users can add a source, connect, see where traffic goes and recover from a failure. Core installation and configuration generation belong to the app.

## Brand Personality

Native, calm, precise. MClash should feel like a focused Apple utility: familiar at first glance, technically trustworthy under sustained use, and quiet when the network is healthy.

## Anti-references

- Cross-platform WebView dashboards that feel like a website placed inside a desktop window.
- Consumer VPN interfaces dominated by maps, neon gradients, oversized connect buttons, or promotional decoration.
- Dense configuration surfaces that expose internal file paths and maintenance operations as normal user choices.

## Design Principles

- The core is infrastructure: bundle it, verify it, and keep it out of normal user decisions.
- Use macOS conventions before inventing custom controls.
- Put current network state and recovery actions ahead of decorative metrics.
- Make advanced information available progressively without making the primary workflow feel technical.
- Every proxy or core state transition must have a safe, understandable failure state.

## Accessibility & Inclusion

Follow the system light/dark appearance, accent color, increased contrast, reduced transparency, and reduced motion settings. All controls require keyboard navigation and useful VoiceOver labels. Status must never be communicated by color alone.

## Delivery

Finish the agreed product scope and verify the integrated application before publishing one version. Individual fixes use local builds and focused tests. A signed candidate can be produced without publishing a Release or creating a tag. Public release follows validation of the complete candidate.
