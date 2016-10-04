#!/bin/bash
ruby simple.rb
ruby syntax.rb
ruby scipy.rb
ruby doc2vec.rb
ruby -r ../lib/virtual_module word2vec.rb --output testoutput.bin --train ../doc/benchmark_word2vec/training_data/tiny.txt --size 20 --window 10 --negative 4 --sample 1e-4 --binary 1 --iter 3 --debug 0
