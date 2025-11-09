local HuntingMode = {}

-- How often (in ticks) a group can search for a NEW enemy
local ENEMY_SEARCH_COOLDOWN = 60 -- 1 second
-- How often (in ticks) a group can search for a NEW patrol point
local PATROL_COOLDOWN = 300 -- 5 seconds
-- How far to scan for local enemies to "finish the fight"
local LOCAL_COMBAT_RANGE = 80
-- How long to pause *after combat* to let stragglers catch up
local REGROUP_DURATION = 600 -- 10 seconds


-- Finds a patrol destination for the group, prioritizing uncharted chunks.
local function get_hunt_destination(unit)
  local surface = unit.surface
  local force = unit.force
  
  -- Try to find an uncharted chunk, like the scout command
  local chunk_x = math.floor(unit.position.x / 32)
  local chunk_y = math.floor(unit.position.y / 32)
  local scout_range = 10 -- Look 10 chunks away
  
  local uncharted_chunks = {}
  local is_charted = force.is_chunk_charted
  
  for X = -scout_range, scout_range do
    for Y = -scout_range, scout_range do
      local chunk_pos = {x = chunk_x + X, y = chunk_y + Y}
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

-- This is called by unit_control.lua when a unit in hunt mode is damaged.
-- It sets the attacker as a high-priority target for the *entire* group.
--[[
-- Disabling this feature to improve performance.
-- This function is called from on_entity_damaged, which can
-- cause performance spikes.
function HuntingMode.register_attacker(unit_data, attacker)
  if not (unit_data and unit_data.group) then return end
  
  local group = unit_data.group
  
  -- Get or create the shared hunt data for this group from the global storage
  if not storage.unit_control.group_hunt_data[group] then
    storage.unit_control.group_hunt_data[group] = {
      target = nil,
      destination = nil,
      next_enemy_search_tick = 0,
      next_patrol_tick = 0,
      aggro_target = nil,
      last_combat_tick = 0,
      regroup_position = nil
    }
  end
  
  -- Set this attacker as the new high-priority target
  storage.unit_control.group_hunt_data[group].aggro_target = attacker
  storage.unit_control.group_hunt_data[group].regroup_position = attacker.position
end
]]


-- This is the main 'update' function for hunt mode, called by process_command_queue.
-- It decides what the unit should be doing (attacking, regrouping, or patrolling).
function HuntingMode.update(unit_data, set_command_func, set_unit_idle_func, event)
  local unit = unit_data.entity
  if not (unit and unit.valid) then return end
  
  -- If the unit got separated from its group, just go idle.
  local group = unit_data.group
  if not group then 
    set_unit_idle_func(unit_data)
    return 
  end
  
  -- Get or create the shared data for this group from global storage
  if not storage.unit_control.group_hunt_data[group] then
    storage.unit_control.group_hunt_data[group] = {
      target = nil,
      destination = nil,
      next_enemy_search_tick = 0,
      next_patrol_tick = 0,
      aggro_target = nil,
      last_combat_tick = 0,
      regroup_position = nil
    }
  end
  local data = storage.unit_control.group_hunt_data[group]
  local unit_force = unit.force

  -- If the unit was just distracted by an enemy, it means it was in combat.
  -- We log this to trigger the "regroup" phase.
  if event and event.was_distracted then
    data.last_combat_tick = game.tick
    data.regroup_position = unit.position 
  end

  -- === PRIORITY 1: AGGRO TARGET (Retaliation) ===
  -- This is the highest priority, from being attacked.
  --[[
  -- Disabling this feature to improve performance.
  -- This relies on data from on_entity_damaged, which is now disabled.
  local aggro_target = data.aggro_target
  if aggro_target then
    if aggro_target.valid then
      -- We have a high-priority target!
      data.target = nil -- Clear any lower-priority target
      data.destination = nil -- Clear any patrol destination
      data.last_combat_tick = game.tick -- Mark as in-combat
      data.regroup_position = aggro_target.position
      
      set_command_func(unit_data, {
        type = defines.command.attack,
        target = aggro_target,
        distraction = defines.distraction.by_enemy
      })
      return -- Skip all other logic
    else
      -- The target is dead, clear it
      data.aggro_target = nil
    end
  end
  ]]

  -- === PRIORITY 2: 960-TILE SEARCH (Find Nests) ===
  -- Look for distant targets like spawners.
  if data.target and not data.target.valid then
    data.target = nil
  end

  -- If no target and cooldown is over, search for one.
  if not data.target and game.tick > data.next_enemy_search_tick then
    data.target = unit.surface.find_nearest_enemy({
      position = unit.position,
      max_distance = 960, 
      force = unit_force
    })
    data.next_enemy_search_tick = game.tick + ENEMY_SEARCH_COOLDOWN
  end
  
  -- If we found a distant target, attack it.
  if data.target then
    data.destination = nil -- Clear patrol destination
    data.last_combat_tick = game.tick
    data.regroup_position = data.target.position
    
    set_command_func(unit_data, {
      type = defines.command.attack,
      target = data.target,
      distraction = defines.distraction.by_enemy
    })
    return
  end
  
  -- === PRIORITY 3: LOCAL COMBAT SCAN (Finish the Fight) ===
  -- Clean up any nearby enemies that were missed.
  local nearby_enemy = unit.surface.find_nearest_enemy({
    position = unit.position,
    max_distance = LOCAL_COMBAT_RANGE,
    force = unit_force
  })
  
  if nearby_enemy then
    data.destination = nil
    data.last_combat_tick = game.tick
    data.regroup_position = nearby_enemy.position
    
    set_command_func(unit_data, {
      type = defines.command.attack,
      target = nearby_enemy,
      distraction = defines.distraction.by_enemy
    })
    return
  end
  
  -- === PRIORITY 4: REGROUP PHASE (Wait for Stragglers) ===
  -- No enemies found. If we were *just* in combat, pause and regroup.
  if data.last_combat_tick > 0 and data.regroup_position then
    if game.tick < data.last_combat_tick + REGROUP_DURATION then
      -- We are in the regroup phase.
      data.destination = nil
      
      -- Tell unit to go to the last combat spot and wait.
      set_command_func(unit_data, {
        type = defines.command.go_to_location,
        destination = data.regroup_position,
        distraction = defines.distraction.never, -- Don't get distracted
        radius = 3 -- Cluster up
      })
      return
    else
      -- Regroup time is over.
      data.last_combat_tick = 0
      data.regroup_position = nil
    end
  end

  -- === PRIORITY 5: PATROL (Scout) ===
  -- No combat, no regrouping. Time to find a new place to scout.
  
  -- Check if we need a new patrol destination
  if not data.destination or game.tick > data.next_patrol_tick then
    data.destination = get_hunt_destination(unit)
    data.next_patrol_tick = game.tick + PATROL_COOLDOWN
  end
  
  -- Issue the patrol command (as an "attack-move")
  set_command_func(unit_data, {
    type = defines.command.go_to_location,
    destination = data.destination,
    distraction = defines.distraction.by_anything,
    radius = 5
  })
end

return HuntingMode