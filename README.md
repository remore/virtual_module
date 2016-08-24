## VirtualModule

If you feel good with Ruby's language design but *totally* disappointed with Ruby's computational performance such as terribly slow speed of loop or Math functions, then VirtualModule may save you a little.

With VirtualModule, you can run your Ruby code on the other language VM process(currently only Julia is supported).

```
vm = VirtualModule.new(<<EOS)
def hi
  "ho"
end

# @param [Fixnum] num
def hello(num)
  num*num
end
EOS
p vm.hi #"ho"
include vm
p hello(33) #1089
```

## Other explanation

TBC

## License
MIT
