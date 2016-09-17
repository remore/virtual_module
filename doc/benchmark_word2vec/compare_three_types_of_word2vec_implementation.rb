require '../../lib/virtual_module'
require 'benchmark'
require 'enumerable/statistics'

size_of_document = ARGV[0] || "small"
number_of_trials = ARGV[1].to_i || 5
puts "staring benchmark...(size_of_document=#{size_of_document}, number_of_trials=#{number_of_trials})\n"
`gcc word2vec.c -o word2vec -lm -pthread -O3 -march=native -Wall -funroll-loops -Wno-unused-result`

w2v_config = {
  :timestamp => Time.now.to_s.gsub(/[:-]/, "").gsub(/ /, "_"),
  :train => "#{File.dirname(__FILE__)}/training_data/#{size_of_document}.txt",
  :size => 20,
  :window => 10,
  :negative => 4,
  :sample => "1e-4",
  :binary => 1,
  :iter => 3,
  :debug => 0
}
config_string = ->(hyphen){
  w2v_config.select{|k,v|k!=:timestamp}.map{|k,v| "#{hyphen}#{k} #{v}" }.join(" ")
}
filename = ->(impl){
  prefix = w2v_config.select{|k,v| k!=:train}.values.join("_")
  ext = w2v_config[:binary]==0 ? "txt" : "bin"
  "#{File.dirname(__FILE__)}/output/#{prefix}_#{impl}_#{size_of_document}.#{ext}"
}

score = {}
number_of_trials.times do |i|
  puts "next trial: #{i+1}/#{number_of_trials}"
  Benchmark.bm 10 do |r|
    r.report "word2vec.c" do
      p "./word2vec -cbow 1 -hs 0 -threads 1 -output #{filename.call("original")} #{config_string.call("-")}"
      `./word2vec -cbow 1 -hs 0 -threads 1 -output #{filename.call("original")} #{config_string.call("-")}`
    end
    r.report "word2vec.rb with vm" do
      p "ruby -r virtual_module ../../example/word2vec.rb --output #{filename.call("vm")} #{config_string.call("--")}"
      `ruby -r virtual_module ../../example/word2vec.rb --output #{filename.call('"vm"')} #{config_string.call("--")}`
    end
    r.report "word2vec.rb" do
      p "ruby ../../example/word2vec.rb --output #{filename.call("ruby")} #{config_string.call("--")}"
      `ruby ../../example/word2vec.rb --output #{filename.call("ruby")} #{config_string.call("--")}`
    end
  end.each do |e|
    score[e.label] = [] if score[e.label].nil?
    score[e.label] << e.total
  end
end

puts "\nbenchmark process has been finished(size_of_document=#{size_of_document}, number_of_trials=#{number_of_trials}):\n"
printf "%s\n%s\n", score.map{|label, time| label}.join("\t"), score.map{|label, time| time.mean}.join("\t")
