---
name: penpot-design-system
description: Research, build, review, and maintain Penpot design systems and UX flows. Use for Penpot tokens, themes, reusable components, variants, shared libraries, responsive layouts, prototypes, design exports, and preservation of approved designs.
---

# Penpot design systems

Use the official sources below and verify capabilities against the installed Penpot version. The current online documentation can describe features newer than a self-hosted instance. Do not claim that a design uses tokens, components, responsive layouts, or prototypes merely because an asset exists: inspect the actual bindings and interactions.

## Workflow

1. Inspect the existing file, its libraries, themes, components, pages, approvals, and feedback. Preserve the user's designs and comments; do not treat a draft as approved.
2. Before modifying an existing design, preserve a named snapshot and an editable export. Check for concurrent edits and feedback. Keep approved versions and their status distinct from new drafts.
3. Decide the smallest reusable system that supports the requested flow. Reuse an existing library only after checking its source, license, platform fit, accessibility, version compatibility, and ability to edit and update it. Do not import an entire kit merely because it exists.
4. Build foundations and semantic tokens, actual component mains and instances, and responsive layouts before assembling screens. Link each applicable property to the intended token or asset; explain deliberate exceptions.
5. Demonstrate and verify the resulting design in Penpot: token change propagates, components update their instances, variant overrides survive where intended, and interactive flows work. Restore-test an exported file in an isolated project when changing deliverable exports.
6. Document what was verified, what remains draft or unsupported, and any migration or feedback limitations. Never claim that a visual mockup or a Penpot component is tested production code.

Use English as the primary language for Nephos design copy, component names, and flow labels. Preserve user comments in their original language.

## Tokens and themes

- Organize primitives, semantic roles, and component-specific tokens where useful. Use meaningful names such as `color.text.primary` instead of names tied to a particular color. Reference other tokens with `{token.name}`; references are case-sensitive.
- Define sets and themes for light and dark values; actually apply the tokens to fills, strokes, sizing, radii, layout spacing, or typography when supported by the installed version. A color or typography asset is not itself proof of a token binding.
- Inspect token usage on the elements themselves, not just the Tokens panel. On a safe test copy, change a token and verify its intended consumers update, then restore the original value.
- In the tested Penpot 2.18.6 plugin flow, the legacy `opacity.disabled` value `.5` recorded a binding without rendering it. The draft explicitly mirrors that token for disabled opacity; treat it as an exception, not an automatic binding.
- Current documentation describes one token source per file, either local or a connected library, and per-file active themes. Check that the installed version supports these features. A file-wide theme switch can affect all bound screens; plan separate files or an explicit presentation strategy if light and dark screens must be visible simultaneously.
- Check readable contrast in each theme and interaction state. Exported token formats and native platform mappings still require compatibility and implementation checks.

## Components and variants

- Define each reusable pattern as a main component, then place linked instances on screens. Group and name assets semantically; document purpose, usage, accessibility, and relevant states with annotations or nearby boards.
- Model reusable controls rather than individual actions: for example, use a `Button` variant with `Type=Destructive` and override its label for “Cancel QR”; do not create a separate component for each button label.
- Model meaningful properties such as `type`, `size`, `state`, and optional icon. Create only valid combinations; use nested components for reusable icons and controls. Cover applicable default, focus, pressed, disabled, loading, and error states rather than assuming every control needs every state.
- Instance overrides persist rather than tracking the overridden property of the main. Use overrides for intentional differences; reset or detach only deliberately, since detaching breaks future updates. Verify inheritance by changing a main in a safe test.
- Penpot can save an instance text override while the canvas and export still render the main component's stale text layout. Verify the rendered result after reopening, not just the stored characters. In a protected 2.18.6 test copy, invalidating stale `position-data` through a validated file update and reopening the page caused Penpot to remeasure it; preserve the override and test any recovery on a snapshot first.
- To preserve overrides while switching variants, corresponding layers must have the same name, compatible layer type, and hierarchy level. Test label and icon overrides across the actual variants.
- If related components are converted into variants, verify the installed version's rules and check the result, including naming and overrides.
- Penpot's AI kit reports that variant-property mutations could corrupt saves on Penpot 2.16. Test any such automation in a disposable copy, verify a subsequent save and reload, and stop if saves fail or hang; never assume newer versions are unaffected.

## Libraries and layouts

- Keep shared foundations, UI patterns, and icons organized into libraries when doing so helps reuse; avoid unnecessary fragmentation. Publish a source file as a shared library and connect it to consumer files. Verify cross-file updates and recognize that disconnecting or unpublishing can break links.
- Document component behavior and intended usage in the library, including states, constraints, and accessibility. Keep asset names consistent and search-friendly. Treat library upgrades and breaking changes as versioned changes.
- Use Flex or Grid for suitable responsive containers, with explicit alignment, gaps, padding, and sizing. Check text resizing, long labels, and different viewport sizes; absolute positioning remains appropriate for intentional overlays or diagram geometry.
- Use Penpot Inspect as a handoff aid, not a guarantee of production-ready behavior or accessibility. Platform-specific iOS and Android controls and conventions need separate review.

## UX flows and preservation

- Maintain readable flow diagrams with visible, labeled arrows when requested. A drawn arrow is not an interactive prototype: add actual prototype interactions and flow starts when interaction is required, and test them in View mode. Use overlays for modal behavior where appropriate.
- Keep admin and mobile canvases separate when requested; demonstrate both light and dark mobile designs without implying they are approved. Preserve native system dialogs as platform behaviors rather than inventing additional application screens.
- `.penpot` exports preserve editable design data but do not by themselves preserve Penpot comment threads or server history. Maintain an appropriate live-server backup for comments and snapshots; never delete or resolve user feedback without authorization. Validate exports by importing into an isolated temporary project, then clean up only that project.
- In the verified 2.18.6 restore, a legacy theme description was cleared on import.
  Compare token definitions, aliases, theme selections, bindings, and interactions
  separately from that descriptive metadata; do not ignore functional differences.

## Action consistency

- Choose one published convention rather than mixing incompatible systems.
  Nephos adopts Carbon's secondary-left / commit-right paired action order.
  Destructive confirmation uses the commit position with explicit danger styling.
- Nephos centers a **single modal-footer action**, regardless of positive or
  destructive intent, following user feedback. This is a product override:
  Carbon itself right-aligns single actions. Nephos also retains inset rounded
  buttons rather than Carbon's full-bleed footer.
- Use linked Button variants and shared sizing tokens, not raw rectangle/text
  copies. Current admin dimensions are 180 x 44, or 224 x 44 for long labels,
  with 16px paired gaps and 24px dialog content/footer insets. Native Flex child
  order can differ from creation order: inspect actual saved button coordinates.
- Card, empty-state, and row actions have different alignment contexts; document
  them explicitly rather than treating every single action as a modal footer.
- Destructive dialogs identify the selected target and consequences, provide a
  safe exit, disable repeated submission while pending, and distinguish confirmed
  success from an uncertain server result. Close does not undo an in-flight request.
- Prototype templates must not substitute a different device for the selected
  one. Label dynamic target fields explicitly and document simulated server outcomes.
- Carbon and Fluent agree on concise action labels, limited primary emphasis,
  and clear outcomes, but their paired-action ordering differs. Do not combine
  their ordering recommendations.

## Sources

- [Design tokens](https://help.penpot.app/user-guide/design-systems/design-tokens/) and [token tutorial](https://penpot.app/blog/design-tokens-with-penpot/)
- [Components](https://help.penpot.app/user-guide/design-systems/components/) and [create and share components](https://penpot.app/blog/tutorial-create-and-share-components-in-penpot/)
- [Variants](https://help.penpot.app/user-guide/design-systems/variants/) and [five variant examples](https://penpot.app/blog/tutorial-5-examples-of-component-variants/)
- [Components & Variants — Penpot tutorial](https://www.youtube.com/watch?v=LZp2-zl4szM)
- [Penpot AI kit: variant API caveats](https://github.com/penpot/penpot-ai-kit/blob/main/shared/plugin-api-gotchas.md)
- [Penpot: stale rendered text on component-instance overrides](https://github.com/penpot/penpot/issues/8826)
- [Libraries](https://help.penpot.app/user-guide/design-systems/libraries/) and [using components and shared libraries](https://penpot.app/blog/tutorial-use-components-and-shared-libraries/)
- [Design-system best practices](https://penpot.app/blog/design-systems-best-practices-with-penpot/) and [component libraries](https://penpot.app/blog/what-is-a-component-library/)
- [Carbon modal guidelines](https://carbondesignsystem.com/components/modal/usage/), [Fluent button guidance](https://fluent2.microsoft.design/components/web/react/core/button/usage), and [Fluent dialog guidance](https://fluent2.microsoft.design/components/web/react/core/dialog/usage)
- [Flex and Grid](https://help.penpot.app/user-guide/designing/flexible-layouts/), [prototyping](https://help.penpot.app/user-guide/prototyping-testing/prototyping/), and [export/import](https://help.penpot.app/user-guide/export-import/)
- [Penpot Hub](https://penpot.app/penpothub/libraries-templates?category=Design+system): [Pencil](https://penpot.app/penpothub/libraries-templates/penpot-design-system), [variant examples](https://penpot.app/penpothub/libraries-templates/variant-examples), [Ant Design](https://penpot.app/penpothub/libraries-templates/ant-design-v6), and [Material Design 3](https://penpot.app/penpothub/libraries-templates/material-design-3). These are candidates for evaluation, not pre-approved dependencies.
