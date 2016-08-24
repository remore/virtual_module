require 'optparse'
require 'byebug'
require 'stackprof'

#StackProf.run(mode: :cpu, out: 'example/stackprof-cpu-myapp.dump') do

MAX_EXP = 6
EXP_TABLE_SIZE = 1000
MAX_SENTENCE_LENGTH = 1000
VocabWord = Struct.new(:cn, :point, :word, :code, :codelen)

class Util
  def initialize(seed=1)
    @next_random = seed
  end
  def next_random
    @next_random = (@next_random * 25214903917 + 11) & 0xffffffffffffffff
    return @next_random
  end
end

params = ARGV.getopts('h:','binary:0','sample:1e-3', 'size:5', 'iter:5', 'window:5', 'min_count:5', 'negative:5', 'debug:0', 'train:', 'output:')
abort "--train or --output is not specified" if params['train'].nil? || params['output'].nil?
neu1 = []
vocab = []
layer1_size = params['size'].to_i
train_words = 0
iter = params['iter'].to_i
debug_mode = params['debug'].to_i
window = params['window'].to_i
min_count = params['min_count'].to_i
syn0 = []
syn1 = []
syn1neg = []
negative = params['negative'].to_i
original_text = []
binary = params['binary'].to_i
cbow = 1
if cbow then
  alpha = 0.05
else
  alpha = 0.025
end
starting_alpha = alpha
sample = params['sample'].to_f
table_size=1e8
table = []
__cum_table = []

__vocab_index_hash = {}
File.open(params['train']){|f|
  while line = f.gets
    line.split(" ").each do |word|
      original_text.push word
      if __vocab_index_hash.key?(word) then
        vocab[__vocab_index_hash[word]].cn += 1
      else
        vocab.push VocabWord.new(1, 0, word, 0, 0)
        __vocab_index_hash[word] = vocab.size-1
      end
      printf "\r%dK" % original_text.size if debug_mode > 1
    end
  end
}
vocab.sort! {|a,b| b.cn <=> a.cn}
vocab.select! {|v| v.cn >= min_count}
train_words = vocab.inject(0) {|sum, v| sum + v.cn}
vocab.unshift VocabWord.new(1, 0, '</s>', 0, 0)
__vocab_index_hash = Hash[vocab.map.with_index {|v, i| [v.word,i]}.to_a]

if negative>0 then
  syn1neg = Array.new(vocab.size*layer1_size, 0.0)
  # InitUnigramTable
  # naive implementation is below, but as python do it easier https://github.com/piskvorky/gensim/blob/develop/gensim/models/word2vec.py#L282
  # we'll use cumulative-distribution table as well.
  power = 0.75
  train_words_pow = 0
  for a in 0..vocab.size-1 do
    train_words_pow += vocab[a].cn**power
  end
  table_size = 1e8
  #i = 0
  #d1 = vocab[i].cn**power / train_words_pow
  #for a in 0..table_size-1 do
  #  table[a] = i
  #  if a / table_size.to_f > d1 then
  #    i += 1
  #    d1 += vocab[i].cn ** power  / train_words_pow
  #  end
  #  i = vocab.size - 1 if i >= vocab.size
  #end
  cumulative = 0.0
  for a in 0..vocab.size-1 do
    cumulative += vocab[a].cn ** power  / train_words_pow
    __cum_table[a] = (cumulative*table_size).round
  end
end
util = Util.new(1)
syn0 = (0..vocab.size*layer1_size).map {|i| ((util.next_random & 0xFFFF).to_f / 65536 -0.5 ) / layer1_size }
puts "vocab.size=#{vocab.size}, layer1_size=#{layer1_size}, watashi-ha-#{syn0.size}"

#require "./calc.rb"
#include Calc
#calc_vec(iter, original_text, sample, train_words, debug_mode, __vocab_index_hash, vocab)
require File.dirname(__FILE__)+'/../lib/virtual_module.rb'
class FloatArray < Array
end
vocab = vocab.map{|e|
  e=[e.cn, e.word]
}
syn0 = FloatArray.new(syn0)
__cum_table = FloatArray.new(__cum_table)
syn1neg = FloatArray.new(syn1neg)

vm = VirtualModule.new(File.read(File.dirname(__FILE__)+"/calc.rb"))
p vm.virtual_module_eval("calc_vec(iter, original_text, sample, train_words, debug_mode, __vocab_index_hash, vocab, syn0, syn1neg, negative, alpha, __cum_table, table_size, layer1_size, window)")

out = sprintf("%d %d\n", vocab.size, layer1_size)
for a in 0..vocab.size-1 do
  out += sprintf("%s ", vocab[a][1])
  for b in 0.. layer1_size-1 do
    if binary==0 then
      out += sprintf("%f ", syn0[a*layer1_size + b])
    else
      out += [syn0[a*layer1_size + b]].pack("f*")
    end
  end
  out += sprintf("\n")
end
if binary==0 then
  File.write(params['output'], out)
else
  File.binwrite(params['output'], out)
end

#end

