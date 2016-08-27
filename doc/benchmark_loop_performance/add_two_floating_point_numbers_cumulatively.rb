require '../../lib/virtual_module'
require 'benchmark'
require 'enumerable/statistics'

at_exit{ `rbenv local 2.3.0` }

order_of_computation = ARGV[0] || 1e8
number_of_trials = ARGV[1].to_i || 30
puts "staring benchmark...(order_of_computation=#{order_of_computation}, number_of_trials=#{number_of_trials})\n"

score = {}
Dir.mktmpdir do |tempdir|
  ruby_source = <<EOS
def sample_loop(n)
  for i in 1..#{order_of_computation}
    n = i+n
  end
  n
end

EOS
  File.write("#{tempdir}/perf.rb", ruby_source + "p sample_loop(2.5)")
  File.write("#{tempdir}/perf_with_vm.rb", "p VirtualModule.new(File.read('#{tempdir}/perf.rb')).sample_loop(2.5)")

  File.write("#{tempdir}/perf.py", <<EOS)
def sample_loop(n):
  for i in range(1,int(#{order_of_computation})+1):
    n=i+n;
  return n

print(sample_loop(2.5))
EOS

  File.write("#{tempdir}/perf.jl", <<EOS)
function sample_loop(n)
  for i in 1:#{order_of_computation}
    n = i+n
  end
  n
end
println(sample_loop(2.5))
EOS

  number_of_trials.times do |i|
    puts "next trial: #{i+1}/#{number_of_trials}"
    Benchmark.bm 10 do |r|
      `rbenv local 2.3.0`
      r.report "Ruby 2.3.0" do
        p `ruby #{tempdir}/perf.rb`
      end
      `rbenv local jruby-9.1.2.0`
      r.report "JRuby 9.1.2.0" do
        p `ruby #{tempdir}/perf.rb`
      end
      r.report "Python 2.7" do
        p `python #{tempdir}/perf.py`
      end
      r.report "Cython 0.24" do
        p `cython #{tempdir}/perf.py`
      end
      r.report "Julia 0.4.6" do
        p `julia #{tempdir}/perf.jl`
      end
      `rbenv local 2.3.0`
      r.report "virtual_module" do
        p `ruby -r virtual_module #{tempdir}/perf_with_vm.rb`
      end
    end.each do |e|
      score[e.label] = [] if score[e.label].nil?
      score[e.label] << e.total
    end
  end
end

puts "\nbenchmark process has been finished(order_of_computation=#{order_of_computation}, number_of_trials=#{number_of_trials}):\n"
printf "%s\n%s\n", score.map{|label, time| label}.join("\t"), score.map{|label, time| time.mean}.join("\t")
