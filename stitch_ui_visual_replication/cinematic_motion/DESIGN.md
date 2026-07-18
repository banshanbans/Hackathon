---
name: Cinematic Motion
colors:
  surface: '#111317'
  surface-dim: '#111317'
  surface-bright: '#37393e'
  surface-container-lowest: '#0c0e12'
  surface-container-low: '#1a1c20'
  surface-container: '#1e2024'
  surface-container-high: '#282a2e'
  surface-container-highest: '#333539'
  on-surface: '#e2e2e8'
  on-surface-variant: '#e0c0b3'
  inverse-surface: '#e2e2e8'
  inverse-on-surface: '#2f3035'
  outline: '#a78a7f'
  outline-variant: '#584238'
  surface-tint: '#ffb597'
  primary: '#ffb597'
  on-primary: '#591d00'
  primary-container: '#f06a28'
  on-primary-container: '#511a00'
  inverse-primary: '#a43d00'
  secondary: '#4ae176'
  on-secondary: '#003915'
  secondary-container: '#00b954'
  on-secondary-container: '#004119'
  tertiary: '#adc6ff'
  on-tertiary: '#002e6a'
  tertiary-container: '#5290ff'
  on-tertiary-container: '#002960'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#ffdbcd'
  primary-fixed-dim: '#ffb597'
  on-primary-fixed: '#360f00'
  on-primary-fixed-variant: '#7d2d00'
  secondary-fixed: '#6bff8f'
  secondary-fixed-dim: '#4ae176'
  on-secondary-fixed: '#002109'
  on-secondary-fixed-variant: '#005321'
  tertiary-fixed: '#d8e2ff'
  tertiary-fixed-dim: '#adc6ff'
  on-tertiary-fixed: '#001a42'
  on-tertiary-fixed-variant: '#004395'
  background: '#111317'
  on-background: '#e2e2e8'
  surface-variant: '#333539'
typography:
  headline-lg:
    fontFamily: Be Vietnam Pro
    fontSize: 28px
    fontWeight: '700'
    lineHeight: 36px
    letterSpacing: -0.02em
  headline-md:
    fontFamily: Be Vietnam Pro
    fontSize: 22px
    fontWeight: '600'
    lineHeight: 28px
  title-lg:
    fontFamily: Be Vietnam Pro
    fontSize: 18px
    fontWeight: '600'
    lineHeight: 24px
  body-lg:
    fontFamily: Be Vietnam Pro
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  body-md:
    fontFamily: Be Vietnam Pro
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  label-md:
    fontFamily: Geist
    fontSize: 12px
    fontWeight: '500'
    lineHeight: 16px
    letterSpacing: 0.05em
  label-sm:
    fontFamily: Geist
    fontSize: 10px
    fontWeight: '600'
    lineHeight: 12px
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  base: 4px
  container-padding: 20px
  stack-gap: 12px
  grid-gutter: 16px
  card-inner-padding: 16px
---

## Brand & Style
The design system focuses on a **Technical Cinematic** aesthetic, positioning the product as a high-performance AI tool for solo travelers. It combines the utility of a professional camera interface with the futuristic feel of an autonomous agent.

The visual language is characterized by a deep, immersive dark mode that reduces glare during outdoor use, paired with a vibrant, high-energy orange that signals action and precision. The style utilizes **Modern Corporate** layouts with **Glassmorphic** accents—using subtle background blurs and translucent overlays to maintain context during the filming process. The goal is to evoke a sense of creative empowerment, reliability, and cutting-edge intelligence.

## Colors
The palette is optimized for high-contrast visibility and emotional resonance.

- **Primary (#F06A28):** "Action Orange." Used for primary calls-to-action, recording indicators, and active selection states. It represents the energy of travel and the "rec" button of a camera.
- **Surface & Background (#0F1115):** A deep Obsidian neutral. It provides a premium, "cinema-like" backdrop that makes travel photography and video content pop.
- **Success & Status (#22C55E):** A vibrant Mint Green for task completion, "Target Acquired" states, and positive AI feedback.
- **Functional Accents:** Use varying shades of grey (#1E2128 to #333741) for card surfaces and secondary containers to create clear information hierarchy without relying on borders.

## Typography
This design system utilizes **Be Vietnam Pro** for its friendly yet contemporary look, ensuring high legibility for Chinese and Latin characters in dynamic environments. 

For technical data—such as camera settings, agent logs, and task timers—**Geist** is used to provide a "developer-tool" precision. Headlines use tighter letter spacing and heavier weights to command attention, while labels are often uppercased or tracked out to distinguish them as metadata.

## Layout & Spacing
The layout follows a **Fluid Grid** model optimized for H5 and mobile app experiences. 

- **Safe Zones:** A 20px horizontal margin is maintained for all content to ensure thumb-friendly interactions.
- **Rhythm:** A 4px base unit drives all spacing. Stacked elements typically use 12px (3 units) or 16px (4 units) gaps to maintain a tight, professional density.
- **Mobile-First Reflow:** Elements are designed to stack vertically on narrow viewports. Task lists and shot plans use a single-column layout, while secondary metrics (like camera height or angle) are paired in two-column rows to maximize vertical space.

## Elevation & Depth
Hierarchy is established through **Tonal Layers** and **Glassmorphism**.

1.  **Level 0 (Background):** Solid #0F1115.
2.  **Level 1 (Cards):** #1E2128 with a subtle 1px border (#2D3139) to define shape.
3.  **Level 2 (Overlays/Modals):** Semi-transparent background (70% opacity) with a 20px Backdrop Blur. This is used for the H5 shooting interface and "Agent Running" states.
4.  **Shadows:** Shadows are rarely used; instead, "Inner Glows" (subtle top-edge highlights) are applied to buttons to give them a tactile, physical presence without looking dated.

## Shapes
The design uses a **Rounded** corner strategy (0.5rem base) to soften the technical nature of the AI.

- **Primary Containers:** 16px (rounded-lg) for main cards and task modules.
- **Action Elements:** 12px for buttons and input fields to create a "nested" look within the larger cards.
- **Small Components:** 8px (rounded-md) for chips and status tags.
- **Media:** 12px for video previews and reference shots to ensure a consistent, modern frame.

## Components
- **Buttons:** Primary buttons use a solid Orange (#F06A28) background with white text. Secondary buttons use an outlined style with a 1px #2D3139 border.
- **Task Chips:** Small, pill-shaped indicators with high-contrast text. Use green for "Completed," orange for "In Progress," and a muted grey for "Queued."
- **Input Fields:** Dark background (#16191E) with a subtle bottom-border focus state in Orange. Labels should sit above the field in `label-md`.
- **Shot Cards:** Complex components containing a reference image, a title, and a set of icons for camera settings. Use a 16px corner radius and internal padding of 16px.
- **The "Agent Track":** A vertical step-indicator showing the AI's logic flow. Use thin 1px lines and small circular nodes to represent the "Skill Path" of the Agent.
- **H5 Shooting Interface:** Uses a "Camera UI" metaphor with ghosted overlays on top of the live view. Controls (Record, Flip, Gallery) are placed in a bottom-weighted cluster for one-handed operation.