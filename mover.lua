-- The mover: all item moves go through here. The server locks an item while it moves and how fast it
-- answers can't be known from the client's files, so this measures rather than assumes: it moves a
-- batch of unrelated slots, waits for all of them to unlock, and takes a bigger batch next time, or
-- a smaller one if the client complains. It checks each slot still holds what the plan expected,
-- pauses for combat and for a player holding an item, and carries on when they're done.
--
-- It only ever picks up and places, never UseContainerItem: "use" drinks the potion if the bank has
-- just closed, while placing onto a closed bank fails and the item goes back.

local Core = NorgannonCore
local D = Dimension
if D.disabled then return end

local Mover = {}
D.Mover = Mover

local TICK = .05             -- seconds between looks while a job runs
local START_BATCH, MAX_BATCH = 4, 12
local UNLOCK_TIMEOUT = 3     -- seconds before a move that hasn't finished counts as stuck
local MAX_RETRIES = 2

local frame = CreateFrame("Frame")
frame:Hide()
local job
local elapsed = 0

local function slotKey(bag, slot) return bag .. ":" .. slot end

local function isLocked(bag, slot)
  local info = D.Read(bag, slot)
  return info and info.isLocked
end

local function finish(reason)
  local done = job
  job = nil
  frame:Hide()
  if not done then return end
  local seconds = GetTime() - done.started
  if done.moved > 0 and seconds > 0 then
    D.db.probe.mover = { moves = done.moved, seconds = seconds, batch = done.batch, at = D.Now() }
  end
  D:Changed()
  if done.onDone then Core.SafeCall(done.onDone, reason, done.moved, done.skipped) end
end

---Runs a list of moves: { { from = {bag, slot}, to = {bag, slot}, id, count? } }. `count` splits a
---stack, otherwise the whole stack goes. opts: { label, bank = true (stops if the bank closes),
---onDone(reason, moved, skipped) }; reason is nil when it finished. False if a job is running.
function Mover:Run(moves, opts)
  if job then return false end
  opts = opts or {}
  job = { queue = {}, inflight = {}, batch = D.db.moverBatch or START_BATCH, moved = 0, skipped = 0, total = #moves,
    started = GetTime(), label = opts.label, bank = opts.bank, onDone = opts.onDone }
  for i, move in ipairs(moves) do job.queue[i] = move end
  elapsed = TICK
  frame:Show()
  return true
end

function Mover:Cancel(reason)
  if job then finish(reason or "cancelled") end
end

function Mover:Active() return job ~= nil end

---{ label, total, done, paused } for what's running, or nil.
function Mover:Status()
  if not job then return nil end
  return { label = job.label, total = job.total, done = job.moved + job.skipped, paused = job.paused }
end

---One move, in the frame it's checked in, so nothing can change between the check and the act.
---Returns true if it went out, false if it was given up on, nil if it has to wait for a slot.
local function startMove(move, used)
  local fromBag, fromSlot, toBag, toSlot = move.from[1], move.from[2], move.to[1], move.to[2]
  if used[slotKey(fromBag, fromSlot)] or used[slotKey(toBag, toSlot)] then return nil end
  local source = D.Read(fromBag, fromSlot)
  if not source or source.itemID ~= move.id then return false end   -- it isn't there any more
  if source.isLocked or isLocked(toBag, toSlot) then return nil end
  if move.count and move.count < (source.stackCount or 1) then
    D.In("C_Container", "SplitContainerItem", fromBag, fromSlot, move.count)
  else
    D.In("C_Container", "PickupContainerItem", fromBag, fromSlot)
  end
  if not D.CursorBusy() then return false end
  D.In("C_Container", "PickupContainerItem", toBag, toSlot)
  -- still holding it means the target refused: it goes straight back to where it was
  if D.CursorBusy() then
    D.Global("ClearCursor")
    return false
  end
  used[slotKey(fromBag, fromSlot)] = true
  used[slotKey(toBag, toSlot)] = true
  move.sentAt = GetTime()
  return true
end

local function stillMoving()
  for i = #job.inflight, 1, -1 do
    local move = job.inflight[i]
    if not isLocked(move.from[1], move.from[2]) and not isLocked(move.to[1], move.to[2]) then
      table.remove(job.inflight, i)
      job.moved = job.moved + 1
    elseif GetTime() - move.sentAt > UNLOCK_TIMEOUT then
      table.remove(job.inflight, i)
      job.batch = math.max(1, math.floor(job.batch / 2))
      move.retries = (move.retries or 0) + 1
      if move.retries <= MAX_RETRIES then
        table.insert(job.queue, move)
      else
        job.skipped = job.skipped + 1
      end
    end
  end
  return #job.inflight > 0
end

local function tick()
  if not job then return end
  local reason = D.PauseReason()
  if reason then
    job.paused = reason
    D:Changed()
    return
  end
  if job.paused then
    job.paused = nil
    D:Changed()
  end
  if stillMoving() then return end
  if D.CursorBusy() then return end   -- the player is dragging something; wait for them
  if #job.queue == 0 then
    finish(nil)
    return
  end
  if job.lastBatch and not job.complained then job.batch = math.min(MAX_BATCH, job.batch + 1) end
  job.complained = nil
  local used, sent, i = {}, 0, 1
  while i <= #job.queue and sent < job.batch do
    local move = job.queue[i]
    local result = startMove(move, used)
    if result == true then
      table.remove(job.queue, i)
      job.inflight[#job.inflight + 1] = move
      sent = sent + 1
    elseif result == false then
      table.remove(job.queue, i)
      job.skipped = job.skipped + 1
    else
      i = i + 1
    end
  end
  job.lastBatch = sent
  D.db.moverBatch = job.batch
  D:Changed()
end

frame:SetScript("OnUpdate", function(_, dt)
  elapsed = elapsed + dt
  if elapsed >= TICK then
    elapsed = 0
    tick()
  end
end)

-- an error while moving means too fast: slow down rather than guess a rate
Core:On("UI_ERROR_MESSAGE", "dimension.mover", function()
  if job then
    job.complained = true
    job.batch = math.max(1, math.floor(job.batch / 2))
  end
end)
Core:On("BANKFRAME_CLOSED", "dimension.mover", function()
  if job and job.bank then Mover:Cancel("the bank closed") end
end)
