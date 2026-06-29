# Prompt for next AI agent — finish the ShellCraft crafting rewrite

You are continuing the partial rewrite of ShellCraft on branch
`craft-rewrite-v2` (commit `cd7e5b9`, pushed to
`git@github.com:hirokyserega-web/shellcraft.git`). The previous agent (me)
ran out of sandbox and stopped midway. Your job: finish what's missing so
the system actually compiles, starts, and runs end-to-end with both single
and multi-turtle setups, satisfying the 10-point requirements from the
original task.

## First 10 minutes — orient yourself

1. Read `docs/ARCHITECTURE.md` (the approved plan) and `docs/TODO.md`
   (current state with priorities).
2. Run `git log --oneline -5` and `git status` on the branch.
3. Run `for f in lib/*.lua core/*.lua worker/*.lua ui/*.lua config.lua
   startup.lua updater.lua install.lua; do luac5.1 -p "$f" || echo "BAD:
   $f"; done` — every existing file must compile clean. Anything red
   stops you.
4. Re-read these files end-to-end (they are the new core):
   - `lib/itemmatch.lua` — `{id|tag|variants|nbt|components}` specs
   - `lib/net.lua` — `shellcraft-v2` protocol with `msg_id` envelope
   - `core/storage.lua` — `scan`, `count`, `available`, `reserve`,
     `release`, `consumeReservation`, `resolveSpec`, `availableSpec`,
     exact-match `extract`, exact-match `deposit`, `importFrom`,
     `collectNames`, `displayName`, `items`, `detailsFor` (if present)
   - `core/recipes.lua` — `SCHEMA_VERSION = 2`, `normalizeCell`,
     `migrate`, `resolveConcrete`, `craftsNeeded`, `ingredientsOf`,
     `ingredientsFor`, `fluidsOf`, `fluidsFor`, `cells`, `cellId`,
     `add`, `remove`, `get`, `all`, `has`, `load`, `save`,
     `updateTiming`, `avgTimeFor`, `snapshotAll`, `snapshotStation`,
     `buildFromTurtle`, `learnFromTurtle`, `learnFromStorage`,
     `activeLearnMachine`, `activeLearnCraft`
   - `core/planner.lua` — uses `storage:available()`, emits `bom`,
     `craftSteps`, `canCraft`, `checkAvailability`, `estimateTime`
   - `core/dispatcher.lua` — buffer/wired dual mode, ACK retries,
     persistence, reservation, `requestCraft`, `tick`, `handleMessage`

## Hard invariants the previous agent set — DO NOT BREAK

- Recipe cells are now specs (string OR table). Anything that reads
  `recipe.pattern[r][c].id` or `recipe.ingredients[i].id` must keep
  working because the UI still calls it. Use `recipes.cellId(cell)` for
  logging/keys and `recipes.normalizeCell(cell)` for iteration.
- `recipes.craftsNeeded(recipe, want)` returns the number of OPERATIONS
  to satisfy `want` OUTPUT items; do NOT confuse with `want` again.
- `storage:count(id)` is physical; `storage:available(id)` subtracts
  reservations. Planner and `canCraft` must use `available`.
- `storage:reserve(id, n, key)` returns a `resId`; keep the array of
  resIds on `task._reservations` so `releaseTaskReservations` works.
- Dispatcher sends `CRAFT_REQUEST` with `payload.buffer = {input,
  output}` in buffer mode and `payload.turtle = "<wired name>"` in
  wired mode. `CRAFT_ACK` must come from the worker before
  `_dispatchTaskToWorker` considers the task in flight. Re-send up to 3
  times if ACK times out.
- Worker response messages include `task_id`; `RESULT` may arrive after
  the worker has been reset to `free` — the dispatcher MUST look the
  task up by id, not by `worker.current_task`.

## Critical missing pieces — fix these IN ORDER

### 1. Rewrite `worker/worker.lua` (it is currently DELETED)

Buffer mode is the default. The worker must:

- On `HELLO` (also `WORKER_HELLO` for backwards compat) reply with
  `{ id, role = "worker", busy = self.busy, current_task_id =
  self.current_task_id, state = self.state, buffer = self.buffer, core
  = self.core_id }`.
- On `CRAFT_REQUEST`:
  1. Set `self.busy = true`, `self.state = "loading"`, store
     `self.buffer = payload.buffer`, `self.current_task_id =
     payload.task_id`.
  2. Send `CRAFT_ACK { task_id }` back IMMEDIATELY (before any
     `turtle.suck`). This is the contract.
  3. If `payload.transfer_mode == "wired"`: ensure
     `peripheral.isPresent(payload.turtle)` and pull ingredients via
     `payload.turtle.pullItems` into the grid.
  4. If `payload.transfer_mode == "buffer"`:
     a. Verify both `payload.buffer.input` and `payload.buffer.output`
        are present. If not, send `RESULT { success = false, error =
        "buffer chest missing" }`.
     b. Clear the inventory: for every non-grid slot that holds
        something, try `peripheral.wrap(buffer.output).pullItems(myId,
        slot)` then `buffer.input.pullItems(...)` then
        `turtle.drop() / dropUp() / dropDown()`. Anything left is a
        real error.
     c. Pull ingredients for each non-empty cell in the recipe: for
        `shaped`, iterate 1..9 in `GRID` order (`{1,2,3,5,6,7,9,10,11}`),
        calling `turtle.suckUp(<buffer.input>)` until you have
        `chunk * cell.count` of that item. For `shapeless`, the same
        but indexed by ingredient position. `turtle.suckUp` returns
        the count moved; loop until satisfied or a timeout per cell
        (e.g. 30 s wall clock).
     d. Craft in chunks: `chunk = min(remaining_crafts,
        max(1, floor(64 / recipe.output)))`. Before each chunk, verify
        you have room for `chunk * recipe.output` in EXTRA slots
        (`{4,8,12,13,14,15,16}`); count space including existing
        partial stacks of `recipe.id`. If no room, try to drop foreign
        items to `buffer.output`; if still no room, send a clear
        error and stop.
     e. `turtle.craft(chunk * output)`. If it returns false, send
        `RESULT { success = false, error = "turtle.craft rejected" }`.
     f. After craft: move results out of slot 1 into EXTRA slots
        (prefer non-grid slots; if no merge-into-same-id slot exists,
        any empty EXTRA). Then run a second clear pass: for every slot
        not in GRID that has items, push to `buffer.output` via
        `buffer.output.pullItems(myId, slot)` (note: `pullItems` FROM
        the turtle's perspective, called on the chest).
     g. Repeat until `crafts == 0`.
  5. Send `RESULT { success = true, count = crafts*output, elapsed,
     crafts }`. Then `self.state = "idle"`, `self.busy = false`,
     `self.current_task_id = nil`.
  6. Wrap the whole craft in `pcall`. On any throw, send `RESULT {
     success = false, error = tostring(err) }` and reset state.
- On `CANCEL { task_id }`: only honour if `task_id ==
  self.current_task_id`. Set `self.cancelled = true`, do your best to
  clear the turtle into `buffer.output`, then send `RESULT { success =
  false, error = "cancelled" }`.
- Heartbeat every `cfg.heartbeat_interval` (default 10 s) to
  `self.core_id` with `{ task_id, current_task_id, busy, state }`. If
  no core is known, broadcast `HELLO`.
- Optional but recommended: respect `turtle.fuel()` — if fuel is low,
  call `turtle.refuel(1)` from a fuel slot. This is the most common
  silent failure today.

Keep `worker/worker.lua` under ~450 lines. Re-use the old helpers only
as comments / inspiration.

### 2. Wire `dispatcher:requestCraft` to actually reserve

`requestCraft` currently calls `planner.canCraft` (which uses
`available`) but does NOT reserve. Result: two orders for the same item
both pass `canCraft` and both fail later with "Not enough X".

Fix: after `canCraft` succeeds and BEFORE creating tasks, walk
`planner.craftSteps(tree)` and for each step call a new helper
`dispatcher:reserveStep(step)` that reserves the step's leaf-BOM via
`storage:reserve(...)`. Store the returned resId on each task in that
step (`task._reservations = { rid, ... }`). If any reservation fails,
release all previously taken reservations in this order and return
`nil, err`.

On `RESULT success`: walk `task._reservations` and call
`storage:consumeReservation(rid, task.count_per_id)`. Use a map
`task_id -> { id -> count }` that you compute when reserving (because
after batching the task only knows its own output count, not the per-id
input consumption). The simplest correct shape: store
`task._ingredientUsage = { [id] = count_consumed }` alongside
`_reservations`; `consumeReservation` will be called with each
`(rid, count)` pair.

On `RESULT failure` / cancel / timeout: call
`dispatcher:releaseTaskReservations(task)`.

### 3. Wire `dispatcher.tick` to do `_readyQueue` reservation-aware

Right now `tick()` calls `prepareIngredients(workerId, task)` which
checks the buffer/wired availability, but the reservation isn't actually
moved from "queued" to "running" state. Make sure that
`task.status = "running"` happens only after `_dispatchTaskToWorker`
has successfully sent the request AND the buffer/wired preparation
passed. If buffer preparation fails because the chest is full,
increment attempts and requeue with a back-off (give it 2 s before
re-attempt).

### 4. UI compatibility shims

The UI (`ui/ui.lua`) still calls:

- `dispatcher:requestCraft(id, count, recipes)` — keep the signature
  exactly.
- `dispatcher:workerCount()`, `dispatcher:workerList()`,
  `dispatcher:freeCount()` — keep returning `{count, [{id, state,
  info, current}], n}`.
- `dispatcher:tick()`, `dispatcher:handleMessage(senderId, msg)`,
  `dispatcher:activeTasks()`, `dispatcher:allTasks()`,
  `dispatcher:checkTimeouts()`.
- `storage:count(id)`, `storage:items()`, `storage:importFrom(name, n)`,
  `storage:deposit(src, slot, n)`, `storage:extract(id, n, dst, slot)`,
  `storage:displayName(id)`, `storage:collectNames(namesModule)`.
- `recipes:get(id)`, `recipes:has(id)`, `recipes:all()`,
  `recipes.ingredientsFor(recipe, want)`, `recipes.fluidsFor(recipe,
  want)`, `recipes.craftsNeeded(recipe, want)`, `recipes.avgTimeFor`,
  `recipes:updateTiming`, `recipes:learnFromTurtle`,
  `recipes:learnFromStorage`, `recipes:activeLearnCraft`,
  `recipes:activeLearnMachine`.
- `planner.buildTree`, `planner.canCraft`, `planner.estimateTime`,
  `planner.formatDuration`.
- `lang.display(id)` and `lang.localize(id)` (these come from
  `lib/names.lua` and are accessed via `_G.lang`).

The UI calls `lang.localize` — `lib/names.lua` exposes `display`, not
`localize`. Set `_G.lang = names` somewhere in `startup.lua` OR add a
`localize` alias to `lib/names.lua` that forwards to `display`. Pick
the smaller change.

UI uses `disp.workers` (plural map). Confirm `dispatcher.workers` is
the same shape.

The UI also writes `self.deps.fluids:resolvePool(resolved)` after
config changes. `core/fluids.lua` is NOT rewritten — confirm the old
`resolvePool` signature is unchanged. If `resolved` now has new keys
(`buffers`, `buffer_inputs`, `buffer_outputs`, `turtles`), `resolvePool`
must ignore them.

### 5. Update `core/server.lua`

- After `dispatcher.new`, call `disp:load()` to restore any persisted
  state from the previous session.
- On the `storageScanLoop`, do `disp:save()` only when `_dirty`.
- Add a `craft_planned` log entry that prints the count of steps and
  estimated time (use `planner.estimateTime(tree, workersCount,
  recipes)`).
- On `task_started`, include `task.count`, `task.crafts`,
  `task.transfer_mode` in the event payload so the UI can show "X
  crafts (buffer) → turtle #N".

### 6. Update `startup.lua`

- Set `_G.lang = names` so `lang.localize` works inside modules.
- Pass `cfg.queue_file` and `cfg.transfer_mode` into `dispatcher.new`
  explicitly OR let `dispatcher.new` read them itself (current code does
  the latter; fine, just verify it).
- Add an updater guard: skip `updater.run()` if `disp.tasks` has any
  `running` or `queued` task — print a warning instead. After update,
  `os.reboot` will pick up the new code; the queue state file should
  reload cleanly.

### 7. Update `install.lua` and `updater.lua`

- Add `lib/itemmatch.lua` to the FILES list.
- Add `docs/ARCHITECTURE.md`, `docs/TODO.md`, `docs/NEXT_AGENT_PROMPT.md`
  to the FILES list (optional — these are dev docs).

### 8. Tests to run before committing

In CraftOS-PC (or pure Lua 5.1 with stubbed CC globals):

```lua
-- 1. itemmatch
local im = require("lib.itemmatch")
assert(im.matches({name="minecraft:oak_log"}, "minecraft:oak_log"))
assert(im.matches({name="minecraft:oak_log", tags={["minecraft:logs"]=true}},
                  {tag="minecraft:logs"}))
assert(not im.matches({name="minecraft:oak_log"}, {tag="minecraft:planks"}))
local k1 = im.specKey({tag="minecraft:logs"})
local k2 = im.specKey({variants={"minecraft:oak_log","minecraft:birch_log"}})
print("itemmatch OK")

-- 2. storage reservations
local st = storage.new({storage={}})
st.cache["minecraft:oak_log"] = {total=10, locations={}}
local rid = st:reserve("minecraft:oak_log", 4, "test")
assert(st:available("minecraft:oak_log") == 6)
st:consumeReservation(rid, 4)
assert(st:available("minecraft:oak_log") == 10)
local rid2 = st:reserve("minecraft:oak_log", 6, "test")
st:release(rid2)
assert(st:available("minecraft:oak_log") == 10)
print("storage reservations OK")

-- 3. recipes craftsNeeded for output=4, want=10 -> crafts = 3 (output 12)
local r = recipes.new("/tmp/r.dat")
r:add({id="minecraft:oak_planks", type="shaped", output=4,
        pattern={{{id="minecraft:oak_log"}}}})
assert(recipes.craftsNeeded(r:get("minecraft:oak_planks"), 10) == 3)
local ings = recipes.ingredientsFor(r:get("minecraft:oak_planks"), 10)
-- 3 crafts * 1 log per craft = 3 logs total input, output = 12 planks
assert(ings[1].id == "minecraft:oak_log" and ings[1].count == 3)
print("recipes OK")

-- 4. spec resolution against a stub storage
st.cache["minecraft:oak_log"] = {total=10, locations={}}
st.cache["minecraft:birch_log"] = {total=5, locations={}}
local id, avail = st:resolveSpec({variants={
    "minecraft:oak_log", "minecraft:birch_log"}}, 1)
assert(id == "minecraft:oak_log", "should prefer whichever has enough")
print("resolveSpec OK")
```

The exact output counts may differ if you change `craftsNeeded`; the
important assertions are "matches/no-matches" and "available
decreases after reserve, restores after release".

### 9. Acceptance checklist from the original task

Run through these mentally against your diff:

1. Single turtle, single recipe, `count = N` works end-to-end.
2. Multiple turtles receive tasks in parallel; the
   `_dispatchTaskToWorker` loop visits all free workers each tick.
3. `transfer_mode = "wired"` still works for legacy setups (the existing
   `core/storage.lua` `extract` covers it; verify the wired path in
   `dispatcher` doesn't regress).
4. Recipes survive a Core reboot: `queue.dat` reloads, tasks restore
   their status, dependencies re-evaluate, reservations re-add against
   the live `available`.
5. Crash mid-craft: worker dead, `heartbeat_interval * 6` later the
   dispatcher requeues the task AND releases its reservation.
6. `Not enough X` now uses `available` not `count`, AND returns a
   single line listing ALL missing items, not the first one only.
7. Final count can be `ceil(want / output)` operations, output can
   exceed `want` by up to `output - 1`. UI shows requested vs
   delivered. No runaway over-craft because the LAST batch is sized to
   not exceed `want + (output - 1)`.
8. UI filter by tags must not show a recipe as craftable if NO
   variant of any of its tagged ingredients is in stock — fix in
   `canCraft`: walk `planner.bom` and check
   `storage:availableSpec(spec) >= need` for spec entries, not
   `count(id) >= need`.
9. Storage full → `importFrom` returns `"storage_full"`, dispatcher
   keeps `worker.state = "draining"`, retries on next tick when space
   opens up; the worker does NOT receive a new task until drained.
10. Tag/variant recipes (e.g. chest from any planks) and NBT recipes
    (e.g. specific enchanted book) both craft correctly — verified via
    the `resolveSpec` tests above and via one end-to-end test per
    shape.

## Style rules

- All comments in English unless the file already uses Russian (the
  existing modules are in Russian — match the file's existing language).
- No dependencies that aren't already installed. Don't `require` any
  LuaRocks modules; CC:Tweaked runs on Lua 5.1 with a fixed stdlib.
- Don't add `npm` / `node` code; this is a Lua codebase.
- Preserve the public API of every module called from
  `core/server.lua`, `ui/ui.lua`, and `worker/worker.lua`. If you
  change a signature, update all callers in the same commit.

## When you're done

- All `luac5.1 -p` checks pass for every `.lua` file in the repo.
- The `docs/TODO.md` checkboxes for §2-§7 are ticked.
- A short note added at the bottom of `docs/TODO.md` listing the final
  list of files changed and any deviations from the architecture plan.
- Push the branch with the same command the previous agent used:
  `git push origin craft-rewrite-v2`.
