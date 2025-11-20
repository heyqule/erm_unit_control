local util = require("script/script_util")
local Core = require("script/uc_core")
local ReactiveDefense = {}

--[[
New event based workflow

- When a valid entity dies by enemy force, 
- Check whether there are unit withinn erm-unit-control-reactive-defense-range box width, using surface.find_units() 
- If units are found, select them (up to max group limit) and form an attack group with LuaCommandable.
- Once group is formed, give them a chain command 
  1. go to target location, distract by enemy,
  2. wander for 5 seconds,  distract by enemy,
  3. go to radar location, distract by enemy,
- After assigning the command,  attach a sprite to the group in map mode. Then assign the renderObjectId and the group LuaCommandable object to the position of dead entity.
- When an entity die within 96 tiles of that location, it can no
- Once unit group complete it command or timeout 5 mins, use renderObjectId to destroy the tag and disband the group.
  - If the group is disbanded by a timeout, notify user by the group's location.   

 
]]--

local acceptable_entity_types = util.list_to_map({
  "artillery-turret",
  "ammo-turret",
  "turret",
  "electric-turret",
  "fluid-turret",
  "assembling-machine",
  "rocket-silo",
  "furnace",
  "mining-drill",
  "boiler",
  "radar",
  "battery",
  "solar-panel",
  "generator",
  "fusion-generator",
  "lab",
  "pump",
  "transport-belt",
  "pipe",
  "electric-pole",
  "offshore-pump",
  "roboport",
  "wall",
  "gate",
  "rail-ramp",
  "rail-support",
  "train-stop",
  "straight-rail",
  "half-diagonal-rail",
  "curved-rail-a",
  "curved-rail-b",
  "legacy-curved-rail",
  "legacy-straight-rail",
  "locomotive",
  "cargo-wagon",
  "fluid-wagon"
})

local COOLDOWN = 5 * second

function ReactiveDefense.search_enemy(entity)
  if not storage.unit_control.reactive_defense_mode_enabled then
    return
  end

  if entity and entity.valid and
    acceptable_entity_types[entity.type] and
    entity.force.ai_controllable == false
  then
    local force = entity.force
    --- 5s cooldown for applicable each force.
    if game.tick < (storage.unit_control.reactive_defense_cooldown[force.index] or 0) then
      return
    end
    
    storage.unit_control.reactive_defense_cooldown[force.index] = game.tick + COOLDOWN
    local unit_search_range = storage.unit_control.reactive_defense_unit_search_range
    local surface = entity.surface
    local position = entity.position
    local enemy = surface.find_nearest_enemy({
      position = position, -- Search *from the origin*, not the unit
      max_distance = unit_search_range,
      force = entity.force
    })
    if not enemy then return end
    
    local target_unit_result = surface.find_entities_filtered({
      area = {
        left_top = {x = position.x - unit_search_range, y = position.y - unit_search_range},
        right_bottom = {x = position.x + unit_search_range, y = position.y + unit_search_range}
      },
      force = force,
      limit = 1,
      type = "unit"
    })
    local target_unit = target_unit_result[1]
    if not target_unit or
       (target_unit.commandable and
       target_unit.commandable.parent_group)
    then 
      return 
    end
    
    local target_unit_position = target_unit.position
    local local_unit_search_range = storage.unit_control.max_selectable_radius
    local defense_units = surface.find_entities_filtered({
      area = {
        left_top = {x = target_unit_position.x - local_unit_search_range, y = target_unit_position.y - local_unit_search_range},
        right_bottom = {x = target_unit_position.x + local_unit_search_range, y = target_unit_position.y + local_unit_search_range}
      },
      force = force,
      limit = 100, -- up to maximum selectable.
      type = "unit"
    })
    
    if not next(defense_units) then return end

    local group_data = storage.unit_control.reactive_defense_groups
    local group = surface.create_unit_group({
      force = force,
      position = target_unit_position
    })
    for _, unit in pairs(defense_units) do
      group.add_member(unit)
    end
    local command = {
      type = defines.command.compound,
      structure_type = defines.compound_command.return_last,
      commands =
      {
        {
          type = defines.command.attack_area,
          destination = { x = position.x, y = position.y },
          radius = 16,
          distraction = defines.distraction.by_enemy
        },
        {
          type = defines.command.wander,
          destination = { x = position.x, y = position.y },
          radius = 32,
          ticks_to_wait = 5 * second,
          distraction = defines.distraction.by_enemy
        },
        {
          type = defines.command.go_to_location,
          distraction = defines.distraction.by_enemy,
          radius = 5,
          destination = {x = target_unit_position.x, y = target_unit_position.y}
        },
      }
    }
    group.set_command(command)
    local icon_object = rendering.draw_sprite {
      sprite = "reactive-defense-icon",
      target = target_unit,
      surface = surface,
      forces = {force},
      y_scale = 2,
      x_scale = 2,
      render_mode = "chart",
      tint = { r=1,g=0,b=0,a=1 },
    }

    local line_object = rendering.draw_line({
      color = { r=1,g=0,b=0,a=1 },
      from = target_unit.position,
      to = position,
      width = 2,
      gap_length = 3,
      dash_length = 3,
      surface = surface,
      forces = {force},
      draw_on_ground = true,
      render_mode = "chart"
    })
    
    --- Make sure clean up code runs when the group destory for any reason
    local registration_number = script.register_on_object_destroyed(group)
    group_data[group.unique_id] = {
      group = group,
      start_position = target_unit.position,
      defense_units = defense_units,
      icon_object = icon_object,
      line_object = line_object,
      --registration_number = registration_data -- don't need registration_number, since the group_id is the userful_id
    }
    ReactiveDefense.clean_groups()
  end
end

-- This is the main 'update' function for QRF (Quick Reaction Force) mode.
-- It scans for enemies. If found, it attacks.
-- If not, it returns to its post and waits.
--[[
defines.behavior_result = {
  deleted = 3,
  fail = 1,
  in_progress = 0,
  success = 2
}
]]
local command_completed = {
  [defines.behavior_result.deleted] = true,
  [defines.behavior_result.fail] = true,
  [defines.behavior_result.success] = true,
}

function ReactiveDefense.update_ai_completed(event)
  if not storage.unit_control.reactive_defense_mode_enabled then
    return
  end
  
  local script_data = storage.unit_control.reactive_defense_groups[event.unit_number]
  if script_data and command_completed[event.result] then

    ---When the group fails, retry return command for each unit, since old group is gone.
    if event.result == defines.behavior_result.fail then
      --- return to start location
      for _, unit in pairs(script_data.defense_units) do
        if unit and unit.valid then
          --- Ask them to return individually. if this fails too, then so be it, they deserted and can die in the wild lol.
          unit.commandable.set_command({
            type = defines.command.go_to_location,
            distraction = defines.distraction.by_enemy,
            radius = 5,
            destination = script_data.start_position
          }) 
        end
        ReactiveDefense.clean_group(event.unit_number)
      end
    else
      ReactiveDefense.clean_group(event.unit_number)
    end
  end
end

function ReactiveDefense.update_group_destroy(event)
  if not storage.unit_control.reactive_defense_mode_enabled then
    return
  end
  
  local group_data = storage.unit_control.reactive_defense_groups[event.useful_id]
  if group_data then
    ReactiveDefense.clean_group(event.useful_id)
  end
end

function ReactiveDefense.clean_groups()
  local garbage_tick = storage.unit_control.reactive_defense_garbage_collect_tick or 0
  local group_data = storage.unit_control.reactive_defense_groups
  if game.tick > garbage_tick then
    for group_id, group_data in pairs(group_data) do
      if group_data and not group_data.group.valid then
        ReactiveDefense.clean_group(group_id)
      end
    end
    storage.unit_control.reactive_defense_garbage_collect_tick = game.tick + 5 * minute
  end
end

function ReactiveDefense.clean_group(group_id)
  local script_data = storage.unit_control.reactive_defense_groups[group_id]
  if script_data then
    --- Clean Icon  
    local icon_object = script_data.icon_object
    if icon_object and icon_object.valid  then 
      icon_object.destroy() 
    end
    local line_object = script_data.line_object
    if line_object and line_object.valid then
      line_object.destroy()
    end
    --- Clean Data
    local group = script_data.group
    if script_data.group and script_data.group.valid then
      group.destroy()
    end
    
    storage.unit_control.reactive_defense_groups[group_id] = nil
  end
end

return ReactiveDefense