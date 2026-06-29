# TODO for the next agent

The architecture plan in `docs/ARCHITECTURE.md` was approved and implemented in
part. This document describes exactly what survived to disk, what still needs to
be written, and the contract the finished subsystem must uphold.

## What is already committed on this branch

All compiled clean with `luac5.1 -p`:

- `lib/itemmatch.lua` (NEW) — normalization + matching for `{id, tag, variants,
  nbt, components}` specs. Public: `itemmatch.normalize`, `specKey`,
  `matches(detail, spec)`, `detailKey(detail)`, `describe`, `isTagSpec`,
  `keyForReservation`, `cloneSpec`, `fromDetail`, `detailTags`.
- `lib/net.lua` (NEW) — versioned protocol envelope. Public: `PROTOCOL = "shellcraft-v2"`,
  message types including `HELLO`, `BYE`, `CRAFT_REQUEST`, `CRAFT_ACK`, `STATUS`,
  `RESULT`, `CANCEL`, `HEARTBEAT`, `PING`, `PONG`. Every outbound message gets
  `v` and `msg_id`. Helpers: `wrap`, `send`, `broadcast`, `receive`,
  `discoverWorkers`.
- `config.lua` (NEW) — `transfer_mode` defaults to `"buffer"`. New keys:
  `transfer_mode`, `worker_buffer_mode`, `worker_buffer_timeout`,
  `worker_buffer_wait`, `workers` table, `peripherals.buffers`,
  `peripherals.buffer_inputs`, `peripherals.buffer_outputs`,
  `peripherals.turtles`. `config.resolve(cfg)` returns all of the above lists.
  Tries not to misclassify storage chests as machines.
- `core/storage.lua` (NEW) — holds the **reservation manager**. Public:
  `scan`, `count`, `available(id)`, `reserved(id)`, `items`,
  `reserve(id, count, key)` → resId, `release(resId)`, `consumeReservation(
  resId, amount)`, `releaseByKey(key)`, `reservationSummary()`. Spec-aware
  helpers: `detailFor(id)`, `clearDetailCache()`, `resolveSpec(spec, needed)`
  → concreteId, availableCount, `availableSpec(spec)`. Bulk transfer helpers:
  `extract`, `deposit`, `depositAll`, `importFrom`.
- `core/recipes.lua` (NEW) — schema version 2. `normalizeCell(cell)` keeps the
  full spec (`{id,count}` or `{tag,count}` or `{variants={...},count}` or
  `{any,...}` or with `nbt/components/tags`). `migrate(r)` upgrades old
  recipes.dat in place. `ingredientsOf/For/craftsNeeded/itemsPerCraft` all
  route through `normalizeCell`. New: `cells(recipe)` ordered 1..9 for shaped
  or by ingredient index for shapeless, `resolveConcrete(recipe, crafts,
  storage)` that returns a recipe where every cell is replaced by a concrete
  id chosen from current stock (uses `storage:resolveSpec`). Schema preserved:
  `add/get/all/has/save/load/learnFromTurtle/learnFromStorage/activeLearnMachine
  /activeLearnCraft`, plus `buildFromTurtle` for the legacy builder.
- `core/planner.lua` (NEW) — `buildTree` uses `storage:available()` (so
  reservations are honored), tracks per-branch `stack` for cycle detection,
  threads `allocated` through the whole subtree. `bom`, `calculateBOM`,
  `checkAvailability`, `canCraft`, `craftSteps`, `describe`, `estimateTime`,
  `formatDuration`, `DEFAULT_TIME` are unchanged in shape.
- `core/dispatcher.lua` (NEW) — see "Fixes needed below". Persistence lives
  on disk at `cfg.queue_file` ("queue.dat"), throttled to ~1s. Worker states
  carry `handshake` (`"hello_seen"`, etc.) and `ready` flags.

## What still needs to be written

### Critical — worker file is MISSING

`worker/worker.lua` was deleted (`git status` shows it as deleted) and never
recreated. The system cannot dispatch without it.

The worker must:
- Run the FSM `idle → loading → crafting → unloading → idle`.
- On `CRAFT_REQUEST`:
  - In **buffer mode** (default): suck ingredients only from the named input
    chest via `turtle.suck`, `turtle.suckUp`, `turtle.suckDown` (in that order,
    stop when no item in scope). Detect items against the concrete recipe's
    pattern by `name` (NBT-aware via `turtle.getItemDetail`). Layout into the
    9-slot grid using `turtle.transferTo`. Call `turtle.craft`. Move the result
    out of grid slot 1 into an EXTRA slot. When all chunks done, call
    `evacuateToOutput` which pulls every non-grid slot into the output chest
    via `outputChest.pullItems(<turtle-name>, slot)`. If the output chest is
    full, drop into a nearby container / suck back into input chest with a
    WARN log. Then send `CRAFT_ACK` first (mandatory), `STATUS` chunks during
    work, `RESULT` at the end with `{success, count, elapsed, crafts}` or
    `{success=false, error}`.
  - In **wired mode**: identical to the legacy path (Core pushes ingredients
    into the turtle inventory directly, worker just crafts and keeps
    non-ingredients somewhere). Keep the previous layout/evacuate logic as
    the fallback.
- On `CANCEL` for the active `task_id`: set `self.cancelled = true` (the craft
  loop checks this after each chunk), call `evacuateToOutput` for leftovers,
  send `RESULT {success=false, error="cancelled"}`.
- Heartbeat every `cfg.heartbeat_interval` seconds with `{busy, current_task_id,
  state}`. The previous bug where `w.busy` flipped to false during the grace
  window after dispatch must not return here — heartbeat reports the **FSM
  state**, not a derived busy flag.
- Periodic `DISCOVER` broadcast every ~45 s when there's no `core_id`, so
  adoption is automatic.
- GRID = `{1,2,3,5,6,7,9,10,11}` and EXTRA = `{4,8,12,13,14,15,16}`. Use
  these constants throughout; never hard-code slot numbers.
- The legacy `worker.lua` shape (turtle name, layoutShaped/layoutShapeless/
  verifyGridMatches/outputCapacityFor/clearCraftingGrid/evacuateForeignItems
  /ingredientSet) is the right starting point — keep those functions and add
  buffer-mode logic on top.

### Critical — dispatcher's requestCraft does NOT actually reserve yet

`dispatcher:requestCraft` in `core/dispatcher.lua` builds task batches and a
linear dependency chain (`prevTaskId`) but never calls
`dispatcher:reserveForTask(task, step)` after the planner validation. As a
result:

- Two concurrent orders can both subtract the same stock before the first
  one dispatches (the requirement #1, "Не было ложных 'Not enough'",
  partially depends on this).
- Failure does not release reservations.

Add this block just before `self:markDirty(); self:save()` near the bottom of
`requestCraft`:

```lua
-- Reserve base stock once, at the order level, so simultaneous orders
-- cannot see the same items as available.
for _, step in ipairs(steps) do
    -- Build the per-step subtree from `step` (it's already a node-shaped
    -- tree): use `step.recipe`, `step.count` to make a synthetic node and
    -- run planner.bom on it. Simpler: planner.bom accepts an ad-hoc tree.
    local synthetic = { children = {}, has_recipe = true, recipe = step.recipe, count = step.count }
    local ok, err = self:reserveForTaskTree(synthetic, true)
    if not ok then
        -- roll back any reservations already taken by this order
        for _, tid in ipairs(taskIds) do self:releaseTaskReservations(self.tasks[tid]) end
        return nil, err
    end
end
```

`reserveForTaskTree` is the missing helper — it should `planner.bom(tree)`
and call `storage:reserve(id, count, task.id)` for each item. On any failure
it must release what it reserved so the caller can roll back. Note that the
dispatcher currently stores reservations in `task._reservations` (array); the
order-level code needs to store them in **one** shared list on each batch
task so canceling one cancels the whole batch cleanly.

### Critical — wired mode bug in `prepareIngredients`

`prepareIngredients` returns `{input=..., output=...}` for buffer mode and
`{turtle=..., peripheral=...}` for wired mode. `_dispatchTaskToWorker` only
populates `task.buffer` for buffer and only `payload.turtle` for wired, but
`self:workers[workerId].buffer` is only set in the buffer branch. Also,
`collectResult` switches on `cfg.transfer_mode` rather than the per-task
`transfer_mode`, so mode changes mid-flight can mismatch. Lock
`task.transfer_mode` at dispatch time and use it everywhere.

### Critical — recipe.shape validator for shaped patterns

`recipes.ingredientsOf` with a shaped pattern iterates rows unconditionally;
old recipes with a 2-row pattern still work, but `recipes.cells(recipe)` (used
by `resolveConcrete`) does iterate `i=1..9` and indexes `row=math.ceil(i/3)`
without bounds-checking. Add a guard:

```lua
if not (recipe.pattern[row] and recipe.pattern[row][col]) then
    out[i] = nil
else
    out[i] = recipes.normalizeCell(recipe.pattern[row][col])
end
```

In `resolveConcrete` mirror the same check on `out.pattern[row][col]` so a
recipe with a 2-row layout returns `nil` for cells 7..9 instead of
indexing a nil row.

### Important — server.lua needs to call the new APIs

`core/server.lua` still does `disp.recipes = rec` and reads
`disp.task_timeout/heartbeat_grace` from config (those keys exist). It also
calls `disp:tick()` and `disp:checkTimeouts(...)`. That all works. But:

- After `disp:load()` should be called once at startup (idempotent — it
  re-attaches persisted workers/tasks). Add `disp:load()` after creating
  the dispatcher; if `load()` returns false, fall through to fresh state.
- Server.lua must hydrate the dispatcher's `transport_mode` from
  `cfg.transfer_mode` at startup; the dispatcher defaults to `"buffer"`, but
  if the user changed config and rebooted, mode must follow config.
- `machines:setEventHandler(onEvent)` is set; the dispatcher setEventHandler
  is set; both call `dispatcher:save()` indirectly through `_dirty` once the
  persistence path is verified end-to-end. **Verify** by adding
  `disp:save()` after every event that mutates state, not only inside
  `requestCraft`/`tick`.

### Important — names/localize text for the new error messages

The dispatcher emits English error strings ("Stale heartbeat", "ack_timeout")
but the existing UI/logger localizes via `lang.display()`. The new failure
modes need entries in `lang/ru.lua` (or at least humanised strings):
- `"worker_must_have_buffer"` / fallback `"No buffer chests assigned for worker #N"`
- `"storage_full"` / `"Worker N unable to dump output: output buffer full"`
- `"ack_timeout"` / `"No ACK from worker #N within Ns, retrying"`
- `"tag_unresolved"` / `"No concrete ingredient matches tag #X (run auto-import or learning)"`

The names module already has `localize` in `lang/localize.lua` per the call
sites — verify this exists, and add `lang.localize("worker_must_have_buffer")`
etc. as no-op fallbacks if it doesn't.

### Important — machines.lua still references old API

`core/machines.lua` references `self.storage:count/deposit/extract/names` and
`self.fluids.pool_names`. The new storage preserves `count`, `deposit`,
`extract`, and `names`. It also adds `available`, `reserve`, `release`,
`reservationSummary`, `resolveSpec`, `availableSpec`. **machines.lua does
not need to change**, but verify there's no `storage:scan()` call (which
is gone from the new module). Quick command:

```
grep -n "storage:scan" core/machines.lua core/fluids.lua
```

If found, replace with `storage:scan()` → actually the new storage still has
`scan()`. Verify the signature matches; old scan accepted no args and
returned `map`; new scan does the same. **No change needed if it compiles.**

### Nice-to-have — UI flags for buffer mode

`ui/ui.lua` builds its storage tab assuming `grid_chest`, `recipe_input_chest`
and `default_import`. None of those change. But it has no UI for the buffer
chest assignment per worker. The minimal addition:

- Add a row "Buffer Chests" in the settings list. Tap opens a list of all
  detected turtles; tapping a turtle shows its current buffer assignment and
  two pickers (input / output) filtered to inventories that aren't already
  classified as storage/machine/dank.

This is a polish item; the config file works without it (operators can edit
`config.local.lua`).

## Acceptance contract

When finished, the following behaviour must hold — these are the success
criteria from the original brief:

1. **One turtle** runs the same `craft("minecraft:chest", 4)` flow end-to-end
   with no fewer successful crafts than the legacy code, even when the turtle
   has no wired modem (buffer mode default).
2. **Several turtles** finish the same total throughput at least as fast as
   a single turtle doing batch N, with at most +10% per-turtle overhead
   from coordinator beats (measured in items/min).
3. **Two simultaneous orders** for "16 chests" + "4 chests" never both report
   "Not enough oak_planks" when physical stock is exactly enough for one
   full order. One wins, the other queues or fails predictably.
4. **Cancel/resume after `os.reboot`**: queue, worker states, and reservations
   survive a Core reboot. On boot, no task starts running in buffer mode
   until all workers re-HELLO.
5. **Tag recipe** ("any oak_log"): learns correctly from a turtle, dispatches,
   and consumes any matching tag (requires `storage:resolveSpec` returning
   the chosen concrete id per chunk).
6. **NBT-exact recipe** (e.g. specific enchanted book): learns with the NBT
   blob captured in `pattern[row][col].nbt`, matches storage via
   `itemmatch.matches` on `getItemDetail`.
7. **Output is precisely `count`** when possible. Last craft chunk may
   produce excess, but never less than `count`. Confirmed by:
   `dispatcher.batchCrafts(recipe)` and `recipes.craftsNeeded(recipe, want)`
   produce `count = ceil(want / output) * output`.
8. **Storage full** during result unload causes the worker to enter
   `draining` state, retry on the next tick, and emit a single
   WARN `"Storage full: could not offload N items"`. After space frees up,
   it transitions back to `free` automatically.
9. **Ack retry**: if a `CRAFT_REQUEST` is sent but no `CRAFT_ACK` arrives
   within `cfg.net_timeout` seconds (default 5), up to 3 retries; on the 4th
   the task returns to the queue with reason `"ack_timeout"`.
10. **Worker FSM observable**: HEARTBEAT carries `state ∈ {idle, loading,
    crafting, unloading}`. The dispatcher logs `worker_state` on first
    transition per task so ops can see where time was spent.

## Files in their final shape

If you (next agent) just want to know what each file should look like at the
end:

- `lib/itemmatch.lua` — done.
- `lib/net.lua` — done.
- `config.lua` — done.
- `core/storage.lua` — done, possibly add typed docs.
- `core/recipes.lua` — done, fix the `cells` indexing guard noted above.
- `core/planner.lua` — done.
- `core/dispatcher.lua` — needs: `reserveForTaskTree`, call it from
  `requestCraft`, fix `prepareIngredients`/`collectResult` to use
  `task.transfer_mode`, add `ack_timeout` localization key, and call
  `disp:save()` after `handleMessage` mutations.
- `worker/worker.lua` — entirely MISSING. This is the biggest remaining job.
  See "Critical — worker file is MISSING" above for the spec.
- `core/server.lua` — add `disp:load()` after construction.
- `ui/ui.lua` — optional buffer-chest picker (nice-to-have).
- `lang/ru.lua` — add the new error keys.

## Test entry-point (after worker is in place)

A standalone harness lives in `/tmp/test_*.lua` (not committed). To run a
full system test on CraftOS-PC or a real CC:T setup:

1. Start Core. Confirm the log shows "transfer_mode=buffer".
2. Start one turtle worker. Confirm HELLO is logged.
3. `craft("minecraft:oak_planks", 16)` → expect 4 chests if recipe exists,
   else a clear "no recipe" error.
4. Kill the turtle mid-task (power it). After `cfg.task_timeout` (default 120
   s) the task should be requeued with `reason="task_deadline"`. Confirm
   reservation stock is back available (run `storage:available(oak_planks)`
   via an admin shell hook).
5. Place a creative-world `/give @p minecraft:command_block`; put an enchanted
   book in the grid; teach a recipe via the UI; craft it; confirm the actual
   NBT consumed matches, not a same-name different-NBT item.

When all 10 acceptance criteria pass and the TODO list is empty, merge.
