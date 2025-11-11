-- This module handles all rendering for the mod,
-- like selection circles, destination lines, and target boxes.

local Core = require("script/uc_core")
local util = require("script/script_util")

local Indicators = {}

local get_unit_number = Core.get_unit_number
local empty_position = {0,0}

-- Draws the red target box on an enemy
function Indicators.add_target_indicator(unit_data)
  local player = unit_data.player
  if not player then return end

  local target = unit_data.target
  if not (target and target.valid) then return end
  local target_index = get_unit_number(target)

  local script_data = storage.unit_control
  local target_indicators = script_data.target_indicators[target_index]
  if not target_indicators then
    target_indicators = {}
    script_data.target_indicators[target_index] = target_indicators
  end

  local indicator_data = target_indicators[player]
  if not indicator_data then
    indicator_data =
    {
      targeting_me = {}
    }
    target_indicators[player] = indicator_data
  end

  indicator_data.targeting_me[unit_data.entity.unit_number] = true
  local indicator = indicator_data.indicator

  if not (indicator and indicator.valid) then
    indicator = target.surface.create_entity
    {
      name = "highlight-box", box_type = "not-allowed",
      target = target, render_player_index = player,
      position = empty_position,
      blink_interval = 0
    }
    indicator_data.indicator = indicator
  end
end

-- Removes the red target box from an enemy
function Indicators.remove_target_indicator(unit_data)
  local unit = unit_data.entity
  -- FIX: Add safety check for invalid units
  if not (unit and unit.valid) then return end

  local target = unit_data.target
  -- FIX: Check for 'target' *and* 'target.valid'
  -- This prevents a crash if the target is invalid.
  if not target or not target.valid then return end
  
  local target_index = get_unit_number(target)
  local script_data = storage.unit_control
  local target_indicators = script_data.target_indicators[target_index]
  if not target_indicators then return end

  local player = unit_data.player
  if not player then return end

  local indicator_data = target_indicators[player]
  if not indicator_data then return end

  indicator_data.targeting_me[unit.unit_number] = nil

  -- If another unit is still targeting this, don't remove the box
  local next_index = next(indicator_data.targeting_me)
  if next_index then return end

  indicator_data.indicators = nil
  local indicator = indicator_data.indicator

  if indicator and indicator.valid then
    indicator.destroy()
    indicator_data.indicator = nil
  end

  target_indicators[player] = nil
end

-- Caches collision box data for drawing selection circles
local box_point_cache = {}
local width = 0.2
local get_collision_box_draw_points = function(entity)
  local box = box_point_cache[entity.name]
  if box then return box end
  local collision_box = entity.prototype.selection_box
  local box =
  {
    {
      {collision_box.left_top.x, collision_box.left_top.y},
      {collision_box.left_top.x + width, collision_box.left_top.y}
    },
    {
      {collision_box.left_top.x, collision_box.left_top.y},
      {collision_box.left_top.x, collision_box.left_top.y + width}
    },
    {
      {collision_box.right_bottom.x, collision_box.left_top.y},
      {collision_box.right_bottom.x - width, collision_box.left_top.y}
    },
    {
      {collision_box.right_bottom.x, collision_box.left_top.y},
      {collision_box.right_bottom.x, collision_box.left_top.y + width}
    },
    {
      {collision_box.right_bottom.x, collision_box.right_bottom.y},
      {collision_box.right_bottom.x - width, collision_box.right_bottom.y}
    },
    {
      {collision_box.right_bottom.x, collision_box.right_bottom.y},
      {collision_box.right_bottom.x, collision_box.right_bottom.y - width}
    },
    {
      {collision_box.left_top.x, collision_box.right_bottom.y},
      {collision_box.left_top.x + width, collision_box.right_bottom.y}
    },
    {
      {collision_box.left_top.x, collision_box.right_bottom.y},
      {collision_box.left_top.x, collision_box.right_bottom.y - width}
    },
  }
  box_point_cache[entity.name] = box
  return box
end

-- Caches selection radius data
local radius_cache = {}
local get_selection_radius = function(entity)
  local radius = radius_cache[entity.name]
  if radius then return radius end
  radius = (util.radius(entity.prototype.selection_box) * 2) + 0.5
  radius_cache[entity.name] = radius
  return radius
end

-- Draws a temporary red circle over an attack target
function Indicators.draw_temp_attack_indicator(entity, player)
  if not player then return end

  local color = {1, 0, 0}
  local width = 2
  local players = {player}
  local surface = entity.surface
  local scale = (32/418) * get_selection_radius(entity)
  rendering.draw_sprite
  {
    sprite = "selection-circle",
    x_scale = scale,
    y_scale = scale/(2^0.5),
    tint = color,
    time_to_live = 100,
    render_layer = "lower-object-above-shadow",
    target = entity,
    surface = surface,
    players = players,
    visible = true,
    only_in_alt_mode = false
  }
end

-- Clears the green selection circle from a unit
function Indicators.clear_selection_indicator(unit_data)
  if unit_data.selection_indicator then
    if unit_data.selection_indicator.valid then
      unit_data.selection_indicator.destroy()
    end
    unit_data.selection_indicator = nil
  end

  if unit_data.rendered_selection_box then
    for k, render_id in pairs (unit_data.rendered_selection_box) do
      render_id.destroy()
    end
    unit_data.rendered_selection_box = nil
  end
end

-- Draws or updates the green selection circle for a unit
function Indicators.update_selection_indicators(unit_data)
  local player = unit_data.player
  if not player then
    Indicators.clear_selection_indicator(unit_data)
    return
  end

  if unit_data.rendered_selection_box then
    local players = {player}
    for k, render_id in pairs (unit_data.rendered_selection_box) do
      render_id.players = players
    end
    return
  end

  unit_data.rendered_selection_box = {}

  local unit = unit_data.entity
  local box_points = get_collision_box_draw_points(unit)

  local draw_line = rendering.draw_line
  local color = {0, 1, 0}
  local width = 2
  local players = {player}
  local surface = unit.surface
  local scale = (32/418) * get_selection_radius(unit)

  unit_data.rendered_selection_box[1] = rendering.draw_sprite
  {
    sprite = "selection-circle",
    x_scale = scale,
    y_scale = scale/(2^0.5),
    tint = color,
    render_layer = "lower-object-above-shadow",
    target = unit,
    surface = surface,
    players = players,
    visible = true,
    only_in_alt_mode = false
  }
end

-- Clears all indicators for a unit (destination lines, etc.)
function Indicators.clear_indicators(unit_data)
  if not unit_data.indicators then return end
  for _, indicator in pairs (unit_data.indicators) do
    indicator.destroy()
  end
  unit_data.indicators = nil
end

-- Colors for destination lines based on move type
local move_color =
{
  [defines.distraction.none] = {r = 0, b = 0, g = 1, a = 1}, -- Blue for simple move
  [defines.distraction.by_anything] = {r = 1, b = 0, g = 0.5, a = 1}, -- Orange for attack-move
  [defines.distraction.by_enemy] = {r = 1, b = 0, g = 0.5, a = 1} -- Orange for attack-move
}

local get_color = function(distraction)
  return move_color[distraction] or {r = 1, b = 1, g = 1, a = 1}
end

-- Main function to draw all indicators for a unit (selection, destination lines)
function Indicators.add_unit_indicators(unit_data)
  Indicators.update_selection_indicators(unit_data)
  Indicators.clear_indicators(unit_data)

  local player = unit_data.player
  if not player then return end

  local unit = unit_data.entity
  if not (unit and unit.valid) then return end

  local indicators = {}
  unit_data.indicators = indicators

  local surface = unit.surface
  local players = {unit_data.player}

  -- FIX: Removed `local rendering = rendering` to fix global scope issue
  local draw_line = rendering.draw_line
  local gap_length = 1.25
  local dash_length = 0.25

  -- Draw line to current destination
  if unit_data.destination then
    local draw_obj = draw_line
    {
      color = get_color(unit_data.distraction),
      width = 1,
      to = unit,
      from = unit_data.destination,
      surface = surface,
      players = players,
      gap_length = gap_length,
      dash_length = dash_length,
      draw_on_ground = true
    }
    indicators[draw_obj.id] = draw_obj
  end

  -- Draw line to a target entity
  if unit_data.destination_entity and unit_data.destination_entity.valid then
    local draw_obj = draw_line
    {
      color = get_color(unit_data.distraction),
      width = 1,
      to = unit,
      from = unit_data.destination_entity,
      surface = surface,
      players = players,
      gap_length = gap_length,
      dash_length = dash_length,
      draw_on_ground = true
    }
    indicators[draw_obj.id] = draw_obj
  end

  -- Draw lines for all queued commands
  local position = unit_data.destination or unit.position
  for k, command in pairs (unit_data.command_queue) do
    if command.command_type == Core.next_command_type.move then
      local draw_obj = draw_line
      {
        color = get_color(command.distraction),
        width = 1,
        to = position,
        from = command.destination,
        surface = surface,
        players = players,
        gap_length = gap_length,
        dash_length = dash_length,
        draw_on_ground = true
      }
      indicators[draw_obj.id] = draw_obj
      position = command.destination
    end

    -- Draw lines for patrol routes
    if command.command_type == Core.next_command_type.patrol then
      for k = 1, #command.destinations do
        local to = command.destinations[k]
        local from = command.destinations[k + 1] or command.destinations[1]
        local draw_obj = draw_line
        {
          color = {b = 0.5, g = 0.2, a = 0.05},
          width = 1,
          from = from,
          to = to,
          surface = surface,
          players = players,
          gap_length = gap_length,
          dash_length = dash_length,
          draw_on_ground = true,
        }
        indicators[draw_obj.id] = draw_obj
      end
    end
  end
end

-- Clears and redraws all indicators for all units
function Indicators.reset_rendering()
  rendering.clear("erm_unit_control")
  local script_data = storage.unit_control
  for k, unit_data in pairs (script_data.units) do
    local unit = unit_data.entity
    if unit and unit.valid then
      Indicators.clear_indicators(unit_data)
      Indicators.clear_selection_indicator(unit_data)
      Indicators.remove_target_indicator(unit_data)
      unit_data.selection_indicators = nil
      Indicators.add_unit_indicators(unit_data)
    else
      script_data.units[k] = nil
    end
  end
end

return Indicators