function +(x::ASCIIString, y::ASCIIString)
  string(x, y)
end

function *(x::ASCIIString, y::Int)
  repeated = map(1:3) do i
    x
  end
  join(repeated, "")
end
