-- This module handles all group movement commands:
-- move, attack-move, patrol, follow, stop, hold position.

local Core = require("script/uc_core")
local Commands = require("script/uc_commands")
local Indicators = require("script/uc_indicators")
-- FIX: Point to the new merged file
local SharedMovement = require('script/uc_shared_movement')
local Selection = require("script/uc_selection_gui_and_groups").Selection 
local util = require("script/script_util")

local Movement = {}

local next_command_type = Core.next_command_type
local tool_names = Core.tool_names

local function unset_selected_unit(player_index)
  local script_data = storage.unit_control
  script_data.selected_units[player_index] = nil
end

-- Issues 'stop' commands to the selected group
function Movement.stop_group(player, queue)
  local group = Selection.get_selected_units(player.index)
  if not group then
    return
  end
  SharedMovement.stop_group(player, queue, group)
end

-- Issues 'hold position' commands to the selected group
function Movement.hold_position_group(player, queue)
  local group = Selection.get_selected_units(player.index)
  if not group then
    return
  end
  SharedMovement.hold_position_group(player, queue, group)
end

-- Calculates positions for a unit formation (spiral pattern)
local turn_rate = (math.pi * 2) / 1.618
local size_scale = 1
local get_move_offset = function(n, size)
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

local path_flags =
{
  allow_destroy_friendly_entities = false,
  cache = false,
  no_break = true
}

local min = 1
-- Gets the size of the largest unit and speed of the slowest unit
local get_group_size_and_speed = function(group)
  local speed = math.huge
  local size = 0
  local checked = {}
  for k, entity in pairs (group) do
    if not checked[entity.name] then
      checked[entity.name] = true
      if entity.type == "unit" then
        if entity.prototype.speed < speed then
          speed = entity.prototype.speed
        end
        local entity_size = min + entity.get_radius()
        if entity_size > size then
          size = entity_size
        end
      end
    end
  end
  if speed == math.huge then speed = nil end
  return size, speed
end

-- Generates and assigns 'go_to_location' commands for a whole group,
-- arranging them in a formation.
function Movement.make_move_command(param)
  local origin = param.position
  local distraction = param.distraction or defines.distraction.by_enemy
  local group = param.group
  local player = param.player
  local surface = player.surface
  local force = player.force
  local append = param.append
  local type = defines.command.go_to_location
  local find = surface.find_non_colliding_position
  local script_data = storage.unit_control
  local units = script_data.units
  local i = 0

  local size, speed = get_group_size_and_speed(group)

  for unit_number, entity in pairs (group) do
    local offset = get_move_offset(i, size)
    i = i + 1
    local destination = {origin.x + offset.x, origin.y + offset.y}
    local is_unit = (entity.type == "unit")
    local found_destination = find(entity.name, destination, 0, 0.5)
    local command =
    {
      command_type = next_command_type.move,
      type = type,
      distraction = distraction,
      radius = 2, -- FIX: Increased radius from 0.5 to 2 to stop "wandering"
      speed = speed,
      pathfind_flags = path_flags,
      destination = found_destination or destination, -- Use original if no spot found
      do_separation = true
    }
    local unit_data = units[unit_number]
    if append then
      if is_unit and unit_data.idle then
        -- If idle, start moving immediately
        Commands.set_command(unit_data, command)
      end
      table.insert(unit_data.command_queue, command)
    else
      if is_unit then
        Commands.set_command(unit_data, command)
        unit_data.command_queue = {}
      else
        unit_data.command_queue = {command}
      end
    end
    Commands.set_unit_not_idle(unit_data)
  end
end

-- Issues a simple move command
local move_units = function(event)
  local group = Selection.get_selected_units(event.player_index)
  if not group then
    unset_selected_unit(event.player_index)
    return
  end
  local player = game.players[event.player_index]
  Movement.make_move_command{
    position = util.center(event.area),
    distraction = defines.distraction.none,
    group = group,
    append = event.name == defines.events.on_player_alt_selected_area,
    player = player
  }
  player.play_sound({path = tool_names.unit_move_sound})
end

-- Issues a move command from a right-click
function Movement.move_units_to_position(player, position, append)
  local group = Selection.get_selected_units(player.index)
  if not group then
    unset_selected_unit(player.index)
    return
  end
  Movement.make_move_command
  {
    position = position,
    distraction = defines.distraction.none,
    group = group,
    append = append,
    player = player
  }
  player.play_sound({path = tool_names.unit_move_sound})
end

-- Issues an attack-move command
local attack_move_units = function(event)
  local group = Selection.get_selected_units(event.player_index)
  if not group then
    unset_selected_unit(event.player_index)
    return
  end
  local player = game.players[event.player_index]
  Movement.make_move_command{
    position = util.center(event.area),
    distraction = defines.distraction.by_anything,
    group = group,
    append = event.name == defines.events.on_player_alt_selected_area,
    player = player
  }
  player.play_sound({path = tool_names.unit_move_sound})
end

-- Issues an attack-move command from a right-click
function Movement.attack_move_units_to_position(player, position, append)
  local group = Selection.get_selected_units(player.index)
  if not group then
    unset_selected_unit(player.index)
    return
  end
  Movement.make_move_command
  {
    position = position,
    distraction = defines.distraction.by_anything,
    group = group,
    append = append,
    player = player
  }
  player.play_sound({path = tool_names.unit_move_sound})
end

-- Finds an existing patrol command in a unit's queue
local find_patrol_comand = function(queue)
  if not queue then return end
  for k, command in pairs (queue) do
    if command.command_type == next_command_type.patrol then
      return command
    end
  end
end

-- Handles the logic for creating and managing patrol routes
function Movement.make_patrol_command(param)
  local origin = param.position
  local distraction = param.distraction or defines.distraction.by_anything
  local group = param.group
  local player = param.player
  local surface = player.surface
  local force = player.force
  local append = param.append
  local type = defines.command.go_to_location
  local find = surface.find_non_colliding_position
  local insert = table.insert
  local script_data = storage.unit_control
  local units = script_data.units

  local size, speed = get_group_size_and_speed(group)
  local i = 0
  for unit_number, entity in pairs (group) do
    local offset = get_move_offset(i, size)
    i = i + 1
    local destination = {origin.x + offset.x, origin.y + offset.y}
    local unit_data = units[unit_number]
    local is_unit = (entity.type == "unit")
    local next_destination = find(entity.name, destination, 0, 0.5) or destination
    
    local command
    local patrol_command = find_patrol_comand(unit_data.command_queue)
    if patrol_command and append then
      -- If appending, add a new point to the existing patrol
      insert(patrol_command.destinations, next_destination)
      command = patrol_command -- A reference, but we don't re-insert it
    else
      -- Otherwise, create a new patrol command
      command =
      {
        command_type = next_command_type.patrol,
        destinations = {entity.position, next_destination},
        destination_index = "initial",
        speed = speed,
        do_separation = true,
        distraction = distraction
      }
    end
    
    if not append then
      unit_data.command_queue = {command}
      Commands.set_unit_not_idle(unit_data)
      if is_unit then
        Commands.process_command_queue(unit_data)
      end
    elseif not patrol_command then
      -- This is append=true, but no patrol command existed, so insert the new one
      insert(unit_data.command_queue, command)
      if is_unit and unit_data.idle then
        Commands.process_command_queue(unit_data)
      end
    end
    Indicators.add_unit_indicators(unit_data)
  end
end

-- Issues a patrol command
function Movement.patrol_units(event)
  local group = Selection.get_selected_units(event.player_index)
  if not group then return end
  local player = game.players[event.player_index]
  Movement.make_patrol_command{
    position = util.center(event.area),
    distraction = defines.distraction.by_anything,
    group = group,
    append = event.name == defines.events.on_player_alt_selected_area,
    player = player
  }
  player.play_sound({path = tool_names.unit_move_sound})
end

-- Logic for the 'follow' command
local unit_follow = function(unit_data)
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

  local speed = target.speed
  local follow_range = 32

  if speed and Core.distance(target.position, unit.position) > follow_range then
    Commands.set_command(unit_data,
    {
      type = defines.command.go_to_location,
      destination_entity = target,
      radius = follow_range - (target.get_radius() + unit.get_radius() + 1)
    })
    return
  end
  if speed then
    speed = math.max(0.05, math.min(unit.prototype.speed, speed * 1.05))
  end
  local offset = get_move_offset(10 + unit.unit_number % 100, unit.get_radius())
  Commands.set_command(unit_data,
  {
    type = defines.command.go_to_location,
    destination = {target.position.x + offset.x, target.position.y + offset.y},
    radius = target.get_radius() + unit.get_radius() + 1,
    speed = speed
  })
end

-- Generates attack commands for a group
function Movement.make_attack_command(group, entities, append)
  if #entities == 0 then return end
  local script_data = storage.unit_control
  local units_table = script_data.units
  local next_command =
  {
    command_type = next_command_type.attack,
    targets = entities
  }
  for unit_number, unit in pairs (group) do
    local commandable = (unit.type == "unit")
    local unit_data = units_table[unit_number]
    if unit_data then -- Add safety check
      if append then
        table.insert(unit_data.command_queue, next_command)
        if unit_data.idle and commandable then
          Commands.register_to_attack(unit_data)
        end
      else
        unit_data.command_queue = {next_command}
        if commandable then
          Commands.register_to_attack(unit_data)
        end
      end
      Commands.set_unit_not_idle(unit_data)
    end
  end
end

-- Generates follow commands for a group
function Movement.make_follow_command(group, target, append)
  if not (target and target.valid) then return end
  local script_data = storage.unit_control
  local units_table = script_data.units
  for unit_number, unit in pairs (group) do
    local commandable = (unit.type == "unit")
    local next_command =
    {
      command_type = next_command_type.follow,
      target = target
    }
    local unit_data = units_table[unit_number]
    if unit_data then -- Add safety check
      if append then
        table.insert(unit_data.command_queue, next_command)
        if unit_data.idle and commandable then
          unit_follow(unit_data)
        end
      else
        unit_data.command_queue = {next_command}
        if commandable then
          unit_follow(unit_data)
        end
      end
      Commands.set_unit_not_idle(unit_data)
    end
  end
end

-- Issues an attack command
local attack_units = function(event)
  local group = Selection.get_selected_units(event.player_index)
  if not group then return end

  local append = event.name == defines.events.on_player_alt_selected_area
  Movement.make_attack_command(group, event.entities, append)
  game.get_player(event.player_index).play_sound({path = tool_names.unit_move_sound})
end

-- Issues a follow command
local follow_entity = function(event)
  local group = Selection.get_selected_units(event.player_index)
  if not group then return end

  local target = event.entities[1]
  if not target then return end
  local append = event.name == defines.events.on_player_alt_selected_area
  Movement.make_follow_command(group, target, append)
  game.get_player(event.player_index).play_sound({path = tool_names.unit_move_sound})
end

-- Smart function that decides whether to attack or attack-move
local multi_attack_selection = function(event)
  local entities = event.entities
  if entities and table_size(entities) > 0 then
    return attack_units(event)
  end
  return attack_move_units(event)
end

-- Smart function that decides whether to move or follow
local multi_move_selection = function(event)
  local entities = event.entities
  if entities and table_size(entities) > 0 then
    return follow_entity(event)
  end
  return move_units(event)
end

-- Maps selection tool actions to the correct functions
Movement.selected_area_actions =
{
  [tool_names.unit_selection_tool] = Selection.unit_selection,
  [tool_names.unit_move_tool] = multi_move_selection,
  [tool_names.unit_patrol_tool] = Movement.patrol_units,
  [tool_names.unit_attack_move_tool] = multi_attack_selection,
}

Movement.alt_selected_area_actions =
{
  [tool_names.unit_selection_tool] = Selection.unit_selection,
  [tool_names.unit_move_tool] = multi_move_selection,
  [tool_names.unit_patrol_tool] = Movement.patrol_units,
  [tool_names.unit_attack_move_tool] = multi_attack_selection,
}

return Movement