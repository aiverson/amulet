for i = 1, 10 do print(i) end
for i = 10, 1, -1 do print(i) end

local i = 1
while i <= 10 do
   print(i)
   i = i + 1
end

repeat
   print(i)
   i = i -1
until i < 1

while true do break end
