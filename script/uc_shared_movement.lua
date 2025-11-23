-- This module handles all group movement commands:
-- move, attack-move, patrol, follow, stop, hold position.

local Core = require("script/uc_core")
local Commands = require("script/uc_commands")
local Indicators = require("script/uc_indicators")
local util = require("script/script_util")

local SharedMovement = {}

local next_command_type = Core.next_command_type
local tool_names = Core.tool_names

-- Issues 'stop' commands to the selected group
function SharedMovement.stop_group(player, queue, group)
  local idle_queue = {command_type = next_command_type.idle}
  local script_data = storage.unit_control
  local units = script_data.units
  for unit_number, unit in pairs (group) do
    local unit_data = units[unit_number]
    if queue and not unit_data.idle then
      table.insert(unit_data.command_queue, idle_queue)
    else
      Commands.set_unit_idle(unit_data, true)
    end
  end
  player.play_sound({path = tool_names.unit_move_sound})
end

-- Issues 'hold position' commands to the selected group
function SharedMovement.hold_position_group(player, queue, group)
  local hold_position_queue = {command_type = next_command_type.hold_position}
  local hold_position_command = {type = defines.command.stop, speed = 0}
  local script_data = storage.unit_control
  local units = script_data.units
  for unit_number, unit in pairs(group) do
    local unit_data = units[unit_number]
    if queue and not unit_data.idle then
      table.insert(unit_data.command_queue, hold_position_queue)
    else
      if unit.type == "unit" then
        unit_data.command_queue = {}
        Commands.set_command(unit_data, hold_position_command)
        Commands.set_unit_not_idle(unit_data)
      else
        unit_data.command_queue = {hold_position_queue}
        Indicators.add_unit_indicators(unit_data)
      end
    end
  end
  player.play_sound({path = tool_names.unit_move_sound})
end

return SharedMovement