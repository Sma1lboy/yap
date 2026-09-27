---
repo:
  id: "yap"
  name: "Yap"
version: "1.0.0"

producer:
  model: "gpt-image-2"
  params:
    quality: "low"
    output_format: "png"

# Colors are copied from docs/DESIGN.md (the only token source). If they differ, DESIGN.md wins:
# fix it there, run `make design-tokens`, then update this block.
global:
  color:
    accent-light: { $value: "#FFD84D", $type: "color" }
    accent-dark: { $value: "#F7C83A", $type: "color" }
    on-accent: { $value: "#2A2320", $type: "color" }
    bg-light: { $value: "#F3F3F5", $type: "color" }
    bg-dark: { $value: "#1B1B1F", $type: "color" }
    surface-light: { $value: "#FFFFFF", $type: "color" }
    surface-dark: { $value: "#26262B", $type: "color" }
    text-light: { $value: "#1F1F23", $type: "color" }
    text-dark: { $value: "#F2F2F4", $type: "color" }
    border-light: { $value: "#DCDCE1", $type: "color" }
    border-dark: { $value: "#37373E", $type: "color" }
  typography:
    ui-face:
      $value: "Apple system sans (SF Pro / PingFang SC), weights 400/500/600 only, 700 for one hero headline; the same font the app renders"
      $type: "fontFamily"
    mono-face:
      $value: "SF Mono / Menlo for commands like make offline-check and file paths"
      $type: "fontFamily"
  style-fragment:
    real-app-surface:
      $value: "the real Yap macOS window or recorder pill as the subject, taken from make ui-snapshots output; cool graphite neutrals from the duck logo's base, white cards with 1px borders on a cool gray background in light, lighter cards on a darker graphite background in dark, no drop shadows on cards"
      $type: "text"
    duck-yellow-fill:
      $value: "duck yellow only as a fill (one primary button, a selected row, the duck mark); text on yellow is the duck-eye ink color; never yellow text on a light background"
      $type: "text"
    mixed-language-text:
      $value: "text samples are one sentence mixing Chinese and English technical terms, e.g. OAuth Refresh Token现在存在Local Storage里, rendered legibly"
      $type: "text"
  negative:
    global-exclude:
      $value: "warm beige paper background, serif display type, terracotta, neon green or red on near-black, purple-blue gradient hero, glossy SaaS cards with drop shadows, emoji section markers, everything centered, orange (reserved for the logo beak and warnings), microphone clip-art, sound-wave clip-art, robot mascot, fake testimonials, balance or price figures, VoiceInk logo, watermark"
      $type: "text"

alias:
  style:
    launch-hero:
      $value: "{global.style-fragment.real-app-surface}"
      $type: "text"
    social-default:
      $value: "{global.style-fragment.duck-yellow-fill}"
      $type: "text"
---

# Yap theme

Yap's look is the app's own look. `docs/DESIGN.md` defines it; this file only restates it so image producers get it
in their prompt.

- **Subject:** the real app. Screenshots come from `make ui-snapshots` (fake data, re-identified copy, no network),
  never from Jackson's running app or desktop.
- **Color:** duck yellow is a fill, never text on light. Neutrals are the cool graphite of the logo's base. Warnings
  are orange, deliberately not the brand yellow. Every asset exists in light and dark, and the two are designed
  separately (dark layers by lighter cards, not by inverting light).
- **Type:** system fonts only. The site, the app and the review pages render the same font, and no external font is
  loaded.
- **Layout:** left-aligned. Only a single icon plus one line (the recorder pill) is centered.
- **Never:** prices or balances as a visual, testimonials, upstream VoiceInk marks.
