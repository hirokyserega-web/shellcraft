# ShellCraft architecture

## Goals

- One turtle or many turtles should use the same crafting pipeline.
- Core owns scheduling, reservation, persistence, and storage accounting.
- Workers only execute one task at a time and never decide global ordering.
- Buffer mode is the default transport because it removes the wired-inventory dependency from turtles.
- Wired mode remains available for legacy builds and for cases where the operator wants direct core→turtle inventory transfers.

## Core ideas

### 1) Two transport modes

#### Buffer mode
- Each worker gets a dedicated input chest and output chest.
- Core places ingredients into the input chest through the wired network.
- The turtle pulls ingredients from the input chest with `turtle.suck*()`.
- The turtle crafts locally and drops the result into the output chest.
- Core pulls the result from the output chest into storage.

This keeps crafting working even when the turtle itself has no wired modem attached.

#### Wired mode
- Core talks directly to the turtle inventory via the wired network.
- This preserves the previous model for legacy setups.
- Startup and dispatch log explicit errors if the turtle is not reachable on the wired network.

### 2) Task model

A craft order becomes a small DAG:
- leaf nodes = base resources already present in storage;
- internal nodes = craftable recipes;
- tasks are created only for craftable nodes.

Tasks are persisted to disk so the queue survives restarts.
A task is only dispatched when all dependencies are finished and its required base resources are already reserved.

### 3) Reservation model

Storage keeps a global reservation table.
- `available = physical_total - reserved_total`
- planning reserves base resources before tasks are dispatched
- a task consumes its reservation when extraction actually happens
- cancel/failure releases remaining reservation

This prevents two orders from double-booking the same stock.

### 4) Recipe resolution

Recipes are normalized into a modern format:
- each ingredient cell stores a list of allowed selectors (`anyOf`)
- selectors can include `id`, `nbtHash`, `componentsHash`, and tags
- old `recipes.dat` entries are migrated on load

At planning time the resolver chooses a concrete selector for each ingredient cell based on current stock.
That concrete plan is what gets reserved and crafted.

### 5) Worker lifecycle

Workers run a strict FSM:
- `idle`
- `loading`
- `crafting`
- `unloading`
- `idle`

Every task carries a `task_id`, and every worker response includes that id.
This makes retries and late packets safe.

### 6) Network protocol

The rednet protocol is versioned and uses explicit message envelopes.
Required messages:
- `DISCOVER`
- `HELLO`
- `BYE`
- `CRAFT_REQUEST`
- `CRAFT_ACK`
- `STATUS`
- `RESULT`
- `CANCEL`
- `HEARTBEAT`
- `PING`
- `PONG`

`CRAFT_REQUEST` is retried until `CRAFT_ACK` arrives.
Late `RESULT` packets are matched by `task_id`.

### 7) Persistence and updates

Core persists queue state, worker state, and reservations to disk.
Startup checks that state before auto-update.
If there is active work, auto-update is deferred until the system goes idle.

## Files

- `lib/net.lua` — message envelope, retries, compatibility helpers
- `core/recipes.lua` — normalization, migration, selector resolution
- `core/storage.lua` — inventory cache, reservation manager, exact extraction/deposit
- `core/planner.lua` — dependency tree and BOM calculation
- `core/dispatcher.lua` — task DAG, queueing, persistence, scheduling
- `worker/worker.lua` — turtle FSM and transport logic
- `config.lua` — transport mode, buffer assignments, persistence paths
- `startup.lua` — defers auto-update while active work exists

## Notes

- UI stays compatible with the old recipe/task APIs where possible.
- Machine processing remains in `core/machines.lua` and is not part of the turtle crafting rewrite.
- The buffer transport still requires the buffer chests themselves to be reachable by the Core on the wired network.
