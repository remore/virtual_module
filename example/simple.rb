require '../lib/virtual_module.rb'

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
p vm.zeros(2,2)
p vm.collect(vm.zeros(2,2))

my_objects = [23, 45, 67.03]
count_num = 229
mystruct = {:dog=>"woof", :cat=>"mew!", "pig"=>[1,2,3]}

vm.virtual_module_eval(<<EOS)
my_objects[1]=9191
count_num=hello(833)
mystruct["pig"][1] = 5678
print 9999999, my_objects[2]
EOS

p my_objects #[23, 9191, 67.03]
p count_num #693889

vm2 = VirtualModule.new(<<EOS, {:ipc=>:rpc})
def hey(x, y)
  "yo" + (x*y).to_s
end
EOS
p 1234
p vm2.hey(2,7)
