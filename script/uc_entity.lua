-- This module handles all entity-related events:
-- spawn, remove, damage, settings pasted, etc.

local Core = require("script/uc_core")
-- FIX: Point to the new merged file
local Selection = require("script/uc_selection_gui_and_groups").Selection 
local Commands = require("script/uc_commands")
local HuntingMode = require("hunting_mode")
local util = require("script/script_util")

local Entity = {}



-- Cleans up a unit from the mod's data when it's removed
function Entity.deregister_unit(entity)
  if not (entity and entity.valid) then return end
  local unit_number = entity.unit_number
  if not unit_number then return end
  
  local script_data = storage.unit_control
  local unit = script_data.units[unit_number]
  if not unit then return end
  script_data.units[unit_number] = nil

  Selection.deselect_units(unit)

  local group = unit.group
  if group then
    group[unit_number] = nil
    
    -- If group is now empty, clean up any shared data
    if not next(group) then
      if script_data.group_hunt_data and script_data.group_hunt_data[group] then
         script_data.group_hunt_data[group] = nil
      end
    end
  end
  local player_index = unit.player
  if not player_index then
    return
  end
end

-- Event handler for when an entity is removed
-- Cleans up unit data and control groups
function Entity.on_entity_removed(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  local unit_number = entity.unit_number
  if not unit_number then return end

    local script_data = storage.unit_control  
  if not script_data.units[entity.unit_number] then return end
    
  script_data.target_indicators[Core.get_unit_number(entity)] = nil
  
  -- Check if this unit was in any control group and mark GUI for refresh
  for player_index, player_groups in pairs(script_data.control_groups) do
    -- FIX: Check frame validity before indexing
    local frame = script_data.open_frames[player_index]
    if frame and frame.valid then
      local group_changed = false
      for group_id, unit_list in pairs(player_groups) do
        if unit_list[unit_number] then
          group_changed = true
          break -- Found it, no need to keep searching
        end
      end
      if group_changed then
        script_data.marked_for_refresh[player_index] = true
      end
    end
  end
  
  Entity.deregister_unit(event.entity)
end

-- Event handler for when a unit is damaged
-- Triggers 'hunt' mode retaliation
--[[
-- Disabling this feature to improve performance.
-- The on_entity_damaged event can fire very frequently
-- and cause performance spikes in large battles.
function Entity.on_entity_damaged(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  
  local unit_data = script_data.units[entity.unit_number]
  if not (unit_data and unit_data.mode == "hunt") then
    return
  end
  
  local cause = event.cause
  if not (cause and cause.object_name == "LuaEntity" and cause.valid) then
    return
  end
  
  -- Check if the cause is an enemy
  local unit_force = entity.force
  local cause_force = cause.force
  if not cause_force or unit_force == cause_force or unit_force.get_cease_fire(cause_force) then
    return
  end
  
  -- Tell the HuntingMode module to set this as a high-priority target
  HuntingMode.register_attacker(unit_data, cause)
  
  -- Force the unit that was *hit* to react *immediately*
  Commands.set_command(unit_data, {
    type = defines.command.attack,
    target = cause,
    distraction = defines.distraction.by_enemy
  })
end
--]]

-- Copies unit command data when a player copies settings
function Entity.on_entity_settings_pasted(event)
  local source = event.source
  local destination = event.destination
  if not (source and source.valid and destination and destination.valid) then return end
  Entity.deregister_unit(destination)
  
  local script_data = storage.unit_control
  local unit_data = script_data.units[source.unit_number]
  if not unit_data then return end
  local copy = util.copy(unit_data)
  copy.entity = destination
  copy.player = nil
  script_data.units[destination.unit_number] = copy
end

-- Event handler for when a unit spawner creates a unit
-- Copies the spawner's command queue to the new unit
function Entity.on_entity_spawned(event)
  local unit = event.entity
  if not (unit and unit.valid) then return end 
    
  local script_data = storage.unit_control 
  local source_data = script_data.units[unit.unit_number]
  if not source_data then return end

  local queue = source_data.command_queue
  local unit_data =
  {
    entity = unit,
    command_queue = util.copy(queue),
    idle = false
  }
  script_data.units[unit.unit_number] = unit_data

  -- Generate a random offset for spawned units
  local offset = {
    x = (math.random() - 0.5) * 4,
    y = (math.random() - 0.5) * 4
  }
  
  for k, command in pairs (unit_data.command_queue) do
    command.speed = nil
    if command.command_type == Core.next_command_type.move then
      command.destination = {x = command.destination.x + offset.x, y = command.destination.y + offset.y}
    end
    if command.command_type == Core.next_command_type.patrol then
      for i, destination in ipairs(command.destinations) do
        -- Make sure to update the table in-place
        command.destinations[i] = {x = destination.x + offset.x, y = destination.y + offset.y}
      end
    end
  end

  unit.release_from_spawner()
  return Commands.process_command_queue(unit_data)
end

return Entity