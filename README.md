# gtnh-bees

gtnh-bees automates Forestry bee breeding in GT New Horizons with OpenComputers. It includes the `bees` command, a keyboard terminal interface, and an optional foundation robot.

Inspired by BreederTron3000.

## Features

- Discovers Forestry species and mutation routes from the installed pack.
- Uses stable species UIDs instead of localized names.
- Breeds one species or builds archives for every reachable species.
- Retains at least 32 pure drones per completed species.
- Supports princess conversion and template-based genome imprinting.
- Recovers known scanner and breeder output after interruption.
- Verifies item movement and stops when physical state cannot be proven.
- Installs and updates transactionally with pinned file hashes.

## Requirements

- GT New Horizons with OpenComputers and Forestry
- OpenOS and Lua 5.2
- an Internet Card and tier-2-or-better Data Card for installation
- a transposer connected to bee storage, scanner, and bee housing
- an analyzed template drone in the final bee-storage slot

The foundation robot additionally needs a modem, geolyzer, inventory controller, tier-2-or-better Data Card, and preloaded replacement blocks.

## Commands

```text
bees
bees complete
bees breed <species> [--imprint=all|intermediate|target|none] [--pause]
bees convert <species> [--count=N | --all]
bees imprint [species]
bees help [command]
```

Running `bees` without arguments opens the terminal menu. Use Up and Down to move, Enter to select, and Q, Escape, or Back to leave.

The optional robot service runs with:

```text
bees-robot [--once] [--config=/etc/gtnh-bees-robot.cfg]
```

## Installation

Download the desired self-contained launcher from the repository, then point it at the same raw Git revision.

Computer:

```text
wget -f https://raw.githubusercontent.com/OneNoted/gtnh-bees/main/install-computer.lua install-computer.lua
install-computer.lua https://raw.githubusercontent.com/OneNoted/gtnh-bees/main/
```

Foundation robot:

```text
wget -f https://raw.githubusercontent.com/OneNoted/gtnh-bees/main/install-robot.lua install-robot.lua
install-robot.lua https://raw.githubusercontent.com/OneNoted/gtnh-bees/main/
```

For a tagged release, replace `main` in both URLs with the same tag. Do not mix launcher and base revisions: the embedded manifest deliberately rejects files from another revision.

The computer installer writes `bees` to `/usr/bin` and modules to `/usr/lib/gtnh_bees`. The robot installer writes only the robot executable and its modules.

Installers download the complete release to a fresh staging directory, verify every file against the release manifest, and preserve the previous installation until commit. Failed or interrupted updates either restore the previous files or retain explicit recovery state.

## Configuration

Copy [`examples/gtnh-bees.cfg`](examples/gtnh-bees.cfg) to `/etc/gtnh-bees.cfg`. If the file is missing, the first hardware command opens a setup wizard.

The configuration defines:

- component addresses and transposer sides;
- scanner and breeder input/output slots;
- every recoverable machine-output slot;
- exact bee item registry names and castes;
- operation limits and archive size;
- exact policies for Forestry mutation-condition strings.

The final physical slot in `bee_storage` is always reserved for the scanned template drone. It is never counted as archive stock or used as ordinary storage.

For the robot, copy [`examples/gtnh-bees-robot.cfg`](examples/gtnh-bees-robot.cfg). Controller and robot configurations must pin each other's modem addresses and contain the same shared secret and replay epoch. Keep the replay journal on persistent writable storage.

## Safety

Every machine operation has a finite budget. Transfers specify an exact count and verify source and destination state. Bees are tracked by genome and observed physical location; a similar bee elsewhere is not treated as the same individual.

If an operation cannot prove where retained items ended up, it reports `PHYSICAL STATE UNPROVEN`, exits nonzero, and locks the menu until the setup is reconciled.

Foundation requests use HMAC-SHA256, pinned peers, nonces, a durable replay journal, and an authenticated epoch anchor. To rotate the replay epoch, stop both peers, archive and remove the active journal, leave its `.epoch` anchor in place, configure the same fresh epoch on both peers, then start the robot before the controller.

## First run

Use empty machines and expendable stock:

1. Open and exit the menu; confirm that nothing moves.
2. Configure every component, side, slot, and item registry name.
3. Check discovered species and mutation routes.
4. Breed one expendable mutation and verify all bees return to storage.
5. Restart and reconcile configured machine outputs.
6. Test one conversion and one imprint while watching the reserved slot.
7. Test `bees-robot --once` with a replaceable block if the robot is enabled.
8. Run `bees complete` on copied stock before using valuable archives.

## Development

```sh
lua5.2 tests/run.lua
lua5.3 tests/run.lua
python tests/verify_manifest.py
```

## License

MIT License. Copyright © Jonatan Jonasson.
