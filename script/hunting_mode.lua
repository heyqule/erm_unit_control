local HuntingMode = {}

-- This table will store shared data for each group
local group_hunt_data = {}
-- How often (in ticks) a group can search for a NEW enemy
local ENEMY_SEARCH_COOLDOWN = 60 -- 1 second
-- How often (in ticks) a group can search for a NEW patrol point
local PATROL_COOLDOWN = 300 -- 5 seconds

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
  if not group_hunt_data[group] then
    group_hunt_data[group] = {
      target = nil,
      destination = nil,
      next_enemy_search_tick = 0,
      next_patrol_tick = 0,
      aggro_target = nil -- Add new field
    }
  end
  
  -- Set this attacker as the new high-priority target for the whole group
  group_hunt_data[group].aggro_target = attacker
end
-- ===================================================================
-- ## END OF NEW FUNCTION ##
-- ===================================================================


--[[
This function is called by process_command_queue.
It finds the nearest enemy and issues an attack command.
If no enemy is found, it coordinates with the group to patrol.
]]
function HuntingMode.update(unit_data, set_command_func, set_unit_idle_func)
  local unit = unit_data.entity
  if not (unit and unit.valid) then return end
  
  local group = unit_data.group
  if not group then 
    -- This unit is orphaned, stop hunting.
    set_unit_idle_func(unit_data)
    return 
  end

  -- Get or create the shared data for this group
  if not group_hunt_data[group] then
    group_hunt_data[group] = {
      target = nil,
      destination = nil,
      next_enemy_search_tick = 0,
      next_patrol_tick = 0,
      aggro_target = nil -- Add new field
    }
  end
  local data = group_hunt_data[group]

  -- ================================================================
  -- ## NEW PRIORITY 1: CHECK AGGRO TARGET ##
  -- This is the highest priority, from being attacked
  -- ================================================================
  local aggro_target = data.aggro_target
  if aggro_target then
    if aggro_target.valid then
      -- We have a high-priority target from being attacked!
      data.target = nil -- Clear any *lower* priority search target
      data.destination = nil -- Clear any patrol destination
      data.next_patrol_tick = 0
      
      set_command_func(unit_data, {
        type = defines.command.attack,
        target = aggro_target,
        distraction = defines.distraction.by_enemy
      })
      return -- IMPORTANT: Skip all other logic
    else
      -- The aggro target is dead or invalid, clear it so we can go back to normal logic
      data.aggro_target = nil
    end
  end
  -- ================================================================
  -- (End of new priority check)
  -- ================================================================


  -- 1. Check for a valid, cached *search* target (This is now Priority 2)
  local target = data.target
  if target and not target.valid then
    target = nil -- Target is dead, clear it
    data.target = nil
  end
  
  -- 2. If no target, and cooldown is over, search for one (ONE TIME for the group)
  if not target and game.tick > data.next_enemy_search_tick then
    target = unit.surface.find_nearest_enemy({
      position = unit.position,
      -- Use vision_distance to only seek *visible* enemies
      max_distance = unit.prototype.vision_distance, 
      force = unit.force
    })
    
    data.target = target
    data.next_enemy_search_tick = game.tick + ENEMY_SEARCH_COOLDOWN -- Reset cooldown *after* search
  end

  -- 3. We now have a decision: Attack or Patrol
  if target then
    -- 4. VISIBLE ENEMY FOUND: Attack it.
    data.destination = nil -- Clear any patrol destination
    data.next_patrol_tick = 0
    
    set_command_func(unit_data, {
      type = defines.command.attack,
      target = target,
      distraction = defines.distraction.by_enemy
    })
  else
    -- 5. NO VISIBLE ENEMY FOUND: Patrol (Scout).
    
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
      radius = 10
    })
  end
end

return HuntingMode