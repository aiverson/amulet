do
  local file_close = io.close
  local file_read = io.read
  local _print = print
  local function file_load(fhandle)
    local output = file_read("*all")
    file_close(fhandle)
    return output
  end
end
