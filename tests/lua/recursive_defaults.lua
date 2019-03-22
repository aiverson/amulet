do
  local __builtin_unit = { __tag = "__builtin_unit" }
  local use = print
  local function _dollardShowci(fl)
    return {
      show = function(fd) return "()" end,
      ["show'"] = function(dz) return _dollardShowci(__builtin_unit).show(dz) end
    }
  end
  use(_dollardShowci(__builtin_unit).show)
end
