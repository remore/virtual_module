require 'virtual_module'
require 'benchmark'

File.write("./perf.rb", <<EOS)
def sample_loop(n)
  for i in 1..1e8; n=i+n; end
  n
end
EOS

File.write("./perf.py", <<EOS)
def sample_loop(n):
        for i in range(1,int(1e8)+1): n=i+n;
        return n
EOS

Benchmark.bm 10 do |r|
  r.report "Ruby2.3" do
    `ruby -r ./perf.rb -e "sample_loop(2.5)"`  # 5.000000050000003e+15
  end
  r.report "Python2.7" do
    `python -c "import perf; perf.sample_loop(2.5)"`  # 5.00000005e+15
  end
  r.report "VirtualModule" do
    include VirtualModule.new(File.read("./perf.rb"))
    sample_loop 2.5  # 5.000000050000003e+15
  end
end
