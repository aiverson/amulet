do
  local function Cons(x) return { x, __tag = "Cons" } end
  local Nil = { __tag = "Nil" }
  local function zip(f, xs, ys)
    if xs.__tag == "Nil" then
      return Cons({ _1 = 1, _2 = Nil })
    elseif xs.__tag == "Cons" then
      local fl = xs[1]
      if ys.__tag == "Nil" then
        return Cons({ _1 = 2, _2 = Nil })
      elseif ys.__tag == "Cons" then
        local fm = ys[1]
        return Cons({ _1 = f(fl._1)(fm._1), _2 = zip(f, fl._2, fm._2) })
      end
    end
  end
  local function zip0(f) return function(xs) return function(ys) return zip(f, xs, ys) end end end
  (nil)(zip0)
end
