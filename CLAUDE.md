# cluster

`README.md` says what this project is until the design doc replaces this line.

@.claude/rules/github-issues.md

## Parts meet at contracts, not code layers

The third-party parts (the image builder, RKE2, keepalived, Rancher, cert-manager, the tofu
harness) will change while this is in development. Keep each one replaceable without a redesign.
Parts talk through plain data: a file, env vars, a port, a qcow2. `/etc/rancher/rke2/elect.env`
between cloud-init and `rke2_elect.py` is one such contract. Keep a part's decisions separate from
the tool-specific calls that act on them. For example, the election's result (role, bootstrap)
stays apart from the RKE2 commands that carry it out. When a change crosses an edge, name the
contract it changes. Do not add wrapper, adapter or plugin code until a second implementation
actually exists. The contract makes the part swappable, not an interface.

## One tofu state for every checkout

The `backend "local"` block in `main.tf` keeps state at `/srv/rocky-cluster/terraform.tfstate`,
and `tofu.sh` mounts that directory into the container. Every checkout and every worktree under
`.claude/worktrees/` therefore drives the same VMs on vcows under one lock. An apply from a
worktree replaces whatever arrangement another session left running, and a destroy removes it. A
lock error means another session is mid-run. `tofu test` ignores the backend and does not touch
this state.

## Commands

`just` lists the recipes. `just check` runs the checks CI runs before `tofu test`. `just tofu <verb>`
goes through `tofu.sh`, which shares the `/srv/rocky-cluster` state (see "One tofu state for every
checkout").

## Refer to code by name

Anchor every reference to a name (a symbol, heading, variable or filename), never `file:NN`. A
line number drifts with every insertion above it, and nothing checks that it still points where
it claims.

## Commits and how work ships

Imperative, sentence-length subject. The body says what was measured and corrects earlier wrong
claims by name. Branch off `master`, one PR per issue, squash-merge, and close the issue from the
commit body with `Closes #NN`.
