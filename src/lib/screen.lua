local Screen = {}

function Screen.clearAndReset()
  term.clear()
  term.setCursorPos(1, 1)
end

return Screen
