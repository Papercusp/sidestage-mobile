# SideStage mobile design tokens

These DTCG token files were seeded from the SideStage web app's canonical CSS
variables in `apps/web/src/styles.css` on 2026-08-13. They preserve the current
blue-frost palette for both native shells while giving mobile-specific semantics
and a 44px minimum touch target.

- `mobile.primitives.tokens.json` — literal palette and size primitives.
- `mobile.semantic.tokens.json` — platform-neutral roles used by Compose/SwiftUI.
- `mobile.component.tokens.json` — buyer-flow component aliases.

P-001 deliberately seeds sources only. The Android/iPhone shell items own native
code generation and placement once their projects exist.
