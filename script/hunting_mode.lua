local HuntingMode = {}
local storage = storage -- <-- FIX: Get reference to global storage

-- This table will store shared data for each group
-- local group_hunt_data = {} -- <-- FIX: Removed this local table
-- How often (in ticks) a group can search for a NEW enemy
local ENEMY_SEARCH_COOLDOWN = 60 -- 1 second
-- How often (in ticks) a group can search for a NEW patrol point
local PATROL_COOLDOWN = 300 -- 5 seconds
-- How far to scan for local enemies to "finish the fight"
local LOCAL_COMBAT_RANGE = 80 -- Same as QRF mode
-- How long to pause *after combat* to let stragglers catch up
local REGROUP_DURATION = 600 -- 10 seconds


--[[
Finds a patrol destination, prioritizing uncharted chunks.
This is used to create a shared destination for the whole group.
]]
local function get_hunt_destination(unit)
  local surface = unit.surface
  local force = unit.force
  
  -- Try to find an uncharted chunk, just like scout
  local chunk_x = math.floor(unit.position.x / 32)
  local chunk_y = math.floor(unit.position.y / 32)
  local scout_range = 10 -- Look 10 chunks away
  
  local uncharted_chunks = {}
  local is_charted = force.is_chunk_charted
  
  for X = -scout_range, scout_range do
    for Y = -scout_range, scout_range do
      local chunk_pos = {x = chunk_x + X, y = chunk_y + Y}
      -- Check if chunk is valid (not out of bounds) before checking if charted
      if surface.is_chunk_generated(chunk_pos) and not is_charted(surface, chunk_pos) then
        table.insert(uncharted_chunks, chunk_pos)
      end
    end
  end
  
  local dest_chunk
  if #uncharted_chunks > 0 then
    -- Go to a random uncharted chunk
    dest_chunk = uncharted_chunks[math.random(#uncharted_chunks)]
  else
    -- No uncharted chunks, pick a random direction far away
    local angle = math.random() * 2 * math.pi
    local distance = 1000 + math.random(1000) -- 1k-2k tiles
    dest_chunk = {
      x = math.floor((unit.position.x + (math.cos(angle) * distance)) / 32),
      y = math.floor((unit.position.y + (math.sin(angle) * distance)) / 32)
    }
  end
  
  -- Pick a random point inside that chunk
  local dest_pos = {
    x = (dest_chunk.x * 32) + math.random(1, 32),
    y = (dest_chunk.y * 32) + math.random(1, 32)
  }
  
  -- Find the closest valid position to that random point
  return surface.find_non_colliding_position(unit.name, dest_pos, 0, 20) or dest_pos
end

-- ===================================================================
-- ## NEW FUNCTION ##
-- Called by unit_control.lua when a unit is damaged
-- ===================================================================
function HuntingMode.register_attacker(unit_data, attacker)
  if not (unit_data and unit_data.group) then return end
  
  local group = unit_data.group
  
  -- Get or create the shared data for this group
  -- FIX: Changed 'group_hunt_data' to 'storage.unit_control.group_hunt_data'
  if not storage.unit_control.group_hunt_data[group] then
    storage.unit_control.group_hunt_data[group] = {
      target = nil,
      destination = nil,
      next_enemy_search_tick = 0,
      next_patrol_tick = 0,
      aggro_target = nil,
      last_combat_tick = 0,
      regroup_position = nil -- Add new field
    }
  end
  
  -- Set this attacker as the new high-priority target for the whole group
  -- FIX: Changed 'group_hunt_data' to 'storage.unit_control.group_hunt_data'
  storage.unit_control.group_hunt_data[group].aggro_target = attacker
  storage.unit_control.group_hunt_data[group].regroup_position = attacker.position -- Log combat location
end
-- ===================================================================
-- ## END OF NEW FUNCTION ##
-- ===================================================================


--[[
This function is called by process_command_queue.
It prioritizes combat, then scouting.
]]
function HuntingMode.update(unit_data, set_command_func, set_unit_idle_func, event) -- ## MODIFIED: Added 'event'
  local unit = unit_data.entity
  if not (unit and unit.valid) then return end
  
  -- ## FIX: ADD THESE LINES ##
  local group = unit_data.group
  if not group then 
    -- This unit is orphaned, stop hunting.
    set_unit_idle_func(unit_data)
    return 
  end
  -- ## END OF FIX ##
  
  -- Get or create the shared data for this group
  -- FIX: Changed 'group_hunt_data' to 'storage.unit_control.group_hunt_data'
  if not storage.unit_control.group_hunt_data[group] then
    storage.unit_control.group_hunt_data[group] = {
      target = nil,
      destination = nil,
      next_enemy_search_tick = 0,
      next_patrol_tick = 0,
      aggro_target = nil,
      last_combat_tick = 0,
      regroup_position = nil -- Add new field
    }
  end
  -- FIX: Changed 'group_hunt_data' to 'storage.unit_control.group_hunt_data'
  local data = storage.unit_control.group_hunt_data[group]
  local unit_force = unit.force

  -- ================================================================
  -- ## NEW BLOCK: Check if we just finished combat from a distraction ##
  -- ================================================================
  if event and event.was_distracted then
    -- This unit was distracted by an enemy (from Priority 5's "attack-move").
    -- This means it was just in combat.
    data.last_combat_tick = game.tick
    -- We don't know *what* it killed, but its current position is the combat area.
    data.regroup_position = unit.position 
  end
  -- ================================================================

  -- ================================================================
  -- ## PRIORITY 1: AGGRO TARGET (Retaliation) ##
  -- This is the highest priority, from being attacked
  -- ================================================================
  local aggro_target = data.aggro_target
  if aggro_target then
    if aggro_target.valid then
      -- We have a high-priority target from being attacked!
      data.target = nil -- Clear any *lower* priority search target
      data.destination = nil -- Clear any patrol destination
      data.last_combat_tick = game.tick -- Mark that we are in combat
      data.regroup_position = aggro_target.position -- Log combat location
      
      set_command_func(unit_data, {
        type = defines.command.attack,
        target = aggro_target,
        distraction = defines.distraction.by_enemy
      })
      return -- IMPORTANT: Skip all other logic
    else
      -- The aggro target is dead or invalid, clear it
      data.aggro_target = nil
    end
  end

  -- ================================================================
  -- ## PRIORITY 2: 960-TILE SEARCH (Find Nests) ##
  -- Check for large-scale targets
  -- ================================================================
  -- Check/clear cached target
  if data.target and not data.target.valid then
    data.target = nil
  end

  -- If no cached target, and cooldown is over, search for one
  if not data.target and game.tick > data.next_enemy_search_tick then
    data.target = unit.surface.find_nearest_enemy({
      position = unit.position,
      max_distance = 960, 
      force = unit_force
    })
    data.next_enemy_search_tick = game.tick + ENEMY_SEARCH_COOLDOWN
  end
  
  -- If we found a distant target, attack it
  if data.target then
    data.destination = nil -- Clear any patrol destination
    data.last_combat_tick = game.tick -- Mark that we are in combat
    data.regroup_position = data.target.position -- Log combat location
    
    set_command_func(unit_data, {
      type = defines.command.attack,
      target = data.target,
      distraction = defines.distraction.by_enemy
    })
    return
  end
  
  -- ================================================================
  -- ## PRIORITY 3: LOCAL COMBAT SCAN (Finish the Fight) ##
  -- This handles "attack-move" distractions and cleaning up
  -- ================================================================
  local nearby_enemy = unit.surface.find_nearest_enemy({
    position = unit.position,
    max_distance = LOCAL_COMBAT_RANGE,
    force = unit_force
  })
  
  if nearby_enemy then
    -- Found a local enemy to clean up
    data.destination = nil -- Clear any patrol destination
    data.last_combat_tick = game.tick -- Mark that we are in combat
    data.regroup_position = nearby_enemy.position -- Log combat location
    
    set_command_func(unit_data, {
      type = defines.command.attack,
      target = nearby_enemy,
      distraction = defines.distraction.by_enemy
    })
    return
  end
  
  -- ================================================================
  -- ## PRIORITY 4: REGROUP PHASE (Wait for Stragglers) ##
  -- No enemies found. If we were *just* in combat, pause and regroup.
  -- ================================================================
  if data.last_combat_tick > 0 and data.regroup_position then
    if game.tick < data.last_combat_tick + REGROUP_DURATION then
      -- We are in the 10-second regroup phase.
      data.destination = nil -- Clear any old patrol destination
      
      -- Tell unit to go to the regroup spot and wait.
      -- This forces stragglers to catch up and others to wait.
      set_command_func(unit_data, {
        type = defines.command.go_to_location,
        destination = data.regroup_position,
        distraction = defines.distraction.never, -- Don't get distracted
        radius = 3 -- Cluster up tightly
      })
      return
    else
      -- Regroup time is over.
      data.last_combat_tick = 0
      data.regroup_position = nil
    end
  end

  -- ================================================================
  -- ## PRIORITY 5: PATROL (Scout) ##
  -- No combat, no cooldown. Time to find a new place to scout.
  -- ================================================================
  
  -- Check if we need a new patrol destination
  if not data.destination or game.tick > data.next_patrol_tick then
    data.destination = get_hunt_destination(unit)
    data.next_patrol_tick = game.tick + PATROL_COOLDOWN
  end
  
  -- Issue the patrol command
  set_command_func(unit_data, {
    type = defines.command.go_to_location,
    destination = data.destination,
    distraction = defines.distraction.by_anything, -- "attack-move" stance
    radius = 5 -- Good compromise for large groups
  })
end

return HuntingMode