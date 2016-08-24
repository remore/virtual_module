require '../lib/virtual_module'
require 'benchmark'

ruby_source = <<EOS
def sample_loop(n)
  for i in 1..1e8
    n = i+n
  end
  n
end

EOS
File.write("./perf.rb", ruby_source + "p sample_loop(2.5)")

File.write("./perf.py", <<EOS)
def sample_loop(n):
        for i in range(1,int(1e8)+1):
                n=i+n;
        return n

print(sample_loop(2.5))
EOS

File.write("./perf.jl", <<EOS)
function sample_loop(n)
  for i in 1:1e8
    n = i+n
  end
  n
end
println(sample_loop(2.5))
EOS

Benchmark.bm 3 do |r|
  r.report "Ruby" do
    p `rbenv local 2.3.0 & ruby ./perf.rb`
  end
  r.report "JRuby" do
    p `rbenv local jruby-9.1.2.0 & ruby ./perf.rb`
  end
  r.report "Python" do
    p `python ./perf.py`
  end
  r.report "Cython" do
    p `cython ./perf.py`
  end
  r.report "Julia" do
    p `julia ./perf.jl`
  end
  r.report "VirtualModule(Julia Inside)" do
    vm = VirtualModule.new(ruby_source)
    p vm.sample_loop 2.5
  end
end
