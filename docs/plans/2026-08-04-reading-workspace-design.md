# Satori reading workspace redesign

## Primary flow

Satori opens into the current course and document rather than a dashboard. The left sidebar answers “what am I learning?” and shows course-level reading progress. The center answers “what am I reading now?” and gives the PDF most of the window. A resizable, dismissible inspector answers “what do I want to understand?” without permanently shrinking the document.

The document header lives inside the reading surface. It shows the actual file name, content type, current/total pages, direct page jump, PDF switching, replacement, and removal. This avoids relying on compact toolbar icons whose labels disappear on macOS.

The inspector has two modes: Understanding and Directory. Understanding starts with the current page context, a small set of intent-based prompts, and a stable composer at the bottom. Directory shows the course structure without competing with the assistant. Closing the inspector produces a focused reader; reopening it keeps the current document and page.

## Visual system

- Reading canvas: neutral system background so scanned pages retain contrast
- Brand accent: restrained lavender for selection and focus
- Insight accent: warm gold for current-context markers only
- Spacing: 8, 12, 16, 20, 24, 32
- Radius: 8 for controls, 12 for cards, 16 for major empty states
- Typography: native San Francisco, using title3/headline/callout/caption hierarchy

## States and accessibility

- Empty course: one primary PDF import action and a short explanation
- Missing file: explicit recovery/replace action rather than a generic empty screen
- AI unconfigured: clear Keychain settings action
- Keyboard: page input submits with Return; tooltips and accessibility labels describe icon-only controls
- Resize: reader remains usable with the inspector closed; inspector is constrained to a practical minimum width
