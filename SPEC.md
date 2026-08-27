# gtnh-bees behavior specification

This document defines the program's observable behavior and safety requirements.

## Product

gtnh-bees is a GT New Horizons OpenComputers program that breeds Forestry bees through an attached bee housing, scanner, transposer, storage inventory, and optional foundation robot.

Runtime requirements:

- OpenOS on OpenComputers
- Lua 5.2 compatibility
- Lua 5.3 compatibility where it does not conflict with Lua 5.2
- no external package manager at runtime

Public executables:

- `bees`
- `bees-robot`

## User experience

Running `bees` without arguments opens a keyboard-driven terminal menu. The initial choices are:

1. Complete the collection
2. Breed a species
3. Convert princesses
4. Imprint a genome
5. Exit

The menu supports Up, Down, Enter, and a clear back/quit key. Before an operation starts it presents a short summary and asks for confirmation. It asks only for values relevant to the selected operation.

The non-interactive command interface is:

```text
bees complete
bees breed <species> [--imprint=MODE] [--pause]
bees convert <species> [--count=N | --all]
bees imprint [species]
bees help [command]
```

Rules:

- No arguments means terminal menu.
- Species names containing spaces can be quoted by the OpenOS shell.
- `--imprint` accepts `all`, `intermediate`, `target`, or `none`; default is `all`.
- `--pause` pauses after each newly produced species for quest turn-in.
- Conversion defaults to one princess.
- Conversion accepts either a positive integer count or `--all`, never both.
- Help and argument validation do not require attached bee hardware.
- CLI and TUI produce one shared command representation and call one application service. No breeding behavior lives in either user interface.

Error messages should identify the failed operation, affected species or inventory role when known, and whether the run stopped safely. Avoid all-caps routine output.

## Forestry identity and discovery

- Stable Forestry species UIDs are the sole graph identity.
- Localized display names are labels and user-input conveniences, not keys.
- Duplicate display names must remain separate when UIDs differ.
- Species and mutation data are discovered dynamically from the installed GTNH/OpenComputers bee-housing APIs, including the APIs that enumerate species and report registered mutation parents.
- Lua-visible values may be strings, allele-like tables, maps, callable proxies, or converted Java/Scala collections. Normalize only when the representation can be interpreted unambiguously.
- Malformed, failed, or ambiguous API responses stop discovery with a useful error. Do not silently produce a partial graph.
- Mutation routes are unordered parent pairs that produce a result species, with available condition and chance metadata retained for reporting and route selection.
- Route choice is deterministic. Prefer routes that are currently feasible; among equivalent routes prefer fewer unmet environmental conditions, then higher chance, then stable UID ordering.
- Opaque official condition strings are satisfied only through an installation-provided exact-string policy. Foundation policies name an exact requested block ID; explicitly satisfied policies require operator validation. Unknown strings remain unmet.

## Inventory model

The program operates on bees found in configured attached storage.

For each bee item, record when available:

- caste: princess, drone, or queen
- active species UID
- inactive species UID
- complete genome data exposed by the component API
- scanned state
- stack size
- physical inventory and slot

Definitions:

- A pure drone has identical active and inactive species UIDs.
- A completed archive species has at least 32 pure drones in ordinary usable storage. Thirty-two is a fixed minimum: configuration may raise the target but must reject zero, fractional, or sub-32 values.
- A pair is population-compatible only when the complete exposed genomes are equivalent, not merely when species UIDs match.
- Mixed drones remain usable breeding stock but do not satisfy the archive target.

The final physical slot of the configured bee-storage inventory is reserved for one valid scanned template drone:

- never count it as archive stock;
- never use it as a mutation parent, conversion source, or ordinary destination;
- reject imprinting when it is absent, unscanned, or not a drone;
- leave it untouched during operations that do not imprint.

Destination selection must prefer merging with a compatible stack before using an empty ordinary slot. It must never use the reserved slot. Full storage is a recoverable stop, not permission to discard or guess.

## Reachability

At the start of `complete`, take a snapshot of usable bee stock and compute every species structurally reachable from that stock.

Reachability tracks princess capability and drone capability separately. A princess of species A and drones of species B can unlock an A+B mutation without requiring a complete pure pair of either species.

A species is initially available in a role only when current stock can actually serve that role. Conversion may create a princess role when sufficient compatible drones exist under the conversion rules.

The target set is fixed for the run. Later route failures or exclusions do not erase a species from the final missing report.

Reachability is structural, not a promise that irreplaceable princess lineages can satisfy every branch simultaneously. Execution must preserve parents whenever possible and report branches that cannot be realized from remaining stock.

## Operations

### Complete collection

`bees complete`:

1. Recovers or reports machine output left by an interrupted prior run.
2. Scans and reconciles bees in usable storage without consuming the reserved template.
3. Discovers the installed mutation graph.
4. Fixes the reachable UID target set from startup stock.
5. Repeatedly selects a feasible missing species or prepares missing parent stock.
6. Breeds, scans, and returns all retained bees to usable storage.
7. Builds each reachable archive to at least 32 pure drones using a full-genome-equivalent pair.
8. Optionally imprints according to the operation's configured policy, without making optional imprint failure corrupt completion state.
9. Stops when all targets are complete or no safe progress remains.
10. Prints completed and missing UIDs with human-readable labels and failure reasons.

An ordinary probabilistic miss with a valid `safe=true` storage attestation retries the same route within a finite configured generation budget. It is not evidence that the route is invalid. Only an explicitly classified deterministic failure with a valid safe attestation may exclude a route immediately; malformed, missing, or unsafe attestations stop before another movement.

A failure to return any bee to known usable storage is fatal to the run because the in-memory inventory would otherwise be dishonest. Every scanner/breeder/conversion/archive/imprint boundary result must be an operation-specific table with `safe=true`, explicit completion, observed identity, and retained-location fields; a non-nil value or omitted safety field is never proof.

### Breed one species

`bees breed <species>` resolves the user label unambiguously to a UID, computes a route from current stock, produces missing ancestors in dependency order, then produces and archives the requested species.

- Unknown labels fail with suggestions when practical.
- Duplicate labels require UID disambiguation.
- Parent bees are retained whenever the physical breeding cycle permits.
- Imprint policy can apply to all produced species, intermediate species only, target only, or none.
- Quest pause occurs only after a newly produced species has been returned to safe storage.

### Convert princesses

Conversion uses drones of the requested species to convert one, N, or every available princess.

- Selected source stacks must remain physically identifiable throughout the loop.
- A target-active princess remains in the bounded conversion lineage until its full exposed genome matches the source drone.
- Conversion stops if source drones are depleted, storage becomes unavailable, or its generation budget is reached.
- Every bee is returned to known storage before success or failure is reported.

### Imprint genomes

Imprinting uses the scanned template drone in the reserved slot and applies its exposed genome to one requested species or all eligible stored species.

- The template itself remains reserved.
- A completed pure-drone archive may supply an ordinary donor only from stock above its protected archive minimum.
- Imprinting is bounded by a configurable generation limit.
- Output is scanned and graded after each generation.
- Optional imprint failure during complete mode is reported but does not falsify archive completion.

## Hardware and safety boundary

Use documented GTNH, OpenComputers, and Forestry integration APIs.

The hardware adapter owns all component calls and physical slot movement. Domain planning must be testable without OpenComputers modules.

Required hardware roles:

- bee housing or apiary/alveary adapter exposing Forestry breeding APIs
- transposer
- bee storage
- scanner input/output inventory path
- breeder input/output inventory path
- explicit recoverable-output or overflow role where the physical setup needs one
- optional modem-connected foundation robot

Configuration maps logical roles to component addresses and sides. First-run configuration must make each role understandable and persist it in one authoritative local configuration file. Invalid or ambiguous component topology stops before any bee moves.

Inventory actions:

- transfer an explicit item count;
- verify observed source and destination state after movement;
- retry only when repetition cannot consume more than requested;
- never infer success solely from elapsed time;
- never guess a destination after an ambiguous API response.

Every wait loop is bounded or requires explicit supervised acknowledgement. This includes:

- bee generations;
- scanner completion;
- blocked transfers;
- princess conversion;
- template imprinting;
- foundation robot requests and replies.

On interruption or restart, inspect configured machine outputs before starting new work. Recover only when the item and destination are unambiguous; otherwise stop and tell the operator where the bee remains.

## Foundation robot

`bees-robot` is an optional service that changes the block under the bee housing when a mutation route requires a foundation condition.

The robot uses preloaded inventory. The protocol must:

- identify the requested block unambiguously;
- confirm that the replacement is available before breaking the installed block;
- place the replacement;
- retain or return the displaced block;
- send a bounded success or failure response to the controller;
- be idempotent enough that a retried request does not blindly break a correct foundation;
- pin and verify both controller/robot modem addresses and both signal endpoints;
- authenticate request and reply contents with a configured secret and replay-resistant nonce (or use a separately verified physically isolated link);
- bind replay records to request ID, block, and nonce, reject ID/content reuse, and verify the response block;
- after placement or confirmation failure, make a bounded restoration attempt and report the exact observed block and retained inventory slots.

## Installer

Provide transactional installers for the computer and robot:

- download every required file to staging paths first;
- do not replace an installed file until every download succeeds;
- preserve backups while installing;
- restore all previous files if any install rename fails;
- recover a complete prior installation after an interrupted update;
- use interruptible low-level requests with explicit connection, idle-read, per-file, and overall deadlines;
- check download, journal, and saved-configuration flushes explicitly;
- validate every staged file against release-pinned size and digest metadata;
- propagate rollback failures, retain recovery artifacts, and report every unresolved destination;
- never leave a mixture of old and new runtime modules presented as successful or claim consistency without proof.

## Acceptance requirements

At minimum test:

1. UID normalization across supported unambiguous representations.
2. Duplicate display names remain distinct.
3. Role-aware reachability from cross-species starter stock.
4. Deterministic route choice independent of table iteration order.
5. Fixed reachable targets remain missing after route failure.
6. Pure-drone counting excludes mixed drones and the reserved slot.
7. Population selection rejects species-equal but genome-different pairs.
8. Storage merges before allocating an empty slot.
9. Full ordinary storage never consumes the reserved slot.
10. Failed or partial transfer never drains more than requested.
11. Scanner and machine-output recovery preserve bee identity.
12. Every breeding, conversion, scanning, robot, and imprint loop terminates under failure.
13. CLI validation and help require no hardware.
14. CLI and TUI map equivalent choices to the same command representation.
15. Installer failure preserves the prior complete installation.
16. Lua 5.2 parsing and tests pass; Lua 5.3 is a supplementary gate.

Live GTNH acceptance is supervised:

1. Open and exit the TUI without moving items.
2. Configure topology with empty machines.
3. Breed one expendable known mutation.
4. Verify all parents and offspring return to expected storage.
5. Restart and reconcile.
6. Run `complete` on copied or expendable stock before valuable archives.
