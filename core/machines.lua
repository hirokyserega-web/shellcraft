-- core/machines.lua
-- Management for universal processing stations (machines, mixers, furnaces, etc.).
-- Uses asynchronous FSM ticks instead of blocking sleep loops.

local machines = {}
machines.__index = machines

-- Helper slot layouts for basic vanilla furnaces
machines.SLOTS = {
    ["minecraft:furnace"]       = { input = {1}, fuel = {2}, output = {3} },
    ["minecraft:blast_furnace"] = { input = {1}, fuel = {2}, output = {3} },
    ["minecraft:smoker"]        = { input = {1}, fuel = {2}, output = {3} },
    ["minecraft:brewer"]        = { input = {1, 2, 3}, fuel = {4}, output = {5} },
    furnace       = { input = {1}, fuel = {2}, output = {3} },
    blast_furnace = { input = {1}, fuel = {2}, output = {3} },
    smoker        = { input = {1}, fuel = {2}, output = {3} },
    brewer        = { input = {1, 2, 3}, fuel = {4}, output = {5} },
}

local function wrap(name)
    if not peripheral.isPresent(name) then return nil end
    return peripheral.wrap(name)
end

local function getCycles(recipe, count)
    if recipe.type == "station" then
        if recipe.output and recipe.output > 0 then
            return math.ceil(count / recipe.output)
        elseif recipe.fluidOutput and recipe.fluidOutput[1] then
            return math.ceil(count / recipe.fluidOutput[1].mb)
        end
        return count
    else
        return math.ceil(count / (recipe.output or 1))
    end
end

--- Create a machines manager.
function machines.new(peripherals, storage, fluids)
    local self = setmetatable({}, machines)
    self.storage = storage
    self.fluids = fluids
    self.names = {}
    self.jobs = {}
    self.onEvent = nil
    
    self:refreshStations(peripherals)
    return self
end

function machines:setEventHandler(fn)
    self.onEvent = fn
end

local function emit(self, etype, payload)
    if self.onEvent then self.onEvent(etype, payload) end
end

--- Detect capabilities of a peripheral.
function machines:caps(name)
    local p = wrap(name)
    if not p then return { inventory = false, fluid = false, energy = false, type = "none" } end
    local ptype = peripheral.getType(name) or "unknown"
    local hasInv = peripheral.hasType(name, "inventory") or (p.list ~= nil and p.size ~= nil)
    local hasFluid = peripheral.hasType(name, "fluid_storage") or (p.tanks ~= nil)
    local hasEnergy = peripheral.hasType(name, "energy_storage") or (p.getEnergy ~= nil and p.getEnergyCapacity ~= nil)
    return {
        inventory = hasInv,
        fluid = hasFluid,
        energy = hasEnergy,
        type = ptype
    }
end

--- Determine if a peripheral is a processing station.
function machines:isStation(name)
    -- 1. Exclude item storage chests
    if self.storage and self.storage.names then
        for _, sn in ipairs(self.storage.names) do
            if sn == name then return false end
        end
    end
    -- 2. Exclude danks
    if self.fluids and self.fluids.danks then
        for _, dk in ipairs(self.fluids.danks) do
            if dk.periph == name then return false end
        end
    end
    -- 3. Exclude fluid pool tanks
    if self.fluids and self.fluids.pool_names then
        for _, pn in ipairs(self.fluids.pool_names) do
            if pn == name then return false end
        end
    end
    
    -- 4. Must have inventory or fluid capability
    local c = self:caps(name)
    return c.inventory or c.fluid
end

--- Refresh the list of active stations on the network.
function machines:refreshStations(peripherals)
    self.names = {}
    local localMachines = peripherals and peripherals.machines or {}
    local added = {}
    
    if #localMachines > 0 then
        for _, name in ipairs(localMachines) do
            if peripheral.isPresent(name) then
                table.insert(self.names, name)
                added[name] = true
            end
        end
    end
    
    -- Auto-detect all other stations
    for _, name in ipairs(peripheral.getNames()) do
        if not added[name] and self:isStation(name) then
            table.insert(self.names, name)
        end
    end
end

--- Get slot layout for basic vanilla furnaces.
function machines:_slots(name)
    local ptype = peripheral.getType(name)
    if machines.SLOTS[ptype] then
        return machines.SLOTS[ptype], ptype
    end
    local _, base = ptype:match("^([^:]+):(.+)$")
    if base and machines.SLOTS[base] then
        return machines.SLOTS[base], ptype
    end
    local p = wrap(name)
    if not p or not p.size then return nil, ptype end
    local sz = p.size()
    if sz == 3 then
        return { input = {1}, fuel = {2}, output = {3} }, ptype
    elseif sz and sz > 1 then
        return { input = {1}, fuel = {}, output = {sz} }, ptype
    end
    return { input = {1}, fuel = {}, output = {2} }, ptype
end

--- Get machine info including inventory, fluids, energy, and state.
function machines:info(name)
    local p = wrap(name)
    if not p then return nil end
    local slots, ptype = self:_slots(name)
    local c = self:caps(name)
    
    local info = {
        name = name,
        type = ptype,
        slots = slots,
        busy = false,
        cooking = false,
        ready = false,
        input_items = {},
        output_items = {},
        fuel = 0,
        energy = nil,
        tanks = nil,
        inventory_size = 0
    }
    
    -- Read inventory details if present
    if c.inventory and p.list then
        local ok, list = pcall(p.list)
        if ok and list then
            info.inventory_size = p.size() or 0
            -- Only apply slot-based cooking/ready semantics for real furnace-type machines
            local isFurnaceType = (ptype and (
                ptype:find("furnace") or ptype:find("smoker") or
                ptype:find("brewer") or ptype:find("kiln") or
                ptype:find("smelter") or ptype:find("smelt")
            ))
            if isFurnaceType and slots then
                local function isFilled(slot) return list[slot] ~= nil end
                if slots.fuel then
                    for _, s in ipairs(slots.fuel) do
                        if isFilled(s) then info.fuel = info.fuel + 1 end
                    end
                end
                if slots.input then
                    for _, s in ipairs(slots.input) do
                        if isFilled(s) then
                            table.insert(info.input_items, list[s].name)
                            info.cooking = true
                        end
                    end
                end
                if slots.output then
                    for _, s in ipairs(slots.output) do
                        if isFilled(s) then
                            table.insert(info.output_items, list[s].name .. " x" .. list[s].count)
                        end
                    end
                end
                info.busy = info.cooking and #info.output_items == 0
                info.ready = #info.output_items > 0
            else
                -- For generic chest/station: just report what's inside, no cooking semantics
                for slot, item in pairs(list) do
                    if item and item.name then
                        table.insert(info.input_items, item.name)
                    end
                end
                -- A chest-station is "ready" only if a job is in collecting state
                info.cooking = false
                info.ready = false
            end
        end
    end
    
    -- Read fluid details if present
    if c.fluid and p.tanks then
        local ok, tks = pcall(p.tanks)
        if ok and tks then
            info.tanks = tks
            local totalMb = 0
            for _, t in ipairs(tks) do
                totalMb = totalMb + (t.amount or 0)
            end
            if totalMb > 0 and not info.ready then
                info.cooking = true
            end
        end
    end
    
    -- Read energy details if present
    if c.energy then
        local ok, energy = pcall(p.getEnergy)
        local ok2, maxEnergy = pcall(p.getEnergyCapacity)
        if ok and ok2 then
            info.energy = { current = energy, max = maxEnergy }
        end
    end
    
    -- Check if it is currently locked by a job
    for _, job in pairs(self.jobs) do
        if job.name == name and job.state ~= "done" and job.state ~= "error" then
            info.busy = true
            break
        end
    end
    
    return info
end

--- Get status of a machine (alias for info).
machines.status = machines.info

--- List all connected stations with their info.
function machines:list()
    local arr = {}
    for _, name in ipairs(self.names) do
        local inf = self:info(name)
        if inf then table.insert(arr, inf) end
    end
    return arr
end

--- Count of connected stations.
function machines:count()
    return #self.names
end

--- Find a free station matching the type.
function machines:findFree(machineType)
    local function matchType(ptype, mtype)
        if not ptype or not mtype then return false end
        if ptype == mtype or mtype == "any" then return true end
        local p_ns, p_base = ptype:match("^([^:]+):(.+)$")
        local m_ns, m_base = mtype:match("^([^:]+):(.+)$")
        p_base = p_base or ptype
        m_base = m_base or mtype
        if p_ns and m_ns and p_ns ~= m_ns then return false end
        return p_base == m_base
    end

    local function isClaimed(mname)
        for _, job in pairs(self.jobs) do
            if job.name == mname and job.state ~= "done" and job.state ~= "error" then
                return true
            end
        end
        return false
    end

    for _, name in ipairs(self.names) do
        if not isClaimed(name) then
            local ptype = peripheral.getType(name)
            local match = (machineType == nil) or (name == machineType) or matchType(ptype, machineType) or
                          (ptype and machineType and ptype:find(machineType, 1, true) ~= nil)
            if match then
                local inf = self:info(name)
                if inf and not inf.cooking and not inf.ready then
                    return name
                end
            end
        end
    end
    return nil
end

--- Feed items and fluids into the station.
function machines:feed(name, recipe, cycles)
    local ptype = peripheral.getType(name)
    local layout = nil
    if ptype then
        if machines.SLOTS[ptype] then
            layout = machines.SLOTS[ptype]
        else
            local _, base = ptype:match("^([^:]+):(.+)$")
            if base and machines.SLOTS[base] then
                layout = machines.SLOTS[base]
            end
        end
    end

    -- 1. Items
    if recipe.itemInput then
        for idx, ing in ipairs(recipe.itemInput) do
            local need = ing.count * cycles
            local toSlot = layout and layout.input and layout.input[idx] or nil
            local moved = self.storage:extract(ing.id, need, name, toSlot)
            if moved < need then
                return false, "missing " .. (need - moved) .. " " .. ing.id
            end
        end
    elseif recipe.type == "machine" and recipe.input then
        -- Backward-compatibility with old machine recipes
        for idx, ing in ipairs(recipe.input) do
            local need = ing.count * cycles
            local toSlot = layout and layout.input and layout.input[idx] or nil
            local moved = self.storage:extract(ing.id, need, name, toSlot)
            if moved < need then
                return false, "missing " .. (need - moved) .. " " .. ing.id
            end
        end
    end

    -- 2. Fluids
    if recipe.fluidInput then
        for _, fl in ipairs(recipe.fluidInput) do
            local need = fl.mb * cycles
            local moved = self.fluids:extractFluid(fl.fluid, need, name)
            if moved < need then
                return false, "missing " .. (need - moved) .. "mB " .. fl.fluid
            end
        end
    end

    return true
end

--- Check if the expected outputs are present.
function machines:ready(name, recipe, cycles)
    local hasItemOut = recipe.itemOutput and #recipe.itemOutput > 0
    local hasFluidOut = recipe.fluidOutput and #recipe.fluidOutput > 0
    local isOldMachine = (recipe.type == "machine")
    if not hasItemOut and not hasFluidOut and not isOldMachine then
        return nil, "recipe has no defined outputs"
    end

    local p = wrap(name)
    if not p then return false end
    
    -- Check items output
    if recipe.itemOutput and #recipe.itemOutput > 0 then
        if not p.list then return false end
        local ok, list = pcall(p.list)
        if not ok or not list then return false end
        for _, out in ipairs(recipe.itemOutput) do
            local targetCount = out.count * cycles
            local currentCount = 0
            for _, info in pairs(list) do
                if info.name == out.id then
                    currentCount = currentCount + (info.count or 0)
                end
            end
            if currentCount < targetCount then
                return false
            end
        end
    end

    -- Check fluids output
    if recipe.fluidOutput and #recipe.fluidOutput > 0 then
        if not p.tanks then return false end
        local ok, tks = pcall(p.tanks)
        if not ok or not tks then return false end
        for _, out in ipairs(recipe.fluidOutput) do
            local targetMb = out.mb * cycles
            local currentMb = 0
            for _, t in ipairs(tks) do
                local fName = t.name or t.fluid
                if fName == out.fluid then
                    currentMb = currentMb + (t.amount or 0)
                end
            end
            if currentMb < targetMb then
                return false
            end
        end
    end

    -- Fallback for old-style machine recipes
    if recipe.type == "machine" and not recipe.itemOutput then
        local slots = self:_slots(name)
        if not slots then return false end
        if not p.list then return false end
        local ok, list = pcall(p.list)
        if not ok or not list then return false end
        
        local targetId = recipe.id
        local targetCount = (recipe.output or 1) * cycles
        local ptype = (peripheral.getType(name) or ""):lower()
        local isFurnaceType = ptype:find("furnace") or ptype:find("smelt") or ptype:find("cook") or ptype:find("kiln") or ptype:find("smoker") or ptype:find("brewer")
        
        if isFurnaceType and slots.output then
            local currentCount = 0
            for _, s in ipairs(slots.output) do
                local item = list[s]
                if item and item.name == targetId then
                    currentCount = currentCount + (item.count or 0)
                end
            end
            return currentCount >= targetCount
        else
            -- Generic chest/station: check all slots for the target output item
            local currentCount = 0
            for _, item in pairs(list) do
                if item and item.name == targetId then
                    currentCount = currentCount + (item.count or 0)
                end
            end
            return currentCount >= targetCount
        end
    end

    return true
end

--- Collect produced items and fluids back to storage.
function machines:collect(name, recipe)
    local p = wrap(name)
    if not p then return 0 end
    local moved = 0

    -- 1. Collect items
    if p.list then
        local ok, list = pcall(p.list)
        if ok and list then
            -- Build set of input items to avoid pulling them
            local inputs = {}
            if recipe.itemInput then
                for _, ing in ipairs(recipe.itemInput) do inputs[ing.id] = true end
            elseif recipe.input then
                for _, ing in ipairs(recipe.input) do inputs[ing.id or ing] = true end
            end
            
            -- Pull output items or anything that is NOT an input ingredient
            for slot, info in pairs(list) do
                if info.name and not inputs[info.name] then
                    local n = self.storage:deposit(name, slot, nil)
                    moved = moved + n
                end
            end
        end
    end

    -- 2. Collect fluids
    if recipe.fluidOutput then
        for _, fo in ipairs(recipe.fluidOutput) do
            local n = self.fluids:depositFluid(name, fo.fluid)
            moved = moved + n
        end
    end

    -- 3. Drain residual input fluids (P9)
    if recipe.fluidInput then
        for _, fi in ipairs(recipe.fluidInput) do
            self.fluids:depositFluid(name, fi.fluid)
        end
    end

    return moved
end

--- Submit a processing job asynchronously.
function machines:submit(recipe, count, onDone)
    local machineName = self:findFree(recipe.machine)
    if not machineName then
        return nil, "no free machine of type " .. tostring(recipe.machine)
    end
    
    local jobId = "job_" .. math.floor(os.clock() * 1000) .. "_" .. math.random(1, 1000)
    self.jobs[jobId] = {
        id = jobId,
        name = machineName,
        recipe = recipe,
        count = count,
        state = "feeding",
        started_at = os.clock(),
        deadline = nil,
        onDone = onDone
    }
    
    emit(self, "machine_start", { name = machineName, recipe = recipe.id, count = count })
    return jobId
end

--- Tick the asynchronous FSM of active jobs.
function machines:tick()
    for jobId, job in pairs(self.jobs) do
        local cycles = getCycles(job.recipe, job.count)
        
        -- Initialize job metrics
        job.total_cycles = job.total_cycles or cycles
        job.cycles_done = job.cycles_done or 0
        job.total_moved = job.total_moved or 0
        
        -- Calculate maxCycles chunk size based on recipe inputs and outputs
        local maxCycles = 64
        local recipe = job.recipe
        if recipe.itemInput then
            for _, ing in ipairs(recipe.itemInput) do
                local limit = math.floor(64 / math.max(1, ing.count or 1))
                maxCycles = math.min(maxCycles, limit)
            end
        elseif recipe.input then
            for _, ing in ipairs(recipe.input) do
                local icount = type(ing) == "table" and ing.count or 1
                local limit = math.floor(64 / math.max(1, icount))
                maxCycles = math.min(maxCycles, limit)
            end
        end
        if recipe.itemOutput then
            for _, out in ipairs(recipe.itemOutput) do
                local limit = math.floor(64 / math.max(1, out.count or 1))
                maxCycles = math.min(maxCycles, limit)
            end
        elseif recipe.output then
            local limit = math.floor(64 / math.max(1, recipe.output))
            maxCycles = math.min(maxCycles, limit)
        end
        maxCycles = math.max(1, maxCycles)
        
        if job.state == "feeding" then
            local chunk = math.min(maxCycles, job.total_cycles - job.cycles_done)
            job.current_chunk = chunk
            local ok, err = self:feed(job.name, job.recipe, chunk)
            if ok then
                job.state = "processing"
                job.started_at = os.clock()
                local avgTime = job.recipe.avgTime or 10
                job.deadline = os.clock() + math.max(30, chunk * avgTime * 3)
            else
                job.state = "error"
                emit(self, "machine_error", { name = job.name, error = err })
                if job.onDone then job.onDone(false, err) end
                self.jobs[jobId] = nil
            end
            
        elseif job.state == "processing" then
            local isReady, err = self:ready(job.name, job.recipe, job.current_chunk)
            if err then
                job.state = "error"
                emit(self, "machine_error", { name = job.name, error = err })
                if job.onDone then job.onDone(false, err) end
                self.jobs[jobId] = nil
            elseif isReady then
                job.state = "collecting"
            elseif os.clock() > job.deadline then
                job.state = "error"
                local err = "processing timeout"
                emit(self, "machine_error", { name = job.name, error = err })
                if job.onDone then job.onDone(false, err) end
                self.jobs[jobId] = nil
            end
            
        elseif job.state == "collecting" then
            local moved = self:collect(job.name, job.recipe)
            local elapsed = os.clock() - job.started_at
            if elapsed < 0 then elapsed = 0 end
            
            job.total_moved = job.total_moved + moved
            job.cycles_done = job.cycles_done + job.current_chunk
            
            if job.cycles_done < job.total_cycles then
                job.state = "feeding"
            else
                job.state = "done"
                emit(self, "machine_done", { name = job.name, recipe = job.recipe.id, count = job.total_moved })
                if job.onDone then job.onDone(true, job.total_moved, elapsed, job.total_cycles) end
                self.jobs[jobId] = nil
            end
        end
    end
end

--- Unused in asynchronous mode but kept for backward compatibility signature
function machines:process(recipe, count)
    error("synchronous process() is deprecated, use submit()")
end

--- Collect outputs of any ready machines that are NOT in a job (for manual extraction support).
function machines:collectReady()
    local total = 0
    for _, name in ipairs(self.names) do
        -- Skip machines claimed by active jobs
        local claimed = false
        for _, job in pairs(self.jobs) do
            if job.name == name then claimed = true; break end
        end
        
        if not claimed then
            local inf = self:info(name)
            if inf and inf.ready then
                -- Try to find out what output it has
                local p = wrap(name)
                if p and p.list then
                    local ok, list = pcall(p.list)
                    if ok and list then
                        for slot, info in pairs(list) do
                            if info.name then
                                local n = self.storage:deposit(name, slot, nil)
                                total = total + n
                            end
                        end
                    end
                end
            end
        end
    end
    return total
end

return machines
