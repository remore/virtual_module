# VirtualModule

If you have ever felt at all disappointed seeing Ruby's computational performance particularly for large-scale scientific computation, VirtualModule may save you a little. It offers you a way to run your arbitrary Ruby code on the other language VM process(currently only Julia is supported). What make VirtualModule possible to do this is [ruby2julia transpiler](https://github.com/remore/julializer)(which is at very early stage of development) and IPC using [msgpack](http://msgpack.org/).

Let's take a look a results of [benchmark program](https://github.com/remore/virtual_module/blob/master/doc/benchmark_loop_performance/add_two_floating_numbers_cumulatively.rb) of which scores were taken on my MacBook Pro(OSX10.11, Core i5 2.9GHz, 8GB). Essentially this benchmarking program just repeats adding two floating point numbers cumulatively. If you run this program with setting of smaller number of loops, VirtualModule doesn't make sense at all as you can see:

![Benchmarking results](https://raw.githubusercontent.com/remore/virtual_module/master/doc/assets/benchmark-result-from-1e1-to-1e7.png "Graphs of average execution time vs number of loops(MacBook Pro)")

However as the number of loops gets bigger, VirtualModule significantly reduces total execution time. (For the sake of honor of python, here is [another benchmarking results](link_to_the_graph_in_case_of_Ubuntu) measured on Ubuntu16 on DigitalOcean. It records better score of python2.7 than the one with my MacBook Pro, although I'm not sure why this happens.)

![Benchmarking results](https://raw.githubusercontent.com/remore/virtual_module/master/doc/assets/benchmark-result-from-1e1-to-1e9.png "Graphs of average execution time vs number of loops(MacBook Pro)")

The other example here is a [prototype word2vec implementation in Ruby](https://github.com/remore/virtual_module/blob/master/example/word2vec.rb), which is just partially ported from [the one created by Tomas Mikolov at Google](https://code.google.com/archive/p/word2vec/). Since it's not optimized very well yet due to limited time to work on this example, it doesn't record decent score in terms of speed, but it reveals at least the fact that VirtualModule will reduces total execution time considerably even in real world example.

(ToDo: insert an image here of benchmarking result of three types of word2vec implementation)

## Usage and How it works(TBD)

VirtualModule is a Module generator which has only one public api named `VirtualModule#new`. In the following example, VirtualModule returns a new Module which have two public method `#hi` and `#hello`. Since `vm `object is a instance of Module class, you can simply include `vm` object and call `#hello` method in this case.

```
require 'virtual_module'
vm = VirtualModule.new(<<EOS)
def hi
  "ho"
end

def hello(num)
  num*num
end
EOS
p vm.hi # "ho"
include vm
p hello(33) # 1089
```

What VirtualModule do at the code above is something like below:

 - Transpile `#def` and `#hello` methods into Julia code, using [julializer] rubygem.
 - Boot the transpiled code and pass the parameters via msgpack-ruby and MsgPack.jl
 - Run #hi or #hello function call on the Julia VM
 - Pass returend value back to ruby via msgpack-ruby and MsgPack.jl

Another important api I'm introducing is `virtual_module_eval`. With this method, you can bind your local variable to Julia. Yey!

```
vm = VirtualModule.new(<<EOS)
def hey(x,y)
  y[2] += x
end
a = 2016
b = [99, "foobar", 3.1415]
vm.virtual_module_eval(a,b)
puts b # 2019.1415
```

## Requirement

- Mac OSX, Linux and Ruby(MRI) 2.1 and higher are supported.
- Julia or Docker inslalled on your machine is a must.

## Installation

Simply run following command.

```
$ gem install virtual_module
$ julia -e 'Pkg.add("MsgPack"); Pkg.add("MsgPackRpcServer")'
```

If you don't have Julia installed in your machine, just install julia is highly recommended.

## Features

Following features are implemented already:

- File-based IPC using [msgpack-ruby](https://github.com/msgpack/msgpack-ruby) and [MsgPack.jl](https://github.com/kmsquire/MsgPack.jl/)
- RPC-based IPC using [msgpack-ruby](https://github.com/msgpack/msgpack-ruby) and [MsgPackRpcServer.jl](https://github.com/remore/MsgPackRpcServer.jl)

And here is a listed of features to be implemented in the future(if needed/requested):

- Improve julializer(transpiler) much better
- Other programming language support such as golang, ruby itself etc.

## License

MIT
