-- This module handles issuing commands, processing the command queue,
-- and the logic for different command types (scout, hunt, etc.)

local Core = require("script/uc_core")
local Indicators = require("script/uc_indicators")
local HuntingMode = require("hunting_mode")
local PerimeterMode = require("perimeter_mode")

local Commands = {}

local next_command_type = Core.next_command_type

-- Tells a unit to perform a specific Factorio command (like 'go_to_location')
-- It also updates our internal unit_data state.
function Commands.set_command(unit_data, command)
  local unit = unit_data.entity
  
  -- FIX: Check for unit validity *first*
  if not (unit and unit.valid) then return end
  
  Indicators.remove_target_indicator(unit_data)
  
  unit_data.command = command
  unit_data.destination = command.destination
  unit_data.distraction = command.distraction
  unit_data.destination_entity = command.destination_entity
  unit_data.target = command.target
  unit_data.in_group = nil
  unit.speed = command.speed or unit.prototype.speed
  unit.ai_settings.path_resolution_modifier = command.path_resolution_modifier or -2
  unit.ai_settings.do_separation = command.do_separation or true
  unit.commandable.set_command(command)
  return Indicators.add_unit_indicators(unit_data)
end

-- If a unit fails a command (e.g., pathfinding), this tries again
-- with a slightly higher path resolution.
local retry_command = function(unit_data)
  local unit = unit_data.entity
  unit.ai_settings.path_resolution_modifier = math.min(unit.ai_settings.path_resolution_modifier + 1, 3)
  return pcall(unit.commandable.set_command, unit_data.command)
end

-- Stops the unit and sets it to an 'idle' or 'wander' state
function Commands.set_unit_idle(unit_data)
  local idle_command = {type = defines.command.wander, radius = 0.5, distraction = unit_data.distraction}
  unit_data.idle = true
  unit_data.command_queue = {}
  unit_data.destination = nil
  unit_data.distraction = nil
  unit_data.target = nil
  unit_data.mode = nil
  unit_data.original_position = nil
  unit_data.aggro_target = nil
  local unit = unit_data.entity
  if unit.type == "unit" then
    unit.ai_settings.do_separation = true
    Commands.set_command(unit_data, idle_command)
  end
  return Indicators.add_unit_indicators(unit_data)
end

-- Marks a unit as 'not idle' (i.e., it has a command)
function Commands.set_unit_not_idle(unit_data)
  unit_data.idle = false
  return Indicators.add_unit_indicators(unit_data)
end

local scout_queue = {command_type = next_command_type.scout}
-- Handles the 'scout' command logic, finding uncharted
-- or unseen chunks for the unit to move to.
function Commands.set_scout_command(unit_data, failure, delay)
  unit_data.command_queue = {scout_queue}
  local unit = unit_data.entity
  if unit.type ~= "unit" then return end
  if failure and unit_data.fail_count > 10 then
    unit_data.fail_count = nil
    return Commands.set_unit_idle(unit_data, true)
  end
  if delay and delay > 0 then
    return Commands.set_command(unit_data,
    {
      type = defines.command.stop,
      ticks_to_wait = delay
    })
  end

  local position = unit.position
  local surface = unit.surface
  local chunk_x = math.floor(position.x / 32)
  local chunk_y = math.floor(position.y / 32)
  local map_chunk_width = surface.map_gen_settings.width / 64
  local map_chunk_height = surface.map_gen_settings.height / 64
  local in_map = function(chunk_position)
    if map_chunk_width > 0 and (chunk_position.x > map_chunk_width or chunk_position.x < -map_chunk_width) then
      return false
    end
    if map_chunk_height > 0 and (chunk_position.y > map_chunk_height or chunk_position.y < -map_chunk_height) then
      return false
    end
    return true
  end
  local insert = table.insert
  local scout_range = 6
  local visible_chunks = {}
  local non_visible_chunks = {}
  local uncharted_chunks = {}
  local checked = {}
  local force = unit.force
  local is_charted = force.is_chunk_charted
  local is_visible = force.is_chunk_visible
  for X = -scout_range, scout_range do
    for Y = -scout_range, scout_range do
      local chunk_position = {x = chunk_x + X, y = chunk_y + Y}
      if in_map(chunk_position) then
        if (not is_charted(surface, chunk_position)) then
          insert(uncharted_chunks, chunk_position)
        elseif (not is_visible(surface, chunk_position)) then
          insert(non_visible_chunks, chunk_position)
        else
          insert(visible_chunks, chunk_position)
        end
      end
    end
  end
  local chunk
  local tile_destination
  local remove = table.remove
  local random = math.random
  local find_non_colliding_position = surface.find_non_colliding_position
  local name = unit.name
  repeat
    local index
    if not failure and #uncharted_chunks > 0 then
      index = random(#uncharted_chunks)
      chunk = uncharted_chunks[index]
      remove(uncharted_chunks, index)
      tile_destination = find_non_colliding_position(name, {(chunk.x * 32) + random(32), (chunk.y * 32) + random(32)}, 0, 4)
    elseif not failure and #non_visible_chunks > 0 then
      index = random(#non_visible_chunks)
      chunk = non_visible_chunks[index]
      remove(non_visible_chunks, index)
      tile_destination = find_non_colliding_position(name, {(chunk.x * 32) + random(32), (chunk.y * 32) + random(32)}, 0, 4)
    elseif #visible_chunks > 0 then
      index = random(#visible_chunks)
      chunk = visible_chunks[index]
      remove(visible_chunks, index)
      tile_destination = find_non_colliding_position(name, {(chunk.x * 32) + random(32), (chunk.y * 32) + random(32)}, 0, 4)
    else
      tile_destination = find_non_colliding_position(name, force.get_spawn_position(surface), 0, 4)
    end
  until tile_destination
  
  return Commands.set_command(unit_data,
  {
    type = defines.command.go_to_location,
    distraction = defines.distraction.by_anything,
    destination = tile_destination,
    radius = 1,
    pathfind_flags =
    {
      allow_destroy_friendly_entities = false,
      cache = true,
      low_priority = true
    }
  })
end

-- Adds a unit to a list to be processed for an attack command
function Commands.register_to_attack(unit_data)
  local script_data = storage.unit_control
  table.insert(script_data.attack_register, unit_data)
end

local hold_position_command = {type = defines.command.stop, speed = 0}

local type_handlers = {
  [next_command_type.move] = function(data)
    -- This handler is called when a 'move' command is at the front
    -- of the queue (e.g., after a previous command completed).
    local unit_data = data.unit_data
    local command_to_run = data.next_command -- This is the next waypoint
    
    -- 1. Remove this command from the *pending* queue
    table.remove(unit_data.command_queue, 1)
    
    -- 2. Execute it, making it the new *active* command for the unit
    -- The 'event' parameter is nil here, so process_command_queue
    -- will check the queue again when this new command completes.
    Commands.set_command(unit_data, command_to_run)
  end,
  [next_command_type.patrol] = function(data)
    local unit_data = data.unit_data
    local next_command = data.next_command
    local entity = data.entity
    if next_command.destination_index == "initial" then
      next_command.destinations[1] = entity.position
      next_command.destination_index = 2
    else
      next_command.destination_index = next_command.destination_index + 1
    end
    local next_destination = next_command.destinations[next_command.destination_index]
    if not next_destination then
      next_command.destination_index = 1
      next_destination = next_command.destinations[next_command.destination_index]
    end
    local script_data = storage.unit_control
    local wait_time = math.random(script_data.min_patrol_unit_wait_time, script_data.max_patrol_unit_wait_time)
    local commands = {
      type = defines.command.compound,
      structure_type = defines.compound_command.logical_and,
      commands = {
        {
          type = defines.command.go_to_location,
          destination = entity.surface.find_non_colliding_position(entity.name, next_destination, 0, 0.5) or entity.position,
          radius = 1,
          distraction = next_command.distraction
        },
        {
          type = defines.command.stop,
          ticks_to_wait = wait_time,
        }
      }
    }
    Commands.set_command(unit_data,commands)
  end,
  [next_command_type.attack] = function(data)
    local unit_data = data.unit_data
    Commands.register_to_attack(unit_data)
  end,
  [next_command_type.idle] = function(data)
    local unit_data = data.unit_data
    unit_data.command_queue = {}
    Commands.set_unit_idle(unit_data, true)
  end,
  [next_command_type.scout] = function(data)
    local unit_data = data.unit_data
    local event = data.event
    Commands.set_scout_command(unit_data, event.result == defines.behavior_result.fail)
  end,
  [next_command_type.hunt] = function(data)
    local unit_data = data.unit_data
    local event = data.event
    HuntingMode.update(unit_data, Commands.set_command, Commands.set_unit_idle, event)
  end,
  [next_command_type.perimeter] = function(data)
    local unit_data = data.unit_data
    PerimeterMode.update(unit_data, Commands.set_command, Commands.set_unit_idle)
  end,
  [next_command_type.hold_position] = function(data)
    local unit_data = data.unit_data
    Commands.set_command(unit_data, hold_position_command)
  end,
  [next_command_type.follow] = function(data)
    local unit_data = data.unit_data
    Commands.unit_follow(unit_data)
  end
}

-- This is the core logic that runs when a unit finishes a command.
-- It checks the unit's `command_queue` and issues the next command
-- (e.g., move, patrol, hunt, etc.).
function Commands.process_command_queue(unit_data, event)
  local entity = unit_data.entity
  if not (entity and entity.valid) then
    if event then
      local script_data = storage.unit_control
      script_data.units[event.unit_number] = nil
    end
    return
  end
  local failed = (event and event.result == defines.behavior_result.fail)

  if failed then
    unit_data.fail_count = (unit_data.fail_count or 0) + 1
    if unit_data.fail_count < 5 then
      if retry_command(unit_data) then
        return
      end
    end
  end

  local command_queue = unit_data.command_queue
  local next_command = command_queue[1]

  -- If no more commands, go idle
  if not (next_command) then
    entity.ai_settings.do_separation = true
    if not unit_data.idle then
      Commands.set_unit_idle(unit_data)
    end
    return
  end

  local type = next_command.command_type

  if type_handlers[type] then
    type_handlers[type]({
      unit_data = unit_data,
      entity = entity,
      event = event,
      next_command = next_command
    })
  end
end

-- Assigns attack targets for a group, finding the closest enemy for each unit
local bulk_attack_closest = function(entities, group)
  for k, entity in pairs (entities) do
    if not (entity.valid and (entity.get_health_ratio() or 0) > 0) then
      entities[k] = nil
    end
  end

  local index, top = next(entities)
  if not index then
    for k, unit_data in pairs (group) do
      table.remove(unit_data.command_queue, 1)
      Commands.process_command_queue(unit_data)
    end
    return
  end

  local get_closest = top.surface.get_closest

  local command =
  {
    type = defines.command.attack,
    distraction = defines.distraction.none,
    do_separation = true,
    target = false
  }

  for k, unit_data in pairs (group) do
    local unit = unit_data.entity
    if unit.valid then
      command.target = get_closest(unit.position, entities)
      Indicators.draw_temp_attack_indicator(command.target, unit_data.player)
      Commands.set_command(unit_data, command)
    end
  end
end

local wants_enemy_attack =
{
  [defines.distraction.by_enemy] = true,
  [defines.distraction.by_anything] = true
}

local select_distraction_target = function(unit)
  local command = unit.commandable.command
  local distraction = (command and command.distraction) or defines.distraction.by_enemy

  if not wants_enemy_attack[distraction] then
    return
  end

  local params =
  {
    position = unit.position,
    max_distance = unit.prototype.vision_distance,
    force = unit.force
  }

  local surface = unit.surface
  return surface.find_nearest_enemy(params) or (distraction == defines.distraction.by_anything and surface.find_nearest_enemy_entity_with_owner(params))

end

function Commands.process_distraction_completed(event)
  local script_data = storage.unit_control
  local unit_data = script_data.units[event.unit_number]
  if not unit_data then return end
  -- Do nothing if the unit is from a hunting group.
  if unit_data.group then
    local group_hunt_data = script_data.group_hunt_data[unit_data.group]
    if group_hunt_data then
      return
    end
  end
  
  local unit = unit_data.entity
  if not (unit and unit.valid) then return end

  local enemy = select_distraction_target(unit)

  if not enemy then return end

  unit.commandable.set_distraction_command
  {
    type = defines.command.attack,
    target = enemy
  }
  
  return true
end

-- Periodically processes the list of units waiting to attack
function Commands.process_attack_register(tick)
  if tick % 31 ~= 0 then return end
  local script_data = storage.unit_control
  local register = script_data.attack_register
  if not next(register) then return end
  script_data.attack_register = {}

  local groups = {}

  for k, unit_data in pairs (register) do
    local command = unit_data.command_queue[1]
    if command then
      local targets = command.targets
      if targets then
        groups[targets] = groups[targets] or {}
        table.insert(groups[targets], unit_data)
      else
        -- This is for our new Hunting Mode
        groups[unit_data.group] = groups[unit_data.group] or {}
        table.insert(groups[unit_data.group], unit_data)
      end
    end
  end

  for entities, group in pairs (groups) do
    local target_list
    if type(entities) == "table" then
      target_list = entities
    else
      -- This is for a hunting group. Find a nearby enemy.
      local group_leader = next(group)
      if group_leader and group_leader.entity and group_leader.entity.valid then
        local target = group_leader.entity.surface.find_nearest_enemy({
          position = group_leader.entity.position,
          max_distance = 960,
          force = group_leader.entity.force,
        })
        if target then
          target_list = {target}
        end
      end
    end
    
    if target_list then
      bulk_attack_closest(target_list, group)
    else
      -- No enemies found, tell the group to process its queue
      for k, unit_data in pairs (group) do
        Commands.process_command_queue(unit_data)
      end
    end
  end
end

-- Calculates positions for a unit formation (spiral pattern)
local turn_rate = (math.pi * 2) / 1.618
local size_scale = 1
function Commands.get_move_offset(n, size)
  n = n % 90
  local move_offset_positions = storage.unit_control.move_offset_positions
  local size = (size or 1) * size_scale
  local position = move_offset_positions[n]
  if position then
    -- FIX: Return a new table, not the cached one
    return {
      x = position.x * size,
      y = position.y * size
    }
  end
  position = {}
  position.x = math.sin(n * turn_rate)* (n ^ 0.5)
  position.y = math.cos(n * turn_rate) * (n ^ 0.5)
  move_offset_positions[n] = position
  -- FIX: Return a new table
  return {
    x = position.x * size,
    y = position.y * size
  }
end

-- Logic for the 'follow' command
function Commands.unit_follow(unit_data)
  local command = unit_data.command_queue[1]
  if not command then return end
  local target = command.target
  if not (target and target.valid) then
    return
  end

  local unit = unit_data.entity
  if unit == target then
    Commands.set_command(unit_data, {type = defines.command.stop})
    return
  end
  local script_data = storage.unit_control.follow_unit_wait_time
  local accept_range = 24
  local wait_time = math.random(script_data.min_follow_unit_wait_time, script_data.max_follow_unit_wait_time)

  if Core.distance(target.position, unit.position) > accept_range then
    Commands.set_command(unit_data,
            {
              type = defines.command.compound,
              structure_type = defines.compound_command.logical_and,
              commands = {
                {
                  type = defines.command.go_to_location,
                  destination_entity = target,
                  radius = accept_range
                },
                {
                  type = defines.command.stop,
                  ticks_to_wait = wait_time,
                  --radius = accept_range ,
                }
              }
            })

    return
  end
  local offset = Commands.get_move_offset(unit.unit_number, unit.get_radius())
  Commands.set_command(unit_data,
          {
            type = defines.command.compound,
            structure_type = defines.compound_command.logical_and,
            commands = {
              {
                type = defines.command.go_to_location,
                destination = {target.position.x + offset.x, target.position.y + offset.y},
                radius = accept_range,
              },
              {
                type = defines.command.wander,
                ticks_to_wait = wait_time,
                radius = accept_range,
              }
            }
          })
end

return Commands