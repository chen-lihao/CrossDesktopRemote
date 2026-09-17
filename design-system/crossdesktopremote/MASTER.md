# CrossDesktopRemote design system

## Night Orbit / 夜航

CrossDesktopRemote is a security-sensitive productivity tool with a restrained,
original anime-inspired identity. The interface uses quiet twilight colors,
precise star-orbit linework, and a compact monitor mark. It never uses
copyrighted characters, decorative clutter, or visual effects over the remote
desktop canvas.

The design is one system with three presentation modes:

- **System** follows the operating-system brightness.
- **Light** uses a cool, luminous indigo workspace.
- **Dark** uses a deep navy workspace, never pure black outside the video canvas.

## Semantic palette

| Role | Light | Dark |
|---|---|---|
| Canvas | #F2F4FB | #101422 |
| Surface | #FAFBFF | #181D2E |
| Primary | #5964B5 | #C4C8FF |
| Brand spark | #B95B7F | #F1A8C0 |
| Success | #32766F | #8FD2C9 |
| Primary text | #25283B | #F2F3FC |
| Secondary text | #5C6077 | #BEC2D8 |

- Indigo is the only interaction accent.
- Sakura is limited to the brand spark and sparse ambient details.
- Success, warning, and error colors remain semantic and always include text
  or an icon.
- The remote desktop video canvas may remain neutral black. App pages may not.

## Layout and component contract

- Flutter Material 3 remains the control foundation.
- Layout follows available width, not operating-system checks.
- Breakpoints are below 700, 700–1099, and 1100 or wider.
- Spacing follows 4 / 8 / 12 / 16 / 24 / 32 / 48.
- Radius hierarchy is 12 for controls, 16 for inner surfaces, 22 for cards,
  and 28 only for large panels.
- Touch targets are at least 44pt on Apple platforms and 48dp where Material
  density permits.
- Motion is causal: 120ms feedback, 190ms state changes, and 260ms panels.
- Platform differences live in capability adapters, not page composition.

## Notification contract

- Transient messages appear below the top safe area, centered within a maximum
  width of 560 logical pixels.
- Up to four messages may be visible simultaneously, separated by 8 pixels.
- Info and success close after 3 seconds, warning after 5 seconds, and error
  after 8 seconds.
- Every message has its own timer and close control. New messages never remove
  an existing one.
- Duplicate messages with the same key within one second are suppressed.
- Notifications are scoped per Flutter window.
- Persistent connection, transfer, and recovery progress belongs in page state
  or an operation banner, not the transient notification stack.

## Safety boundary

Presentation work may change theme, layout, typography, notification rendering,
and shared visual components. It must not alter remote video geometry, input
mapping, audio capture/playout, file-transfer state, trust authentication, or
signaling behavior.
