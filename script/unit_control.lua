local util = require("script/script_util")
local tool_names = names.unit_tools
local HuntingMode = require("hunting_mode")
local QRFMode = require("qrf_mode")
local PerimeterMode = require("perimeter_mode")

-- This is a fix for loading saved games.
-- We must re-define hotkey names here because loading a save doesn't
-- re-run the data phase, so `names.hotkeys` would be empty.
if not names.hotkeys then names.hotkeys = {} end
local hotkeys = names.hotkeys

for i = 0, 9 do
  local key_num_str = tostring(i)
  hotkeys["select_control_group_" .. key_num_str] = "erm-unit-control-select_control_group_" .. key_num_str
  hotkeys["set_control_group_" .. key_num_str] = "erm-unit-control-set_control_group_" .. key_num_str
end

-- This is another fix for loading saved games, same reason as above.
-- It re-defines the unit tool names.
if not names.unit_tools then names.unit_tools = {} end
names.unit_tools.unit_attack_move_tool = "unit_attack_move_tool"
names.unit_tools.unit_move_tool = "unit_move_tool"
names.unit_tools.unit_patrol_tool = "unit_patrol_tool"
names.unit_tools.unit_selection_tool = "select-units"
names.unit_tools.unit_attack_tool = "unit_attack_tool"
names.unit_tools.unit_force_attack_tool = "unit_force_attack_tool"
names.unit_tools.unit_follow_tool = "unit_follow_tool"
names.unit_tools.unit_move_sound = "utility/confirm"

-- This is the main global table that holds all the mod's
-- active data and state, like selected units, groups, etc.
local script_data =
{
  button_actions = {},
  groups = {},
  selected_units = {},
  open_frames = {},
  units = {},
  indicators = {},
  unit_unselectable = {},
  debug = false,
  marked_for_refresh = {},
  last_selection_tick = {},
  last_right_click_position = nil,
  target_indicators = {},
  attack_register = {},
  last_location = {},
  group_hunt_data = {},
  control_groups = {},
}

local empty_position = {0,0}

-- A simple 'enum' to define our custom command types
local next_command_type =
{
  move = 1,
  patrol = 2,
  scout = 3,
  idle = 4,
  attack = 5,
  follow = 6,
  hold_position = 7,
  hunt = 8,
  qrf = 9,
  perimeter = 10
}

-- Custom event names for the mod
local script_events =
{
  on_unit_spawned = script.generate_event_name()
}

-- A custom print function for debugging
-- Only prints if `script_data.debug` is true
local print = function(string)
  if not script_data.debug then return end
  local tick = game.tick
  log(tick.." | "..string)
  game.print(tick.." | "..string)
end

local profiler
local print_profiler = function(string)
  game.print({"", string, " - ", profiler, " ", game.tick})
end


local insert = table.insert

-- Basic helper function for distance
local distance = function(position_1, position_2)
  local d_x = position_2.x - position_1.x
  local d_y = position_2.y - position_1.y
  return ((d_x * d_x) + (d_y * d_y)) ^ 0.5
end

local delim = "."
local concat = table.concat
-- Gets a unique ID number for a unit
local get_unit_number = function(entity)
  return entity.unit_number or concat{entity.surface.index, delim, entity.position.x, delim, entity.position.y}
end

local add_unit_indicators
local remove_target_indicator

-- Tells a unit to perform a specific Factorio command (like 'go_to_location')
-- It also updates our internal unit_data state.
local set_command = function(unit_data, command)
  remove_target_indicator(unit_data)
  local unit = unit_data.entity
  if not unit.valid then return end
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
  return add_unit_indicators(unit_data)
end

-- If a unit fails a command (e.g., pathfinding), this tries again
-- with a slightly higher path resolution.
local retry_command = function(unit_data)
  local unit = unit_data.entity
  unit.ai_settings.path_resolution_modifier = math.min(unit.ai_settings.path_resolution_modifier + 1, 3)
  return pcall(unit.commandable.set_command, unit_data.command)
end

local set_unit_idle
local scout_queue = {command_type = next_command_type.scout}
-- Handles the 'scout' command logic, finding uncharted
-- or unseen chunks for the unit to move to.
local set_scout_command = function(unit_data, failure, delay)
  unit_data.command_queue = {scout_queue}
  local unit = unit_data.entity
  if unit.type ~= "unit" then return end
  if failure and unit_data.fail_count > 10 then
    unit_data.fail_count = nil
    return set_unit_idle(unit_data, true)
  end
  if delay and delay > 0 then
    return set_command(unit_data,
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
  
  return set_command(unit_data,
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

-- Gets the currently selected units for a player,
-- cleaning out any invalid/dead units first.
local get_selected_units = function(player_index)

  local selected = script_data.selected_units[player_index]
  if not selected then return end

  for unit_number, entity in pairs (selected) do
    if not entity.valid then
      selected[unit_number] = nil
    end
  end

  if not next(selected) then
    script_data.selected_units[player_index] = nil
    return
  end

  return selected
end

local highlight_box

-- Draws the red target box on an enemy
local add_target_indicator = function(unit_data)
  local player = unit_data.player
  if not player then return end

  local target = unit_data.target
  if not (target and target.valid) then return end
  local target_index = get_unit_number(target)

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
remove_target_indicator = function(unit_data)

  local target = unit_data.target
  if not (target and target.valid) then return end
  local target_index = get_unit_number(target)

  local target_indicators = script_data.target_indicators[target_index]
  if not target_indicators then return end

  local player = unit_data.player
  if not player then return end

  local indicator_data = target_indicators[player]
  if not indicator_data then return end

  indicator_data.targeting_me[unit_data.entity.unit_number] = nil

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
local draw_temp_attack_indicator = function(entity, player)
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
local clear_selection_indicator = function(unit_data)

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
local update_selection_indicators = function(unit_data)
  local player = unit_data.player
  if not player then
    clear_selection_indicator(unit_data)
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
local clear_indicators = function(unit_data)
  if not unit_data.indicators then return end
  for indicator, bool in pairs (unit_data.indicators) do
    indicator.destroy()
  end
  unit_data.indicators = nil
end

-- Removes a unit from a player's selection
local deselect_units = function(unit_data)
  if unit_data.player then
    script_data.marked_for_refresh[unit_data.player] = true
    unit_data.player = nil
  end
  clear_selection_indicator(unit_data)
  clear_indicators(unit_data)
end

-- Helper for box math
local shift_box = function(box, shift)
  local x = shift[1] or shift.x
  local y = shift[2] or shift.y
  local new =
  {
    left_top = {},
    right_bottom = {}
  }
  new.left_top.x = box.left_top.x + x
  new.left_top.y = box.left_top.y + y
  new.right_bottom.x = box.right_bottom.x + x
  new.right_bottom.y = box.right_bottom.y + y
  return new
end

-- Helper to get a unit's attack range from its prototype
local get_attack_range = function(prototype)
  local attack_parameters = prototype.attack_parameters
  if not attack_parameters then return end
  return attack_parameters.range
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
add_unit_indicators = function(unit_data)

  update_selection_indicators(unit_data)
  clear_indicators(unit_data)

  local player = unit_data.player
  if not player then return end

  local unit = unit_data.entity
  if not unit and unit.valid then return end

  local indicators = {}
  unit_data.indicators = indicators

  local surface = unit.surface
  local players = {unit_data.player}

  local rendering = rendering
  local draw_line = rendering.draw_line
  local gap_length = 1.25
  local dash_length = 0.25

  -- Draw line to current destination
  if unit_data.destination then
    indicators[draw_line
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
    }] = true
  end

  -- Draw line to a target entity
  if unit_data.destination_entity and unit_data.destination_entity.valid then
    indicators[draw_line
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
    }] = true
  end

  -- Draw lines for all queued commands
  local position = unit_data.destination or unit.position
  for k, command in pairs (unit_data.command_queue) do
    if command.command_type == next_command_type.move then
      indicators[draw_line
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
      }] = true
      position = command.destination
    end

    -- Draw lines for patrol routes
    if command.command_type == next_command_type.patrol then
      for k = 1, #command.destinations do
        local to = command.destinations[k]
        local from = command.destinations[k + 1] or command.destinations[1]
        indicators[draw_line
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
        }] = true
      end
    end

  end

end

-- Clears and redraws all indicators for all units
local reset_rendering = function()
  rendering.clear("erm_unit_control")
  for k, unit_data in pairs (script_data.units) do
    local unit = unit_data.entity
    if unit and unit.valid then
      clear_indicators(unit_data)
      clear_selection_indicator(unit_data)
      remove_target_indicator(unit_data)
      unit_data.selection_indicators = nil
      add_unit_indicators(unit_data)
    else
      script_data.units[k] = nil
    end
  end
end

local stop = {type = defines.command.stop}
local hold_position_command = {type = defines.command.stop, speed = 0}

-- Stops the unit and sets it to an 'idle' or 'wander' state
set_unit_idle = function(unit_data)
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
    set_command(unit_data, idle_command)
  end
  return add_unit_indicators(unit_data)
end

-- Marks a unit as 'not idle' (i.e., it has a command)
local set_unit_not_idle = function(unit_data)
  unit_data.idle = false
  return add_unit_indicators(unit_data)
end

-- Gets the player's main unit control GUI frame
local get_frame = function(player_index)
  local frame = script_data.open_frames[player_index]
  if not (frame and frame.valid) then
    script_data.open_frames[player_index] = nil
    return
  end
  return frame
end

-- Issues 'stop' commands to the selected group
local stop_group = function(player, queue)
  local group = get_selected_units(player.index)
  if not group then
    return
  end
  local idle_queue = {command_type = next_command_type.idle}
  local units = script_data.units
  for unit_number, unit in pairs (group) do
    local unit_data = units[unit_number]
    if queue and not unit_data.idle then
      insert(unit_data.command_queue, idle_queue)
    else
      set_unit_idle(unit_data, true)
    end
  end
  player.play_sound({path = tool_names.unit_move_sound})
end

-- Issues 'hold position' commands to the selected group
local hold_position_group = function(player, queue)
  local group = get_selected_units(player.index)
  if not group then
    return
  end
  local hold_position_queue = {command_type = next_command_type.hold_position}
  local units = script_data.units
  for unit_number, unit in pairs (group) do
    local unit_data = units[unit_number]
    if queue and not unit_data.idle then
      table.insert(unit_data.command_queue, hold_position_queue)
    else
      if unit.type == "unit" then
        unit_data.command_queue = {}
        set_command(unit_data, hold_position_command)
        set_unit_not_idle(unit_data)
      else
        unit_data.command_queue = {hold_position_queue}
        add_unit_indicators(unit_data)
      end
    end
  end
  player.play_sound({path = tool_names.unit_move_sound})
end

-- Adds a unit to a list to be processed for an attack command
local register_to_attack = function(unit_data)
  insert(script_data.attack_register, unit_data)
end



local type_handlers = {
  [next_command_type.move] = function(data)
    local unit_data = data.unit_data
    local next_command = data.next_command
    set_command(unit_data, next_command)
    unit_data.destination = next_command.destination
    unit_data.distraction = next_command.distraction
    table.remove(unit_data.command_queue, 1)
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
    set_command(unit_data,
            {
              type = defines.command.go_to_location,
              destination = entity.surface.find_non_colliding_position(entity.name, next_destination, 0, 0.5) or entity.position,
              radius = 1,
              distraction = next_command.distraction
            })
  end,
  [next_command_type.patrol] = function(data)
    local unit_data = data.unit_data
    register_to_attack(unit_data)
  end,
  [next_command_type.idle] = function(data)
    local unit_data = data.unit_data
    unit_data.command_queue = {}
    set_unit_idle(unit_data, true)
  end,
  [next_command_type.scout] = function(data)
    local unit_data = data.unit_data
    local event = data.event
    set_scout_command(unit_data, event.result == defines.behavior_result.fail)
  end,
  [next_command_type.hunt] = function(data)
    local unit_data = data.unit_data
    local event = data.event
    HuntingMode.update(unit_data, set_command, set_unit_idle, event)
  end,
  [next_command_type.qrf] = function(data)
    local unit_data = data.unit_data
    QRFMode.update(unit_data, set_command)
  end,
  [next_command_type.perimeter] = function(data)
    local unit_data = data.unit_data
    PerimeterMode.update(unit_data, set_command, set_unit_idle)
  end,
  [next_command_type.hold_position] = function(data)
    local unit_data = data.unit_data
    set_command(unit_data, hold_position_command)
  end,
  [next_command_type.follow] = function(data)
    -- ignore, process somewhere else
  end
}

-- This is the core logic that runs when a unit finishes a command.
-- It checks the unit's `command_queue` and issues the next command
-- (e.g., move, patrol, hunt, etc.).
local process_command_queue = function(unit_data, event)
  local entity = unit_data.entity
  if not (entity and entity.valid) then
    if event then
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
      set_unit_idle(unit_data)
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

-- This table maps all GUI button clicks to their functions
local gui_actions =
{
  move_button = function(event)
    local player = game.players[event.player_index]
    if not (player and player.valid) then return end
    player.clear_cursor()
    if not player.cursor_stack then return end
    player.cursor_stack.set_stack{name = tool_names.unit_move_tool}
  end,
  patrol_button = function(event)
    local player = game.players[event.player_index]
    if not (player and player.valid) then return end
    player.clear_cursor()
    if not player.cursor_stack then return end
    player.cursor_stack.set_stack{name = tool_names.unit_patrol_tool}
  end,
  attack_move_button = function(event)
    local player = game.players[event.player_index]
    if not (player and player.valid) then return end
    player.clear_cursor()
    if not player.cursor_stack then return end
    player.cursor_stack.set_stack{name = tool_names.unit_attack_move_tool}
  end,
  attack_button = function(event)
    local player = game.players[event.player_index]
    if not (player and player.valid) then return end
    player.clear_cursor()
    if not player.cursor_stack then return end
    player.cursor_stack.set_stack{name = tool_names.unit_attack_tool}
  end,
  force_attack_button = function(event)
    local player = game.players[event.player_index]
    if not (player and player.valid) then return end
    player.clear_cursor()
    if not player.cursor_stack then return end
    player.cursor_stack.set_stack{name = tool_names.unit_force_attack_tool}
  end,
  follow_button = function(event)
    local player = game.players[event.player_index]
    if not (player and player.valid) then return end
    player.clear_cursor()
    if not player.cursor_stack then return end
    player.cursor_stack.set_stack{name = tool_names.unit_follow_tool}
  end,
  hold_position_button = function(event)
    hold_position_group(game.get_player(event.player_index), event.shift)
  end,
  stop_button = function(event)
    stop_group(game.get_player(event.player_index), event.shift)
  end,
  scout_button = function(event)
    local group = get_selected_units(event.player_index)
    if not group then
      return
    end
    local append = event.shift
    local scout_queue = {command_type = next_command_type.scout}
    local units = script_data.units
    for unit_number, unit in pairs (group) do
      local unit_data = units[unit_number]
      if append and not unit_data.idle then
        insert(unit_data.command_queue, scout_queue)
      else
        set_scout_command(unit_data, false, unit_number % 120)
        set_unit_not_idle(unit_data)
      end
    end
    game.get_player(event.player_index).play_sound({path = tool_names.unit_move_sound})
  end,
  
  -- Button to activate 'Hunt' mode
  hunt_button = function(event)
    local group = get_selected_units(event.player_index)
    if not group then return end
    
    local hunt_queue = {command_type = next_command_type.hunt}
    local units = script_data.units
    for unit_number, unit in pairs(group) do
      local unit_data = units[unit_number]
      unit_data.mode = "hunt"
      unit_data.original_position = nil
      unit_data.aggro_target = nil
      unit_data.command_queue = {hunt_queue}
      set_unit_not_idle(unit_data)
      process_command_queue(unit_data) -- Start the command immediately
    end
    game.get_player(event.player_index).play_sound({path = tool_names.unit_move_sound})
  end,

  -- Button to activate 'QRF' (Quick Reaction Force) mode
  qrf_button = function(event)
    local group = get_selected_units(event.player_index)
    if not group then return end
    
    local qrf_queue = {command_type = next_command_type.qrf}
    local units = script_data.units
    for unit_number, unit in pairs(group) do
      local unit_data = units[unit_number]
      unit_data.mode = "qrf"
      unit_data.original_position = unit.position -- Store current pos
      unit_data.command_queue = {qrf_queue}
      set_unit_not_idle(unit_data)
      process_command_queue(unit_data) -- Start the command immediately
    end
    game.get_player(event.player_index).play_sound({path = tool_names.unit_move_sound})
  end,

  -- Button to activate 'Perimeter' mode
  perimeter_button = function(event)
    local group = get_selected_units(event.player_index)
    if not group then return end
    
    local perimeter_queue = {command_type = next_command_type.perimeter}
    local units = script_data.units
    for unit_number, unit in pairs(group) do
      local unit_data = units[unit_number]
      unit_data.mode = "perimeter"
      unit_data.original_position = unit.position -- Store current pos
      unit_data.command_queue = {perimeter_queue}
      set_unit_not_idle(unit_data)
      process_command_queue(unit_data) -- Start the command immediately
    end
    game.get_player(event.player_index).play_sound({path = tool_names.unit_move_sound})
  end,

  -- Button for selecting a control group from the GUI
  control_group_button = function(event, action)
    local player = game.get_player(event.player_index)
    if not player then return end
    
    local group_number = tonumber(action.group_number)

    if event.shift then
      -- Additive selection (Shift-click)
      local player_index = player.index
      local group_units_list = script_data.control_groups[player_index] and script_data.control_groups[player_index][group_number]
      if not group_units_list then return end 

      local current_selection_map = get_selected_units(player_index) or {}
      local all_units = script_data.units
      local valid_units_to_select_map = {}

      -- Add currently selected units
      for unit_number, entity in pairs(current_selection_map) do
        if entity and entity.valid then
          valid_units_to_select_map[unit_number] = entity
        end
      end

      -- Add new group's units
      for unit_number, _ in pairs(group_units_list) do
        local unit_data = all_units[unit_number]
        if unit_data and unit_data.entity and unit_data.entity.valid then
          valid_units_to_select_map[unit_number] = unit_data.entity
        end
      end

      -- Convert map back to a list
      local entities_list = {}
      for unit_number, entity in pairs(valid_units_to_select_map) do
        table.insert(entities_list, entity)
      end
      
      clear_selected_units(player) 
      
      if table_size(entities_list) > 0 then
        process_unit_selection(entities_list, player)
      end

    else
      -- Regular selection (Left-click)
      -- This calls the same function as the hotkey, but
      -- it won't center the camera, which is correct for a GUI click.
      select_control_group({player_index = player.index}, group_number)
    end
  end,

  -- Button to close the GUI
  exit_button = function(event)
    local group = get_selected_units(event.player_index)
    if not group then return end

    local units = script_data.units
    for unit_number, entity in pairs (group) do
      deselect_units(units[unit_number])
      group[unit_number] = nil
    end
    script_data.selected_units[event.player_index] = nil
    
    -- Force GUI to destroy (prevents potential bug in multiplayer)
    local frame = get_frame(event.player_index)
    if not (frame and frame.valid) then return end
    util.deregister_gui(frame, script_data.button_actions)
    frame.destroy()
  end,
  
  -- Button for a specific unit type inside the GUI (e.g., clicking the 'grunt' icon)
  selected_units_button = function(event, action)
    local unit_name = action.unit
    local group = get_selected_units(event.player_index)
    if not group then return end
    local right = (event.button == defines.mouse_button_type.right)
    local left = (event.button == defines.mouse_button_type.left)
    local units = script_data.units

    if right then
      if event.shift then
        -- Right-shift-click: Deselect half
        local count = 0
        for unit_number, entity in pairs (group) do
          if entity.name == unit_name then
            count = count + 1
          end
        end
        local to_leave = math.ceil(count / 2)
        count = 0
        for unit_number, entity in pairs (group) do
          if entity.name == unit_name then
            if count > to_leave then
              deselect_units(units[unit_number])
              group[unit_number] = nil
            end
            count = count + 1
          end
        end
      else
        -- Right-click: Deselect one
        for unit_number, entity in pairs (group) do
          if entity.name == unit_name then
            deselect_units(units[unit_number])
            group[unit_number] = nil
            break
          end
        end
      end
    end

    if left then
      if event.shift then
        -- Left-shift-click: Deselect all of this type
        for unit_number, entity in pairs (group) do
          if entity.name == unit_name then
            deselect_units(units[unit_number])
            group[unit_number] = nil
          end
        end
      else
        -- Left-click: Select *only* this type
        for unit_number, entity in pairs (group) do
          if entity.name ~= unit_name then
            deselect_units(units[unit_number])
            group[unit_number] = nil
          end
        end
      end
    end
  end
}

-- Defines the visual properties (sprite, tooltip) for the buttons
local button_map =
{
  move_button = {sprite = "utility/mod_dependency_arrow", tooltip = {"tooltip." .. tool_names.unit_move_tool}, style = "shortcut_bar_button_small_green"},
  patrol_button = {sprite = "utility/refresh", tooltip = {"tooltip." .. tool_names.unit_patrol_tool}, style = "shortcut_bar_button_small_blue"},
  attack_move_button = {sprite = "utility/center", tooltip = {"tooltip." .. tool_names.unit_attack_move_tool}},
  hold_position_button = {sprite = "utility/downloading", tooltip = {"custom-input-name.hold-position"}},
  stop_button = {sprite = "utility/close_black", tooltip = {"custom-input-name.stop"}, style = "shortcut_bar_button_small_red"},
  scout_button = {sprite = "utility/map", tooltip = {"custom-input-name.scout"}},
  hunt_button = {sprite = "utility/center", tooltip = {"gui.hunt-mode"}, style = "shortcut_bar_button_small_red"},
  qrf_button = {sprite = "utility/downloading", tooltip = {"gui.qrf-mode"}, style = "shortcut_bar_button_small_blue"},
  perimeter_button = {sprite = "utility/refresh", tooltip = {"gui.perimeter-mode"}, style = "shortcut_bar_button_small_green"}
}

-- Creates or updates the main unit control GUI for a player
local make_unit_gui = function(player)
  local index = player.index
  local frame = get_frame(index)
  if not (frame and frame.valid) then return end
  util.deregister_gui(frame, script_data.button_actions)

  local group = get_selected_units(index)

  -- If no units are selected, destroy the GUI
  if not group then
    script_data.last_location[index] = frame.location
    frame.destroy()
    return
  end

  frame.clear()
  local header_flow = frame.add{type = "flow", direction = "horizontal"}
  local label = header_flow.add{type = "label", caption = {"gui.unit-control"}}
  label.drag_target = frame
  local pusher = header_flow.add{type = "empty-widget", direction = "horizontal", style = "draggable_space_header"}
  pusher.style.horizontally_stretchable = true
  pusher.style.height = 16 * player.display_scale
  pusher.drag_target = frame
  local exit_button = header_flow.add{type = "sprite-button", style = "frame_action_button", sprite = "utility/close"}
  exit_button.style.height = 24
  exit_button.style.width = 24

  util.register_gui(script_data.button_actions, exit_button, {type = "exit_button"})

  -- Draw the control group buttons
  local player_control_groups = script_data.control_groups[index] or {}
  local all_units_data = script_data.units
  local has_control_groups = false
  local control_group_data_for_gui = {}

  -- Check groups 1-10 (10 is bound to '0')
  for i = 1, 10 do
    local unit_list = player_control_groups[i]
    if unit_list and table_size(unit_list) > 0 then
      local valid_count = 0
      -- Clean the group to get an accurate count of valid units
      for unit_number, _ in pairs(unit_list) do
        local unit_data = all_units_data[unit_number]
        if unit_data and unit_data.entity and unit_data.entity.valid then
          valid_count = valid_count + 1
        end
      end
      
      if valid_count > 0 then
        has_control_groups = true
        table.insert(control_group_data_for_gui, {number = i, count = valid_count})
      end
    end
  end

  -- Add the control group button bar to the GUI
  if has_control_groups then
    local cg_frame = frame.add{type="frame", style="inside_deep_frame", direction="vertical"}
    local cg_table = cg_frame.add{type="table", column_count=10, style="filter_slot_table"}
    
    for _, data in pairs(control_group_data_for_gui) do
      local group_number = data.number
      local group_count = data.count
      
      local signal_number = (group_number == 10) and 0 or group_number 
      local signal_sprite = "virtual-signal/signal-" .. signal_number
      local signal_tooltip = {"custom-input-name.erm-unit-control-select_control_group_" .. signal_number}

      local button = cg_table.add{
        type = "sprite-button",
        sprite = signal_sprite,
        number = group_count,
        tooltip = signal_tooltip,
        style = "slot_button"
      }
      util.register_gui(script_data.button_actions, button, {type = "control_group_button", group_number = group_number})
    end
  end

  -- Draw the icons for currently selected units
  local map = {}
  for unit_number, ent in pairs (group) do
    local name = ent.name
    map[name] = (map[name] or 0) + 1
  end
  local inner = frame.add{type = "frame", style = "inside_deep_frame", direction = "vertical"}
  local spam = inner.add{type = "frame"}
  local subfooter = inner.add{type = "frame", style = "subfooter_frame"}
  subfooter.style.horizontally_stretchable = true
  spam.style.minimal_height = 0
  spam.style.width = 400 * player.display_scale
  local tab = spam.add{type = "table", column_count = 10, style = "filter_slot_table"}
  local pro = prototypes.entity
  for name, count in pairs (map) do
    local ent = pro[name]
    local unit_button = tab.add{type = "sprite-button", sprite = "entity/"..name, tooltip = ent.localised_name, number = count, style = "slot_button"}
    util.register_gui(script_data.button_actions, unit_button, {type = "selected_units_button", unit = name})
  end

  -- Draw the command buttons (Move, Patrol, Hunt, etc.)
  subfooter.add{type = "empty-widget"}.style.horizontally_stretchable = true
  local butts = subfooter.add{type = "table", column_count = 10}
  for action, param in pairs (button_map) do
    local button = butts.add{type = "sprite-button", sprite = param.sprite, tooltip = param.tooltip, style = param.style or "shortcut_bar_button_small"}
    button.style.height = 24 * player.display_scale
    button.style.width = 24 * player.display_scale
    util.register_gui(script_data.button_actions, button, {type = action})
  end
end

-- Cleans up a unit from the mod's data when it's removed
local deregister_unit = function(entity)
  if not (entity and entity.valid) then return end
  local unit_number = entity.unit_number
  if not unit_number then return end
  local unit = script_data.units[unit_number]
  if not unit then return end
  script_data.units[unit_number] = nil

  deselect_units(unit)

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

local double_click_delay = 30

-- Helper to detect double-clicks
local is_double_click = function(event)
  local this_area = event.area
  local radius = util.radius(this_area)
  if radius > 1 then return end

  local last_selection_tick = script_data.last_selection_tick[event.player_index]
  script_data.last_selection_tick[event.player_index] = event.tick

  if not last_selection_tick then
    return
  end


  local click_position = this_area.left_top
  local position = script_data.last_left_click_position
  script_data.last_left_click_position = click_position

  if position and click_position then
    if util.distance(position, click_position) > 1 then
      return
    end
  end

  local duration = event.tick - last_selection_tick
  return duration <= double_click_delay
end

-- Helper to detect double-right-clicks
local is_double_right_click = function(event)
  local last_selection_tick = script_data.last_selection_tick[event.player_index]
  script_data.last_selection_tick[event.player_index] = event.tick

  if not last_selection_tick then
    return
  end

  local click_position = event.cursor_position
  local position = script_data.last_right_click_position
  script_data.last_right_click_position = click_position

  if position and click_position then
    if util.distance(position, click_position) > 1 then
      return
    end
  end

  local duration = event.tick - last_selection_tick

  return duration <= double_click_delay
end

-- Selects all units of the same type on screen
local select_similar_nearby = function(entity)
  local r = 32 * 4
  local origin = entity.position
  local area = {{origin.x - r, origin.y - r},{origin.x + r, origin.y + r}}
  return entity.surface.find_entities_filtered{area = area, force = entity.force, name = entity.name}
end

-- Checks if any GUIs are marked for refresh and updates them
local check_refresh_gui = function()
  if not next(script_data.marked_for_refresh) then return end
  for player_index, bool in pairs (script_data.marked_for_refresh) do
    make_unit_gui(game.get_player(player_index))
  end
  script_data.marked_for_refresh = {}
end

-- Handles adding units to a player's selection, creating the GUI if needed
process_unit_selection = function(entities, player)
  player.clear_cursor()
  local player_index = player.index
  local map = script_data.unit_unselectable
  local group = get_selected_units(player_index) or {}
  local units = script_data.units
  local types = {}
  for k, entity in pairs (entities) do
    local name = entity.name
    if not map[name] then
      types[name] = true
      local unit_index = entity.unit_number
      group[unit_index] = entity

      local unit_data = units[unit_index]
      if unit_data then
        deselect_units(unit_data)
      else
        unit_data =
        {
          entity = entity,
          command_queue = {},
          idle = true
        }
        units[unit_index] = unit_data
      end
      unit_data.entity = entity
      unit_data.group = group
      unit_data.player = player_index
      add_unit_indicators(unit_data)
    end
  end
  script_data.selected_units[player_index] = group

  local frame = get_frame(player_index)
  if not frame then
    frame = player.gui.screen.add{type = "frame", direction = "vertical"}
    local width = (12 + 400 + 12) * player.display_scale
    local size = player.display_resolution

    -- Check if player has groups to determine extra height for the GUI
    local extra_height = 0
    local player_control_groups = script_data.control_groups[player_index]
    if player_control_groups and next(player_control_groups) then
      for i = 1, 10 do
         if player_control_groups[i] and table_size(player_control_groups[i]) > 0 then
            local has_valid_unit = false
            for unit_num, _ in pairs(player_control_groups[i]) do
              if script_data.units[unit_num] and script_data.units[unit_num].entity and script_data.units[unit_num].entity.valid then
                has_valid_unit = true
                break
              end
            end
            if has_valid_unit then
              extra_height = 40 -- Add height for one row of control group buttons
              break
            end
         end
      end
    end

    local x_position = (size.width / 2) -  (width / 2)
    local y_position = size.height  - ((200 + extra_height + (math.ceil(table_size(types) / 10) * 40)) * player.display_scale)
    if script_data.last_location[player_index] then
      frame.location = script_data.last_location[player_index]
    else
      frame.location = {x_position, y_position}
      script_data.last_location[player_index] = {x_position, y_position}
    end
    script_data.open_frames[player_index] = frame
    player.opened = frame
  end
  script_data.marked_for_refresh[player_index] = true
  check_refresh_gui()
end

-- Clears a player's entire selection
clear_selected_units = function(player)
  local units = script_data.units
  local group = get_selected_units(player.index)
  if not group then return end
  for unit_number, ent in pairs (group) do
    deselect_units(units[unit_number])
    group[unit_number] = nil
  end
end

-- Event handler for when a player selects units
local unit_selection = function(event)
  local entities = event.entities
  if not entities then return end

  local append = (event.name == defines.events.on_player_alt_selected_area)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end

  if not append then
    clear_selected_units(player)
  end

  local first_index, first = next(entities)
  if first and is_double_click(event) then
    entities = select_similar_nearby(first)
  end

  process_unit_selection(entities, player)
end

-- Helper to get prototype info for a group
local get_offset = function(entities)
  local map = {}
  local small = 1
  for k, entity in pairs (entities) do
    local name = entity.name
    if not map[name] then
      map[name] = entity.prototype
    end
  end
  local rad = util.radius
  local speed = math.huge
  local max = math.max
  local min = math.min
  for name, prototype in pairs (map) do
    small = max(small, rad(prototype.selection_box) * 2)
    if prototype.type == "unit" then
      speed = min(speed, prototype.speed)
    end
  end
  if speed == math.huge then speed = nil end
  return small, math.ceil((small * (table_size(entities) -1) ^ 0.5)), speed
end

-- Helper to get the minimum speed of a group
local get_min_speed = function(entities)
  local map = {}
  local speed = math.huge
  for k, entity in pairs (entities) do
    local name = entity.name
    if not map[name] then
      map[name] = entity.prototype
    end
  end
  local min = math.min
  for name, prototype in pairs (map) do
    speed = min(speed, prototype.speed)
  end
  return speed
end

-- Calculates positions for a unit formation (spiral pattern)
local positions = {}
local turn_rate = (math.pi * 2) / 1.618
local size_scale = 1
local get_move_offset = function(n, size)
  local size = (size or 1) * size_scale
  local position = positions[n]
  if position then
    return
    {
      x = position.x * size,
      y = position.y * size
    }
  end
  position = {}
  positions[n] = position
  position.x = math.sin(n * turn_rate)* (n ^ 0.5)
  position.y = math.cos(n * turn_rate) * (n ^ 0.5)
  return
  {
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
local make_move_command = function(param)
  local origin = param.position
  local distraction = param.distraction or defines.distraction.by_enemy
  local group = param.group
  local player = param.player
  local surface = player.surface
  local force = player.force
  local append = param.append
  local type = defines.command.go_to_location
  local find = surface.find_non_colliding_position
  local units = script_data.units
  local i = 0

  local size, speed = get_group_size_and_speed(group)

  for unit_number, entity in pairs (group) do
    local offset = get_move_offset(i, size)
    i = i + 1
    local destination = {origin.x + offset.x, origin.y + offset.y}
    local is_unit = (entity.type == "unit")
    local destination = find(entity.name, destination, 0, 0.5)
    local command =
    {
      command_type = next_command_type.move,
      type = type,
      distraction = distraction,
      radius = 0.5,
      speed = speed,
      pathfind_flags = path_flags,
      destination = destination,
      do_separation = true
    }
    local unit_data = units[unit_number]
    if append then
      if is_unit and unit_data.idle then
        set_command(unit_data, command)
      end
      insert(unit_data.command_queue, command)
    else
      if is_unit then
        set_command(unit_data, command)
        unit_data.command_queue = {}
      else
        unit_data.command_queue = {command}
      end
    end
    set_unit_not_idle(unit_data)
  end
end

-- Issues a simple move command
local move_units = function(event)
  local group = get_selected_units(event.player_index)
  if not group then
    script_data.selected_units[event.player_index] = nil
    return
  end
  local player = game.players[event.player_index]
  make_move_command{
    position = util.center(event.area),
    distraction = defines.distraction.none,
    group = group,
    append = event.name == defines.events.on_player_alt_selected_area,
    player = player
  }
  player.play_sound({path = tool_names.unit_move_sound})
end

-- Issues a move command from a right-click
local move_units_to_position = function(player, position, append)
  local group = get_selected_units(player.index)
  if not group then
    script_data.selected_units[player.index] = nil
    return
  end
  make_move_command
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
  local group = get_selected_units(event.player_index)
  if not group then
    script_data.selected_units[event.player_index] = nil
    return
  end
  local player = game.players[event.player_index]
  make_move_command{
    position = util.center(event.area),
    distraction = defines.distraction.by_anything,
    group = group,
    append = event.name == defines.events.on_player_alt_selected_area,
    player = player
  }
  player.play_sound({path = tool_names.unit_move_sound})
end

-- Issues an attack-move command from a right-click
local attack_move_units_to_position = function(player, position, append)
  local group = get_selected_units(player.index)
  if not group then
    script_data.selected_units[player.index] = nil
    return
  end
  make_move_command
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
local make_patrol_command = function(param)
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
  local units = script_data.units

  local size, speed = get_group_size_and_speed(group)
  local i = 0
  for unit_number, entity in pairs (group) do
    local offset = get_move_offset(i, size)
    i = i + 1
    local destination = {origin.x + offset.x, origin.y + offset.y}
    local unit_data = units[unit_number]
    local is_unit = (entity.type == "unit")
    local next_destination = find(entity.name, destination, 0, 0.5)
    local patrol_command = find_patrol_comand(unit_data.command_queue)
    if patrol_command and append then
      -- If appending, add a new point to the existing patrol
      insert(patrol_command.destinations, next_destination)
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
      set_unit_not_idle(unit_data)
      if is_unit then
        process_command_queue(unit_data)
      end
    elseif not patrol_command then
      insert(unit_data.command_queue, command)
      if is_unit and unit_data.idle then
        process_command_queue(unit_data)
      end
    end
    add_unit_indicators(unit_data)
  end
end

-- Issues a patrol command
local patrol_units = function(event)
  local group = get_selected_units(event.player_index)
  if not group then return end
  local player = game.players[event.player_index]
  make_patrol_command{
    position = util.center(event.area),
    distraction = defines.distraction.by_anything,
    group = group,
    append = event.name == defines.events.on_player_alt_selected_area,
    player = player
  }
  player.play_sound({path = tool_names.unit_move_sound})
end

-- Helper for quick distance check
local quick_dist = function(p1, p2)
  return (((p1.x - p2.x) * (p1.x - p2.x)) + ((p1.y - p2.y) * (p1.y - p2.y)))
end

local directions =
{
  [defines.direction.north] = {0, -1},
  [defines.direction.northeast] = {1, -1},
  [defines.direction.east] = {1, 0},
  [defines.direction.southeast] = {1, 1},
  [defines.direction.south] = {0, 1},
  [defines.direction.southwest] = {-1, 1},
  [defines.direction.west] = {-1, 0},
  [defines.direction.northwest] = {-1, -1},
}

local random = math.random
local follow_range = 32
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
    set_command(unit_data, stop)
    return
  end

  local speed = target.speed

  if speed and distance(target.position, unit.position) > follow_range then
    set_command(unit_data,
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
  set_command(unit_data,
  {
    type = defines.command.go_to_location,
    destination = {target.position.x + offset.x, target.position.y + offset.y},
    radius = target.get_radius() + unit.get_radius() + 1,
    speed = speed
  })

end

-- Generates attack commands for a group
local make_attack_command = function(group, entities, append)
  if #entities == 0 then return end
  local script_data = script_data.units
  local next_command =
  {
    command_type = next_command_type.attack,
    targets = entities
  }
  for unit_number, unit in pairs (group) do
    local commandable = (unit.type == "unit")
    local unit_data = script_data[unit_number]
    if append then
      table.insert(unit_data.command_queue, next_command)
      if unit_data.idle and commandable then
        register_to_attack(unit_data)
      end
    else
      unit_data.command_queue = {next_command}
      if commandable then
        register_to_attack(unit_data)
      end
    end
    set_unit_not_idle(unit_data)
  end
end

-- Generates follow commands for a group
local make_follow_command = function(group, target, append)
  if not (target and target.valid) then return end
  local script_data = script_data.units
  for unit_number, unit in pairs (group) do
    local commandable = (unit.type == "unit")
    local next_command =
    {
      command_type = next_command_type.follow,
      target = target
    }
    local unit_data = script_data[unit_number]
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
    set_unit_not_idle(unit_data)
  end
end

-- Issues an attack command
local attack_units = function(event)
  local group = get_selected_units(event.player_index)
  if not group then return end

  local append = event.name == defines.events.on_player_alt_selected_area
  make_attack_command(group, event.entities, append)
  game.get_player(event.player_index).play_sound({path = tool_names.unit_move_sound})
end

-- Issues a follow command
local follow_entity = function(event)
  local group = get_selected_units(event.player_index)
  if not group then return end

  local target = event.entities[1]
  if not target then return end
  local append = event.name == defines.events.on_player_alt_selected_area
  make_follow_command(group, target, append)
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
local selected_area_actions =
{
  [tool_names.unit_selection_tool] = unit_selection,
  [tool_names.unit_move_tool] = multi_move_selection,
  [tool_names.unit_patrol_tool] = patrol_units,
  [tool_names.unit_attack_move_tool] = multi_attack_selection,
}

local alt_selected_area_actions =
{
  [tool_names.unit_selection_tool] = unit_selection,
  [tool_names.unit_move_tool] = multi_move_selection,
  [tool_names.unit_patrol_tool] = patrol_units,
  [tool_names.unit_attack_move_tool] = multi_attack_selection,
}

local clear_poop = function(player_index)
  local player = game.get_player(player_index)
  if not player then return end
  local cursor = player.cursor_stack
  if not (cursor and cursor.valid and cursor.valid_for_read) then return end
  if cursor.name == "select-units" then
    cursor.clear()
  end
end

-- Main event handler for player selection
local on_player_selected_area = function(event)
  clear_poop(event.player_index)
  local action = selected_area_actions[event.item]
  if not action then return end
  return action(event)
end

-- Main event handler for player alt-selection (shift-click)
local on_player_alt_selected_area = function(event)
  clear_poop(event.player_index)
  local action = alt_selected_area_actions[event.item]
  if not action then return end
  return action(event)
end

-- Main event handler for all GUI clicks
local on_gui_click = function(event)
  local element = event.element
  if not (element and element.valid) then return end
  local player_data = script_data.button_actions[event.player_index]
  if not player_data then return end
  local action = player_data[element.index]
  if action then
    gui_actions[action.type](event, action)
    return true
  end
end

-- Event handler for when an entity is removed
-- Cleans up unit data and control groups
local on_entity_removed = function(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  local unit_number = entity.unit_number
  if not unit_number then return end

  script_data.target_indicators[get_unit_number(entity)] = nil
  
  -- Check if this unit was in any control group and mark GUI for refresh
  for player_index, player_groups in pairs(script_data.control_groups) do
    if get_frame(player_index) then
      local group_changed = false
      for group_id, unit_list in pairs(player_groups) do
        if unit_list[unit_number] then
          group_changed = true
        end
        if group_changed then break end
      end
      if group_changed then
        script_data.marked_for_refresh[player_index] = true
      end
    end
  end
  
  deregister_unit(event.entity)
end

-- Event handler for when a unit is damaged
-- Triggers 'hunt' mode retaliation
--[[
-- Disabling this feature to improve performance.
-- The on_entity_damaged event can fire very frequently
-- and cause performance spikes in large battles.
local function on_entity_damaged(event)
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
  set_command(unit_data, {
    type = defines.command.attack,
    target = cause,
    distraction = defines.distraction.by_enemy
  })
end
]]


local wants_enemy_attack =
{
  [defines.distraction.by_enemy] = true,
  [defines.distraction.by_anything] = true
}

local entity_with_health_types =
{
  "container", "storage-tank", "transport-belt", "underground-belt", "splitter", "loader", "inserter", "electric-pole", "pipe", "pipe-to-ground", "pump", "curved-rail", "straight-rail", "train-stop", "rail-signal", "rail-chain-signal", "locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon", "car", "spider-vehicle", "logistic-robot", "construction-robot", "logistic-container", "roboport", "lamp", "arithmetic-combinator", "decider-combinator", "constant-combinator", "power-switch", "programmable-speaker", "boiler", "generator", "solar-panel", "accumulator", "reactor", "heat-pipe", "mining-drill", "offshore-pump", "furnace", "assembling-machine", "lab", "beacon", "rocket-silo", "unit", "land-mine", "wall", "gate", "ammo-turret", "electric-turret", "fluid-turret", "artillery-turret", "radar", "simple-entity-with-force", "simple-entity-with-owner", "electric-energy-interface", "linked-container", "heat-interface", "linked-belt", "infinity-container", "infinity-pipe", "burner-generator", "player-port", "combat-robot", "turret", "unit-spawner", "character", "fish", "tree", "simple-entity", "loader-1x1", "spider-leg", "market"
}

local has_enough_health = function(entity)
  return (entity.health - entity.get_damage_to_be_taken()) > 0
end

-- Handles unit AI distraction logic
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

local process_distraction_completed = function(event)

  local unit_data = script_data.units[event.unit_number]
  if not unit_data then return end

  local unit = unit_data.entity
  if not (unit and unit.valid) then return end

  local enemy = select_distraction_target(unit)

  if not enemy then return end

  unit.commandable.set_distraction_command
  {
    type = defines.command.attack,
    target = enemy
  }

end

-- Main event handler for when a unit's AI finishes a command
-- This is the trigger to call `process_command_queue`
local on_ai_command_completed = function(event)
  local unit_data = script_data.units[event.unit_number]
  if unit_data then
    return process_command_queue(unit_data, event)
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
      process_command_queue(unit_data)
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
      draw_temp_attack_indicator(command.target, unit_data.player)
      set_command(unit_data, command)
    end
  end
end

-- Periodically processes the list of units waiting to attack
local process_attack_register = function(tick)
  if tick % 31 ~= 0 then return end
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
        insert(groups[targets], unit_data)
      else
        -- This is for our new Hunting Mode
        groups[unit_data.group] = groups[unit_data.group] or {}
        insert(groups[unit_data.group], unit_data)
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
          max_distance = 5000,
          force = group_leader.entity.force,
          type = {"unit", "turret"}
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
        process_command_queue(unit_data)
      end
    end
  end

end

-- The main 'update' loop, run every game tick
local on_tick = function(event)
  process_attack_register(event.tick)
  check_refresh_gui()
end

local suicide = function(event)
  local group = get_selected_units(event.player_index)
  if not group then return end
  local unit_number, entity = next(group)
  if entity then entity.die() end
end

local suicide_all = function(event)
  local group = get_selected_units(event.player_index)
  if not group then return end
  for unit_number, entity in pairs (group) do
    if entity and entity.valid then entity.die() end
  end
end

-- Copies unit command data when a player copies settings from one unit spawner to another
local on_entity_settings_pasted = function(event)
  local source = event.source
  local destination = event.destination
  if not (source and source.valid and destination and destination.valid) then return end
  deregister_unit(destination)
  local unit_data = script_data.units[source.unit_number]
  if not unit_data then return end
  local copy = util.copy(unit_data)
  copy.entity = destination
  copy.player = nil
  script_data.units[destination.unit_number] = copy
end

-- Cleans up a player's GUI and selected units when they leave
local on_player_removed = function(event)
  local frame = script_data.open_frames[event.player_index]
  if (frame and frame.valid) then
    util.deregister_gui(frame, script_data.button_actions)
    frame.destroy()
  end
  script_data.open_frames[event.player_index] = nil

  local group = get_selected_units(event.player_index)
  if not group then return end

  local units = script_data.units
  for unit_number, ent in pairs (group) do
    deselect_units(units[unit_number])
  end
end

-- This mod disables vanilla unit groups by destroying them
local NO_GROUP = true
local on_unit_added_to_group = function(event)
  local unit = event.unit
  if not (unit and unit.valid) then return end
  local group = event.group
  if not (group and group.valid) then return end
  local unit_data = script_data.units[unit.unit_number]
  if not unit_data then
    return
  end
  if NO_GROUP then
    group.destroy()
    process_command_queue(unit_data)
    return
  end
end

local on_unit_removed_from_group = function(event)
  if NO_GROUP then return end
  local unit = event.unit
  if not (unit and unit.valid) then return end
  local unit_data = script_data.units[unit.unit_number]
  if unit_data and unit_data.in_group then
    return process_command_queue(unit_data)
  end
end

-- A cleanup function to remove invalid units
local validate_some_stuff = function()
  local units = script_data.units
  for unit_number, unit_data in pairs (units) do
    local entity = unit_data.entity
    if not (entity and entity.valid) then
      units[unit_number] = nil
    end
  end
end

-- Modifies Factorio's pathfinding settings for better performance
local set_map_settings = function()
  local settings = game.map_settings
  settings.path_finder.max_steps_worked_per_tick = 400
  settings.path_finder.max_clients_to_accept_any_new_request = 1000
  settings.path_finder.use_path_cache = false
  settings.steering.moving.force_unit_fuzzy_goto_behavior = true
  settings.steering.default.force_unit_fuzzy_goto_behavior = false
  settings.max_failed_behavior_count = 5
end

-- Event handler for when a unit spawner creates a unit
-- Copies the spawner's command queue to the new unit
local on_entity_spawned = function(event)
  local source = event.spawner
  local unit = event.entity
  if not (source and source.valid and unit and unit.valid) then return end
  if unit.type ~= "unit" then return end
  
  local source_data = script_data.units[source.unit_number]
  if not source_data then
    unit.commandable.set_command({type = defines.command.wander, radius = source.get_radius()})
    return
  end

  local queue = source_data.command_queue
  local unit_data =
  {
    entity = unit,
    command_queue = util.copy(queue),
    idle = false
  }
  script_data.units[unit.unit_number] = unit_data

  local i = math.random(50)
  local offset = get_move_offset(math.random(50))
  for k, command in pairs (unit_data.command_queue) do
    command.speed = nil
    if command.command_type == next_command_type.move then
      command.destination = {x = command.destination.x + offset.x, y = command.destination.y + offset.y}
    end
    if command.command_type == next_command_type.patrol then
      for k, destination in pairs (command.destinations) do
        destination = {x = destination.x + offset.y, y = destination.y + offset.x}
      end
    end
  end

  unit.release_from_spawner()
  return process_command_queue(unit_data)
end

-- Hotkey handlers
local stop_hotkey = function(event)
  stop_group(game.get_player(event.player_index))
end

local queue_stop_hotkey = function(event)
  stop_group(game.get_player(event.player_index), true)
end

local hold_position_hotkey = function(event)
  hold_position_group(game.get_player(event.player_index))
end

local queue_hold_position_hotkey = function(event)
  hold_position_group(game.get_player(event.player_index), true)
end

local unit_names
local get_unit_names = function()
  if unit_names then return unit_names end
  unit_names = {}
  for name, prototype in pairs (prototypes.item["select-units"].get_entity_filters(defines.selection_mode.select)) do
    if prototype.type == "unit" then
      table.insert(unit_names, prototype.name)
    end
  end
  return unit_names
end

local select_all_units_hotkey = function(event)
  local player = game.get_player(event.player_index)
  if not (player and player.valid) then return end

  clear_selected_units(player)

  local names = get_unit_names()
  if not next(unit_names) then return end
  local entities = player.surface.find_entities_filtered
  {
    position = event.cursor_position or {0,0},
    force = player.force,
    name = unit_names,
    radius = 200
  }
  process_unit_selection(entities, player)

end

-- Core logic for setting a control group
local set_control_group = function(event, group_number)
  local player_index = event.player_index
  local player = game.get_player(player_index)
  if not player then return end

  script_data.control_groups[player_index] = script_data.control_groups[player_index] or {}
  group_number = tonumber(group_number)
  
  local selected = get_selected_units(player_index)
  
  if not selected then
    -- No units selected, so clear the control group
    script_data.control_groups[player_index][group_number] = nil
    player.play_sound({path = "utility/cannot_build"})
  else
    -- Store the list of selected unit numbers
    local unit_numbers_list = {}
    for unit_number, _ in pairs(selected) do
      unit_numbers_list[unit_number] = true
    end
    script_data.control_groups[player_index][group_number] = unit_numbers_list
    player.play_sound({path = "utility/confirm"})
  end
  
  -- Refresh the GUI if it's open
  if get_frame(player_index) then
      script_data.marked_for_refresh[player_index] = true
  end
end

-- Core logic for selecting a control group
select_control_group = function(event, group_number)
  local player_index = event.player_index
  local player = game.get_player(player_index)
  if not player then return end
  
  group_number = tonumber(group_number)
  if not script_data.control_groups[player_index] or not script_data.control_groups[player_index][group_number] then
    player.play_sound({path = "utility/cannot_build"})
    return
  end

  local unit_numbers_list = script_data.control_groups[player_index][group_number]
  if not unit_numbers_list or table_size(unit_numbers_list) == 0 then
    player.play_sound({path = "utility/cannot_build"})
    return
  end

  local all_units = script_data.units
  local entities_to_select = {}
  local valid_unit_numbers = {} -- To clean dead units from the group

  for unit_number, _ in pairs(unit_numbers_list) do
    local unit_data = all_units[unit_number]
    if unit_data and unit_data.entity and unit_data.entity.valid then
      table.insert(entities_to_select, unit_data.entity)
      valid_unit_numbers[unit_number] = true
    end
  end

  -- Auto-clean the group of dead units
  script_data.control_groups[player_index][group_number] = valid_unit_numbers

  clear_selected_units(player)

  if table_size(entities_to_select) > 0 then
    process_unit_selection(entities_to_select, player)
    return entities_to_select
  else
    -- Group was full of dead units and is now empty
    script_data.control_groups[player_index][group_number] = nil
    script_data.marked_for_refresh[player_index] = true
    player.play_sound({path = "utility/cannot_build"})
    return nil
  end
end

-- Selects a group and also centers the camera on them
local function select_control_group_and_center_camera(event, group_number)
  local player = game.get_player(event.player_index)
  if not player then return end

  local selected_entities = select_control_group(event, group_number)
  if not selected_entities then return end
  
  local selected_size = table_size(selected_entities)
  if selected_size > 0 then
    -- Find the center position of the group
    local total_x, total_y = 0, 0
    for _, entity in pairs(selected_entities) do
      total_x = total_x + entity.position.x
      total_y = total_y + entity.position.y
    end

    local center_pos = {
      x = total_x / selected_size,
      y = total_y / selected_size
    }

    -- This block handles compatibility with Space Exploration/Space Age
    if remote.interfaces["space-exploration"] and remote.interfaces["space-exploration"]["remote_view_start"] then
      local surface = selected_entities[1].surface
      local zone_data = remote.call("space-exploration", "get_zone_from_surface_index", {surface_index = surface.index})

      if zone_data and zone_data.name then
        remote.call("space-exploration", "remote_view_start", {
          player = player,
          zone_name = zone_data.name,
          position = center_pos,
          freeze_history = true
        })
      else
        player.print({"ERM Unit Control: Could not find Space Exploration zone data for this surface."})
      end

    else
      local zoom = player.zoom
      player.set_controller {
        type = defines.controllers.remote,
        position = center_pos,
      }
      player.zoom = zoom
    end
  end
end

-- Exposes functions to be called by other mods
remote.add_interface("erm_unit_control", {
  register_unit_unselectable = function(entity_name)
    script_data.unit_unselectable[entity_name] = true
  end,
  get_events = function()
    return script_events
  end,
  set_debug = function(bool)
    script_data.debug = bool
  end,
  set_map_settings = function()
    set_map_settings()
  end,
  print_global = function()
    helpers.write_file("erm_unit_control/storage.json",helpers.table_to_json(util.copy(storage)))
  end,
  
  -- Allows other mods to assign a unit to a control group
  assign_control_group = function(player_index, control_group_index, unit)
    if not (player_index and control_group_index and unit and unit.valid) then
      log("ERM Unit Control: assign_control_group called with invalid arguments.")
      return
    end
    
    local unit_number = unit.unit_number
    if not unit_number then
      log("ERM Unit Control: assign_control_group called on unit with no unit_number.")
      return
    end

    -- Ensure unit is registered in our mod's data
    if not script_data.units[unit_number] then
      local unit_data = {
          entity = unit,
          command_queue = {},
          idle = true
      }
      script_data.units[unit_number] = unit_data
    end
    control_group_index = tonumber(control_group_index)
    -- Get/Initialize Control Group table
    script_data.control_groups[player_index] = script_data.control_groups[player_index] or {}
    local player_groups = script_data.control_groups[player_index]

    player_groups[control_group_index] = player_groups[control_group_index] or {}
    local group_list = player_groups[control_group_index]

    -- Add unit to group (if not already there)
    local found = false
    if group_list[unit_number] then
      found = true
    end

    if not found then
        group_list[unit_number] = true
    end
    
    if get_frame(player_index) then
        script_data.marked_for_refresh[player_index] = true
    end
  end
})

local allow_selection =
{
  ["unit"] = true,
  ["unit-spawner"] = true
}

local block_by_opened_gui = {
  [defines.gui_type.blueprint_library] = true
}

-- Checks if the player is in a state that allows our left-click override
local can_left_click = function(player, shift)
  if block_by_opened_gui[player.opened_gui_type] then return end
  if not shift and player.render_mode == defines.render_mode.chart then return end
  if player.cursor_ghost then return end
  if player.selected and not allow_selection[player.selected.type] then return end
  if not player.is_cursor_empty() then return end
  if player.opened ~= get_frame(player.index) then return end
  return true
end

-- Sets the player's cursor to the 'select-units' tool
local set_cursor_to_select = function(player)
  local stack = player.cursor_stack
  if not stack then return end
  if stack.valid_for_read then return end

  stack.set_stack({name = "select-units"})
  return true
end

-- Overrides the default left-click to start our unit selection
local left_click = function(event)
  local player = game.get_player(event.player_index)
  if not can_left_click(player) then
    return
  end
  if set_cursor_to_select(player) then
    player.start_selection(event.cursor_position, defines.selection_mode.select)
  end
end

-- Overrides the default shift-left-click
local shift_left_click = function(event)
  local player = game.get_player(event.player_index)
  if not can_left_click(player, true) then
    return
  end
  if set_cursor_to_select(player) then
    player.start_selection(event.cursor_position, defines.selection_mode.alt_select)
  end
end

-- Overrides the default right-click to issue unit commands
local right_click = function(event)
  local group = get_selected_units(event.player_index)
  if not group then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  local entities = player.surface.find_entities_filtered{position = event.cursor_position}
  local player_force = player.force
  local attack_entities = {}
  local follow_entity
  for k, entity in pairs(entities) do
    local force = entity.force
    if force == player_force then
      follow_entity = entity
    elseif not player_force.get_cease_fire(entity.force) then
      if entity.get_health_ratio() then
        attack_entities[k] = entity
      end
    end
  end

  if next(attack_entities) then
    make_attack_command(group, attack_entities, false)
    player.play_sound({path = tool_names.unit_move_sound})
    return
  end

  if follow_entity then
    make_follow_command(group, follow_entity, false)
    player.play_sound({path = tool_names.unit_move_sound})
    return
  end

  if is_double_right_click(event) then
    move_units_to_position(player, event.cursor_position)
  else
    attack_move_units_to_position(player, event.cursor_position)
  end

end

-- Overrides the default shift-right-click
local shift_right_click = function(event)
  local group = get_selected_units(event.player_index)
  if not group then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  local entities = player.surface.find_entities_filtered{position = event.cursor_position}
  local player_force = player.force
  local attack_entities = {}
  local follow_entity
  for k, entity in pairs(entities) do
    local force = entity.force
    if force == player_force then
      follow_entity = entity
    elseif not player_force.get_cease_fire(entity.force) then
      if entity.get_health_ratio() then
        attack_entities[k] = entity
      end
    end
  end

  if next(attack_entities) then
    make_attack_command(group, attack_entities, true)
    player.play_sound({path = tool_names.unit_move_sound})
    return
  end

  if follow_entity then
    make_follow_command(group, follow_entity, true)
    player.play_sound({path = tool_names.unit_move_sound})
    return
  end

  attack_move_units_to_position(player, event.cursor_position, true)

end

local on_gui_closed = function(event)
   gui_actions.exit_button(event)
end

-- Main event handler table
-- This maps all game events and hotkeys to the functions
local unit_control = {}

unit_control.events =
{
  [defines.events.on_tick] = on_tick,
  [defines.events.on_entity_settings_pasted] = on_entity_settings_pasted,
  [defines.events.on_player_selected_area] = on_player_selected_area,
  [defines.events.on_player_alt_selected_area] = on_player_alt_selected_area,
  [defines.events.on_gui_click] = on_gui_click,
  [defines.events.on_gui_closed] = on_gui_closed,

  [defines.events.on_entity_died] = on_entity_removed,
  [defines.events.on_robot_mined_entity] = on_entity_removed,
  [defines.events.on_player_mined_entity] = on_entity_removed,
  [defines.events.script_raised_destroy] = on_entity_removed,
  
  -- [defines.events.on_entity_damaged] = on_entity_damaged, -- Disabled for performance
  
  [defines.events.on_ai_command_completed] = on_ai_command_completed,
  [defines.events.on_unit_added_to_group] = on_unit_added_to_group,

  [names.hotkeys.suicide] = suicide,
  [names.hotkeys.suicide_all] = suicide_all,
  [names.hotkeys.stop] = stop_hotkey,
  [names.hotkeys.queue_stop] = queue_stop_hotkey,
  [names.hotkeys.hold_position] = hold_position_hotkey,
  [names.hotkeys.queue_hold_position] = queue_hold_position_hotkey,

  [defines.events.on_player_died] = on_player_removed,
  [defines.events.on_player_left_game] = on_player_removed,
  [defines.events.on_player_changed_force] = on_player_removed,
  [defines.events.on_player_changed_surface] = on_player_removed,

  [defines.events.on_surface_deleted] = validate_some_stuff,
  [defines.events.on_surface_cleared] = validate_some_stuff,
  [defines.events.on_entity_spawned] = on_entity_spawned,
  [script_events.on_unit_spawned] = on_entity_spawned,

  ["left-click"] = left_click,
  ["shift-left-click"] = shift_left_click,
  ["right-click"] = right_click,
  ["shift-right-click"] = shift_right_click,
  [names.hotkeys.select_all_units] = select_all_units_hotkey,

  -- Control Group Hotkeys
  [names.hotkeys.set_control_group_1] = function(e) set_control_group(e, 1) end,
  [names.hotkeys.set_control_group_2] = function(e) set_control_group(e, 2) end,
  [names.hotkeys.set_control_group_3] = function(e) set_control_group(e, 3) end,
  [names.hotkeys.set_control_group_4] = function(e) set_control_group(e, 4) end,
  [names.hotkeys.set_control_group_5] = function(e) set_control_group(e, 5) end,
  [names.hotkeys.set_control_group_6] = function(e) set_control_group(e, 6) end,
  [names.hotkeys.set_control_group_7] = function(e) set_control_group(e, 7) end,
  [names.hotkeys.set_control_group_8] = function(e) set_control_group(e, 8) end,
  [names.hotkeys.set_control_group_9] = function(e) set_control_group(e, 9) end,
  [names.hotkeys.set_control_group_0] = function(e) set_control_group(e, 10) end, -- 0 maps to 10
  
  [names.hotkeys.select_control_group_1] = function(e) select_control_group_and_center_camera(e, 1) end,
  [names.hotkeys.select_control_group_2] = function(e) select_control_group_and_center_camera(e, 2) end,
  [names.hotkeys.select_control_group_3] = function(e) select_control_group_and_center_camera(e, 3) end,
  [names.hotkeys.select_control_group_4] = function(e) select_control_group_and_center_camera(e, 4) end,
  [names.hotkeys.select_control_group_5] = function(e) select_control_group_and_center_camera(e, 5) end,
  [names.hotkeys.select_control_group_6] = function(e) select_control_group_and_center_camera(e, 6) end,
  [names.hotkeys.select_control_group_7] = function(e) select_control_group_and_center_camera(e, 7) end,
  [names.hotkeys.select_control_group_8] = function(e) select_control_group_and_center_camera(e, 8) end,
  [names.hotkeys.select_control_group_9] = function(e) select_control_group_and_center_camera(e, 9) end,
  [names.hotkeys.select_control_group_0] = function(e) select_control_group_and_center_camera(e, 10) end, -- 0 maps to 10
}

-- Standard Factorio mod function, runs when the mod is first initialized
unit_control.on_init = function()
  storage.unit_control = storage.unit_control or script_data
  -- Ensure new tables exist for migration
  storage.unit_control.group_hunt_data = storage.unit_control.group_hunt_data or {}
  storage.unit_control.control_groups = storage.unit_control.control_groups or {}
  
  set_map_settings()
end

-- Runs when mod is added to an existing save or when mod version changes
unit_control.on_configuration_changed = function(configuration_changed_data)
  storage.unit_control = storage.unit_control or script_data
  script_data = storage.unit_control

  -- Ensure new tables exist for migration
  script_data.group_hunt_data = script_data.group_hunt_data or {}
  script_data.control_groups = script_data.control_groups or {}

  set_map_settings()
  reset_rendering()
  script_data.last_location = script_data.last_location or {}
end

-- Runs when a save game is loaded
unit_control.on_load = function()
  script_data = storage.unit_control
end

return unit_control