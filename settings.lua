-- This adds the new map setting for the selection limit
data:extend({
  {
    type = "int-setting",
    name = "erm-unit-control-selection-limit",
    setting_type = "runtime-global", -- "map" is not a valid type, "runtime-global" is what we want
    default_value = 100,
    min_value = 10,
    max_value = 1000, -- Let players set it high if they want
    order = "a-erm-a" -- Puts it near the top of the mod settings list
  }
})