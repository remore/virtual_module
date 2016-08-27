#!/bin/bash

w2v () {
local timestamp=`date +%s`
local train=$1
local size="20"
local window="10"
local negative="5"
local sample="1e-4"
local binary="1"
local iter="3"
local debug="0"
local filename="${size}_${window}_${negative}_${sample}_${binary}_${iter}"
if [ $binary = "0" ]; then
  local ext="txt"
else
  local ext="bin"
fi

echo "Starting [$1] benchmarking..."
echo "benchmarking word2vec.c..."
time ./word2vec -train ./training_data/${train}.txt -output ./tmp/${timestamp}_${filename}_original_${train}.${ext} -cbow 1 -size ${size} -window ${window} -negative ${negative} -hs 0 -sample ${sample} -threads 1 -binary ${binary} -iter ${iter} -debug ${debug}
echo "benchmarking word2vec.rb with virtual_module..."
time ruby -r virutal_module ../../example/word2vec.rb --train ./training_data/${train}.txt --output ./tmp/${timestamp}_${filename}_vm_${train}.${ext} --size ${size} --window ${window} --negative ${negative} --sample ${sample} --binary ${binary} --iter ${iter} --debug ${debug}
echo "benchmarking word2vec.rb without virtual_module..."
time ruby ../../example/word2vec.rb --train ./training_data/${train}.txt --output ./tmp/${timestamp}_${filename}_vm_${train}.${ext} --size ${size} --window ${window} --negative ${negative} --sample ${sample} --binary ${binary} --iter ${iter} --debug ${debug}
}

gcc word2vec.c -o word2vec -lm -pthread -O3 -march=native -Wall -funroll-loops -Wno-unused-result
date
w2v "tiny"
w2v "small"
w2v "medium"
w2v "large"
