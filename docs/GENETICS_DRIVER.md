# Official genetics and machine boundary

`gtnh_bees.hardware` is the sole component/transfer boundary. Component methods are invoked by address through `component.invoke` when available, with a protected callable-proxy fallback for faithful OpenOS callable tables. The physical layout is configured once and all scanner, housing, recovery, conversion, archive, and imprint consumers derive from those role records.

## Fixed official discovery API

The bundled `gtnh_bees.official_driver` targets the inspected GTNH OpenComputers Forestry integration:

- component type: `bee_housing`;
- `listAllSpecies()` for species records;
- `getBeeBreedingData()` for mutation records (`allele1`, `allele2`, `result`, `chance`, `specialConditions`).

Names returned in breeding data are mapped atomically to the stable `uid` values returned by `listAllSpecies`. Resolution retains every case-folded UID/label candidate: duplicate labels and label/UID collisions reject an ambiguous string instead of overwriting a lookup entry. An unambiguous reference or an explicit UID-bearing shape remains usable. The callback only enumerates species that occur as mutation results, so it can omit a parent-only allele. If any reported parent or result is absent from that enumeration, discovery stops. Missing, duplicate, malformed, ambiguous, non-finite, or out-of-range data likewise aborts discovery.

Both official callback collections are traversed by their raw Lua keys, never by the length operator. A collection is accepted only as an empty table, an exact contiguous positive-integer array, or a deterministic string-keyed map, with at most 4096 entries. Zero, negative, fractional, NaN, infinite, sparse, mixed array/map, and non-string map keys are rejected before any catalog is published. Mutation `parents` is likewise an exact two-item array with no extra keys. Custom scalar routes may instead supply one complete `parent1`/`parent2` pair; combining representations or supplying either half alone is rejected.

OpenComputers' analyzed Forestry individual converter exposes `isAnalyzed`, plus complete `active` and `inactive` genome maps. Each genome's `species` value contains `uid` and `name`. The driver preserves both complete maps and uses the UIDs as identity. A raw transposer item stack does not, by itself, prove its Forestry genome; the configured exact item-name/caste map only identifies which items may be sent through the analyzer.

## Physical state machines

The authoritative computer configuration records:

- `bee_storage`: transposer side, final reserved slot, and exact item registry name → caste mapping;
- `scanner`: transposer side, analyzer component address, one input slot, and every possible output slot;
- `breeder`: transposer side, princess input, drone input, every output slot, and at least two stable terminal observations (`terminal_stable_polls`);
- `recovery`: every recoverable output slot.

A machine cycle checks configured slots before input, transfers explicit counts, and accepts a terminal state only after both input slots are empty and the configured output-slot state is stable for a bounded number of observations. Input occupancy and `minimum_outputs` are never offspring evidence. Stacked unanalyzed output is moved through the analyzer one physical bee at a time, re-reading the same source slot until it is empty. Scanner calls may carry `{blocked_storage_slot=<slot>}` while an unanalyzed remainder still occupies its source storage slot. Every output is returned before a second bounded empty-state check; late or unsettled output is recovered but makes the cycle incomplete. Collection uses the exact final storage evidence returned by `adapter:return_output`, not the stale scanner/breeder source coordinates. A result is accepted only when it is an operation-specific table with `safe=true`, a boolean completion state, target/bee identity, and an exact retained location. Missing safety or location is fatal; non-nil is never treated as proof.

`specialConditions` from the official callback are opaque strings. The catalog consults only the exact `mutation_conditions` key from configuration. A validated mapping may mark that exact identity `satisfied`, leave it explicitly `unmet`, or request a validated namespaced foundation block through the authenticated controller. Unknown strings remain unmet; there is no substring, localization, or case-fold guessing. A custom driver may return a string or a table containing one exact string `identity`, but table fields such as `satisfied`, `foundation`, or `block` never carry policy and cannot bypass configuration. A condition table without that identity is rejected.

Required successful result fields are:

- scan: `safe`, `complete`, `identity`, `location`, `scanned`;
- breed/archive: `safe`, `complete`, `uid`, `location`, `outputs`;
- conversion: `safe`, `complete`, `uid`, `princess_identity`, `location`; every retryable incomplete generation must report `retained_princess` as one physical princess with `inventory="bee_storage"` and its exact final ordinary storage `slot`;
- imprint: `safe`, `complete`, `uid`, `scanned`, `template_retained`, `location`; every retryable incomplete generation must report `retained_princess` as one physical princess with `inventory="bee_storage"` and its exact final ordinary storage `slot`.

The hardware transfer boundary rejects the reserved template slot as either source or destination. Imprinting therefore requires an explicitly selected singleton princess at an exact ordinary storage slot and an ordinary template-equivalent donor drone; the reserved singleton scanned drone template is verified at the configured reserved slot and never moved. On retry, that exact princess may carry any graded active allele: eligibility is lineage-and-location based rather than an obsolete `active == requested_uid` check. Success requires exactly one scanned princess output whose full exposed genome matches the template. An unchanged matching donor drone is not imprint evidence.

Direct and dependency conversions retry ordinary safely retained incomplete generations for the same physically identified princess lineage up to `limits.conversion_generations`. A reconciled bee must match the attested exact final storage slot and full exposed identity; genome equality alone can never choose between duplicate princesses. Only `route_failure="deterministic"` on an otherwise valid safe result can exclude dependency conversion and permit an alternate mutation route. Exhausted ordinary misses remain a reported incomplete target; missing retained-slot evidence, ambiguous evidence, malformed, missing, or unsafe results are fatal.

Safe graded imprint mismatches are ordinary misses and retry up to `limits.imprint`. Each retry follows the one exact physical princess attested in the preceding generation even when grading changes its active UID; the operations layer reconciles its exact ordinary storage slot, singleton count, caste, active/inactive identities, and full genome. It never reselects by the command's original active UID, which can collide with duplicate stock. Missing, ambiguous, reserved-slot, stacked, or mismatched retained evidence is fatal. Only an otherwise valid safe result carrying `route_failure="deterministic"` may stop grading early. The selected princess output, rather than a matching donor, is graded against the reserved full genome after the reserved template is reverified in place after every generation. Missing or malformed attestations and any failure to prove template retention remain fatal.

Planning keeps species-role presence separate from executable stock. Conversion capability needs both a source drone and a physically present alternate princess; archive readiness needs a full-genome-equivalent princess/drone pair. Matching species with incompatible genomes therefore does not enter archive directly: registered mutation routes are still explored. Dependency solving explores both parent orientations and fills only the required princess role for one parent and drone role for the other. In breed mode, requested intermediate imprints are queued until the target has been produced and archived. Complete mode queues every requested completed-archive imprint until all fixed reachable targets have been produced and archived; if complete stops with any target missing, it executes none of the queued imprints. Thus grading cannot consume a princess lineage before a downstream dependency. Once every target is complete, safe imprint misses retain their existing non-fatal reporting behavior.

The operations boundary rejects counted-conversion values that are NaN, positive or negative infinity, nonpositive, or fractional before attempting a physical conversion.

## Deployment validation

Inventory slot layouts vary between GTNH installations. Configure only slots observed on the target setup, validate topology with empty machines, and run the first cycle with an expendable bee. If the reserved template cannot be decoded and verified in place, or any configured output cannot be identified and returned, the bundled driver stops.

A custom driver module remains possible, but it must preserve the same result schemas, use `adapter:transfer_verified`, use only official APIs, keep finite bounds, and prove every retained location. Bundled analyzer slot and fixed-callback validation applies only when `driver_module` is exactly `gtnh_bees.official_driver`; universal component, endpoint, reserved-slot, finite-limit, and foundation-authentication checks still apply to custom drivers.
