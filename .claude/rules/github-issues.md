# GitHub issues

Larger work is written up as a GitHub issue before it is built. An issue opens with a short
paragraph, without a heading, saying what is missing or wrong and why it matters. Then these
sections, in this order, leaving out any that would be empty:

- `## Current state`: what the code does today, by name. #7's table of the settings tofu
  supplies and #8's "Current gap" are examples.
- `## Goal`, or `## Proposal` when the issue names a specific approach.
- `## Done when`: observable results that close the issue. A test issue may call it `## Cover`
  and list the cases the test must prove.
- `## Constraints`: limits the solution must respect. Say which ones are measured and which are not.
- `## Open questions`
- `## Related`: other issues, and whether each one blocks.
- `## Decided`: choices already made. Implement them, and ask before reopening one.
