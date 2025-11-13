-- This adds the new map setting for the selection limit
data:extend({
  {
    type = "int-setting",
    name = "erm-unit-control-selection-limit",
    setting_type = "runtime-global", -- "map" is not a valid type, "runtime-global" is what we want
    default_value = 100,
    allowed_values = { 20, 30, 40, 50, 70, 100, 150, 200, 250, 300, 400, 500},
    order = "a-erm-a" -- Puts it near the top of the mod settings list
  }
})