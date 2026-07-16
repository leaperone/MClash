---
name: MClash
description: A calm, native macOS control surface for mihomo Alpha.
colors:
  accent: "NSColor.controlAccentColor"
  window-background: "NSColor.windowBackgroundColor"
  control-background: "NSColor.controlBackgroundColor"
  primary-label: "NSColor.labelColor"
  secondary-label: "NSColor.secondaryLabelColor"
  separator: "NSColor.separatorColor"
  success: "NSColor.systemGreen"
  warning: "NSColor.systemOrange"
  failure: "NSColor.systemRed"
typography:
  title:
    fontFamily: "SF Pro, system-ui"
    fontSize: "22pt"
    fontWeight: 600
    lineHeight: 1.2
  body:
    fontFamily: "SF Pro, system-ui"
    fontSize: "13pt"
    fontWeight: 400
    lineHeight: 1.35
  label:
    fontFamily: "SF Pro, system-ui"
    fontSize: "11pt"
    fontWeight: 400
    lineHeight: 1.25
  data:
    fontFamily: "SF Mono, ui-monospace"
    fontSize: "11pt"
    fontWeight: 400
    lineHeight: 1.3
spacing:
  compact: "8px"
  control: "12px"
  group: "20px"
  section: "24px"
  page: "28px"
---

# Design System: MClash

## Overview

**Creative North Star: "The Native Network Utility"**

MClash should look and behave as though it belongs beside System Settings, Activity Monitor, and the best focused utilities built for macOS. The interface is restrained and task-oriented: a sidebar establishes place, native lists organize changing data, and semantic system colors communicate state without creating a separate visual universe.

The product explicitly rejects cross-platform WebView dashboards, consumer VPN spectacle, and maintenance-oriented screens that ask users to locate executables or reason about internal file paths. Motion is responsive rather than choreographed, and density increases only on screens where the data demands it.

**Key Characteristics:**

- Native SwiftUI/AppKit control vocabulary
- System-managed light, dark, contrast, accent, and accessibility behavior
- Clear connected, transitional, recoverable, and failed states
- Compact operational data with generous page-level breathing room
- Wide-screen composition that uses horizontal space before adding vertical depth
- No decorative branding competing with network status

## Colors

The palette is entirely semantic and supplied by macOS. Fixed RGB values are forbidden in product code because they break system appearance, user accent selection, and increased-contrast behavior.

### Primary

- **System Accent:** Used only for the primary action, current selection, keyboard focus, and active profile indication.

### Neutral

- **Window Background:** The default window and navigation surface.
- **Control Background:** A subtle secondary surface for overview content where macOS already uses it.
- **Primary and Secondary Labels:** Standard macOS text hierarchy; secondary text never replaces a proper label.
- **Separator:** Native dividers between structurally different regions.

### State

- **System Green:** Healthy, connected state accompanied by an icon and text label.
- **System Orange:** Transitional or recoverable warning state.
- **System Red:** Failed state and destructive actions only.

**The Semantic Color Rule.** Always use `Color(nsColor:)`, SwiftUI semantic styles, or system materials. Never hard-code a light/dark pair in a view.

**The Rare Accent Rule.** Accent color is for action and selection, not decoration. It should occupy less than ten percent of a normal screen.

## Typography

**Display Font:** SF Pro through SwiftUI system typography
**Body Font:** SF Pro through SwiftUI system typography
**Label/Mono Font:** SF Mono through `.monospaced()` or the system monospaced design

**Character:** Familiar, compact, and highly legible. Typography should disappear into the task rather than establish a separate editorial voice.

### Hierarchy

- **Title** (semibold, 22pt): Window destinations and major operational state.
- **Headline** (semibold, system headline): Menu bar title, grouped controls, and list emphasis.
- **Body** (regular, 13pt): Standard labels and descriptive content.
- **Label** (regular, 11pt): Metadata, timestamps, and secondary operational context.
- **Data** (regular, 11pt monospaced): Rates, byte counts, ports, controller versions, and logs.

**The System Scale Rule.** Use SwiftUI text styles. Explicit point sizes are documentation references, not permission to bypass Dynamic Type or accessibility sizing.

## Elevation

MClash is flat by default. Depth comes from native window chrome, sidebar/content separation, sheets, popovers, menus, and tonal system backgrounds. Custom drop shadows are forbidden; the operating system owns window and transient-surface elevation.

**The Platform Owns Depth Rule.** If a surface needs a custom shadow to read correctly, its containment or hierarchy is wrong.

## Components

### Buttons

- **Shape:** Native macOS button geometry determined by the selected control size.
- **Primary:** `.borderedProminent` for the single dominant action in a region.
- **Hover / Focus:** System-provided pointer, keyboard focus, and pressed states.
- **Secondary:** `.bordered` or borderless toolbar actions according to platform convention.

### Status Marks

- **Style:** SF Symbol plus semantic color plus explicit status text.
- **State:** Connected, transitional, stopped, and failed states use different symbols; color alone is never sufficient.

### Containers

- **Corner Style:** Native lists, forms, sections, and popovers before custom rounded containers.
- **Background:** Semantic window and control backgrounds.
- **Shadow Strategy:** None inside normal content.
- **Internal Padding:** 12px controls, 20–24px groups, and 28px page edges.
- **Page Surface:** Every destination fills the detail column with the system
  window background. Dense lists use 18px horizontal and 12px vertical scroll
  margins; content dashboards use the shared 28px page gutter.
- **Responsive Structure:** Overview-style dashboards use a main/secondary
  column on wide windows and return to one column when either side would become
  unreadable. Controls hide or consolidate secondary metadata before truncating
  the primary label.

### Inputs / Fields

- **Style:** Standard `TextField`, `Picker`, `Toggle`, and `Form` behavior.
- **Focus:** System focus ring and full keyboard traversal.
- **Error / Disabled:** Inline explanation when actionable; disabled states must remain legible.

### Navigation

- **Style:** `NavigationSplitView` with a standard sidebar and SF Symbols.
- **Active State:** System selection treatment, never a custom colored stripe.
- **Menu Bar:** A compact status summary and the most frequent actions only.

## Do's and Don'ts

### Do:

- **Do** follow system light, dark, accent, increased-contrast, and reduced-motion settings automatically.
- **Do** use lists and tables for proxy groups, connections, profiles, and logs.
- **Do** keep the active profile, connection state, routing mode, and recovery action immediately discoverable.
- **Do** use 150–250ms state transitions only where they clarify a change.
- **Do** keep the bundled core and internal paths outside normal settings.

### Don't:

- **Don't** build a cross-platform WebView dashboard that feels like a website placed inside a desktop window.
- **Don't** imitate consumer VPN interfaces with maps, neon gradients, oversized connect controls, or promotional decoration.
- **Don't** expose executable selection, core download, controller secrets, or runtime file paths as normal user settings.
- **Don't** use glassmorphism, decorative gradients, custom shadows, or gratuitous entrance animations.
- **Don't** use color alone for status or bypass standard keyboard and VoiceOver behavior.
