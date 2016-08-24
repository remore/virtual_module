MAX_EXP = 6
EXP_TABLE_SIZE = 1000
MAX_SENTENCE_LENGTH = 1000

def init_unigram_table(table_size, vocab)
  train_words_pow = 0.0
  power = 0.75
  table = Array.new(table_size, 0)
  for a in 0..vocab.size-1
    train_words_pow+=vocab[a][0]**power
  end
  i=0
  d1 = (vocab[i][0]**power) / train_words_pow
  for a in 0..table_size-1
    table[a] = i
    if a / table_size.to_f > d1
      i+=1
      d1+=(vocab[i][0]**power) / train_words_pow
    end
    i = vocab.size - 1 if i >= vocab.size
  end
  return table
end

#syn0=addop(layer1_size, syn0, last_word*layer1_size, neu1e)
def addop(size, list, base, target)
  for i in 0..size-1
    list[i+base]+=target[i]
println "syn0:list[#{i+base}]=#{list[i+base]}, "
  end
println "\n"
  list
end

def addop2(size, list, base, coefficient, target, base2)
  for i in 0..size-1
println "addop2-before:list[#{i+base}]=#{list[i+base]}, "
    list[i+base]+=coefficient*target[i+base2]
println "addop2-after:list[#{i+base}]=#{list[i+base]}, "
  end
println "\n"
  list
end

def addop3(size, f, coefficient, target, base)
#puts "size=#{size}"
#puts "f=#{f}"
#puts "target.size=#{target.length}"
#puts "base=#{base}"
  for i in 0..size-1
    f+=coefficient[i]*target[i+base]
  end
  f
end

def addop4(size, list, target, base)
  for i in 0..size-1
    list[i]+=target[i+base];
  end
  list
end

$myrandom = 0
def next_random
  #$myrandom = ($myrandom * 25214903917 + 11) & 0xffffffff # 0xffffffffffffffff は遅いので使わない
  $myrandom = $myrandom + 3
  return $myrandom
end

# @param [Fixnum] num
def exptable(num)
  num = Math.exp((num / EXP_TABLE_SIZE.to_f * 2 - 1) * MAX_EXP)
  num / (num + 1)
end

# @param [FloatArray] list
# @param [Fixnum] target
def bsearch_index(list, target)
  a=0
  z=list.size-1
  while(true) do
    current_entry = list[a..z][((z-a)/2).floor]
    if current_entry < target then
      next_entry = list[a..z][((z-a)/2+1).floor]
      # CAUTION!!:: nilやnil?は禁止
      if (next_entry>=target) || z-a<=1 then
        return (a + (z-a)/2+1).round
      else
        a = (a + (z-a)/2).round
      end
    else
      return a if a >= target || z-a<=1
      z = (z - (z-a)/2).round
    end
  end
end

def calc_vec(iter, original_text, sample, train_words, debug_mode, __vocab_index_hash, vocab, syn0, syn1neg, negative, alpha, __cum_table, table_size, layer1_size, window)
  #layer1_size = 8
  #window = 9
  sentence_position = 0
  sentence_length = 0
  word_count = 0
  word_count_actual = 0
  last_word_count = 0
  sen = []
  local_iter = iter
  neu1 = []
  neu1e = []
  backup = original_text.dup
  __denominator = (EXP_TABLE_SIZE/MAX_EXP/2).to_i # CAUTION!!:: VirtualModule用にこの.to_iを追加。これをしないと、Juliaでは83.3333333...が__denominatorになってしまう。Rubyではここは83。 !!WARNING!!! むしろこれは誤った修正かも？Rubyだから83にfloorされてしまうが、そもそもCではそのような切り上げは処理が実装されていない！！！！！
  __sample_train_words = sample*train_words
  table_size = 1e8.to_i
  table = init_unigram_table(table_size, vocab)
  starting_alpha = alpha
  while true do
  puts "%d %d / " % [word_count, last_word_count] if sentence_position % 500 == 0 && debug_mode > 1
    if word_count - last_word_count > 10000 then
      word_count_actual += word_count - last_word_count
      last_word_count = word_count
      print "\r Alpha: #{'%f' % alpha}  Progress: #{'%.2f' % (word_count_actual / (iter*train_words+1).to_f * 100) }%" if debug_mode > 1
      alpha = starting_alpha * (1 - word_count_actual / (iter * train_words + 1).to_f)
      alpha = starting_alpha * 0.0001 if alpha < starting_alpha * 0.0001
    end
    if sentence_length == 0 then
  #puts "currently=%d" % original_text.size if debug_mode > 1
  println "currently=%d" % original_text.size
      skipped=0
      sen=[]
      original_text.each do |e|
        # CAUTION!!:: nilやnil?は禁止
        #word = __vocab_index_hash[e]
        #if word.nil? then
        if __vocab_index_hash.key?(e) then
          # CAUTION!!:: Hashアクセスの際は[e]ではなく["#{e}"]のように式展開をする（さもなくばArrayへのアクセスとみなされる）
          word = __vocab_index_hash["#{e}"]
        else
          println "skipped:#{e}"
          skipped+=1
          next
        end
        word_count += 1
        println "sentence_length=#{sentence_length}, e=#{e}, word=#{word}, word_count=#{word_count}"
        break if word == 0
        if sample > 0 then
          ran = (Math.sqrt(vocab[word][0] / __sample_train_words) + 1) * __sample_train_words / vocab[word][0]
          next if ran < (next_random() & 0xFFFF) / 65536.0
        end
        #sen[sentence_length] = word
        sen << word # sen.push! や sen[sentence_length] は文法上NG
        sentence_length += 1
        break if sentence_length >= MAX_SENTENCE_LENGTH
      end
      if MAX_SENTENCE_LENGTH+skipped <= original_text.length-1
        original_text.slice!(0, MAX_SENTENCE_LENGTH+skipped)
      else
        original_text = []
      end
      sentence_position = 0
    end
#puts "size=#{original_text.length}"
    if original_text.size==0 || word_count > train_words then
      word_count_actual += word_count - last_word_count
      local_iter -= 1
  puts local_iter if debug_mode > 1
      break if local_iter == 0
      word_count = 0
      last_word_count = 0
      sentence_length = 0
      original_text = backup.dup
      sen = []
      next
    end
    # CAUTION!!:: nilやnil?は禁止
    #word = sen[sentence_position]
    #next if word.nil?
    next if sentence_position >= sen.size
    word = sen[sentence_position]
    neu1 = Array.new(layer1_size, 0.0)
    println "@@@@@@@@@@@CHECK after!!=#{neu1[1]}"
    neu1e = Array.new(layer1_size, 0.0)
    b = next_random() % window
    cw = 0
    for j in b..window*2-b do
      if j!=window then
        k = sentence_position - window+j
        next if k < 0 || k >= sentence_length
        # CAUTION!!:: nilやnil?は禁止
        #last_word = sen[k]
        #next if last_word.nil?
        next if k >= sen.size
        last_word = sen[k]
        neu1=addop4(layer1_size, neu1, syn0, last_word*layer1_size)
        #for k in 0..layer1_size-1 do
        #  neu1[k] += syn0[k+last_word*layer1_size]
        #end
        cw += 1
      end
    end
    if cw!=0 then
      for j in 0..layer1_size-1 do neu1[j] /= cw end
      # NEGATIVE SAMPLING
      if negative > 0 then
        for j in 0..negative do
          if j==0 then
            target = word
            label = 1
          else
            # 8/11: 以下のコマンドで#bsearch_index使ったらboundary errorで途中でaddop3がエラー。そこでUnigramを使う方式に切り替えた。
            # ruby example/word2vec.rb --train ~/Dropbox/Public/word2vec/doc/medium.txt --out ./a.out && cat a.out
            #target = bsearch_index(__cum_table, Random.rand(0..table_size-1))
            nr = next_random()
            target = table[(nr>>16)%table_size]
            target = nr % (vocab.size-1) +1 if target==0
            next if target==word
            label = 0
          end
          l2 = target * layer1_size # 8/10 bug - l2がlength(syn1neg)を超えたサイズでやってくる。。このためaddop3()内でboundaryエラー。）
          println "target=#{target}, word=#{word}, l2=#{l2} "
          f = 0.0
          f=addop3(layer1_size, f, neu1, syn1neg, l2)
          #for c in 0..layer1_size-1 do
          #  f += neu1[c] * syn1neg[c+l2]
          #end
          if f > MAX_EXP then
            g = (label-1) * alpha
          elsif f < -MAX_EXP then
            g = label * alpha
          else
            println "[__denominator]=#{__denominator}, [middle]=#{(f+MAX_EXP)*__denominator}, [to_i]=#{((f+MAX_EXP)*__denominator).to_i}, [middle2]=#{exptable(((f+MAX_EXP)*__denominator).to_i)}, [final]=#{(label - exptable(((f+MAX_EXP)*__denominator).to_i))},  [g]=#{(label - exptable(((f+MAX_EXP)*__denominator).to_i)) * alpha}"
            g = (label - exptable(((f+MAX_EXP)*__denominator).to_i)) * alpha
          end
          #puts "sentence_position=#{sentence_position}, word=#{word} #{vocab[word][1]}, target=#{target} #{vocab[target][1]}, label=#{label}, f=#{f}, g=#{g}" if debug_mode > 1
          println "sentence_position=#{sentence_position}, word=#{word} #{vocab[word][1]}, target=#{target} #{vocab[target][1]}, label=#{label}, f=#{f}, g=#{g}"
          ##def addop2(size, list, base, coefficient, target, base2)
          neu1e=addop2(layer1_size, neu1e, 0, g, syn1neg, l2)
          #for c in 0..layer1_size-1 do
          #  neu1e[c] += g*syn1neg[c+l2]
          #  puts "neu1e[#{c}]=#{neu1e[c]}" if debug_mode > 1
          #end
          ##def addop2(size, list, base, coefficient, target, base2)
          syn1neg=addop2(layer1_size, syn1neg, l2, g, neu1, 0)
          #for c in 0..layer1_size-1 do
          #  syn1neg[c+l2] += g*neu1[c]
            #puts "syn1neg[#{syn1neg_index}]=#{syn1neg[syn1neg_index]}" if debug_mode > 1
          #end
        end
      end
      for j in b..window*2-b do
        if j != window then
          c = sentence_position - window + j
          next if c < 0 || c >= sentence_length
          # CAUTION!!:: nilやnil?は禁止
          #last_word = sen[c]
          #next if last_word.nil?
          next if c >= sen.size
          last_word = sen[c]
          #for k in 0..layer1_size-1 do
          #  syn0[k+last_word*layer1_size] += neu1e[k]
          #end
          syn0=addop(layer1_size, syn0, last_word*layer1_size, neu1e)
        end
      end
    end
#puts "<#{sentence_position}>"
#break if sentence_position > 10
    sentence_position += 1
    sentence_length = 0 if sentence_position >= sentence_length
    #break if sentence_position > 50
  end
  [syn0, syn1neg]
end
