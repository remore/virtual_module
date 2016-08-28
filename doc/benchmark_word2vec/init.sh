#!/bin/bash

cd $(cd $(dirname $0); pwd)

# prepare folders word2vec.c
mkdir output
mkdir training_data

# download training data
cd training_data
wget http://mattmahoney.net/dc/text8.zip
unzip text8.zip
head -c 1000 text8 > tiny.txt
head -c 100000 text8 > small.txt
head -c 5000000 text8 > medium.txt
head -c 100000000 text8 > large.txt
head -c 1000 text8 > 1k.txt
head -c 10000 text8 > 10k.txt
head -c 100000 text8 > 100k.txt
head -c 1000000 text8 > 1m.txt
head -c 10000000 text8 > 10m.txt
head -c 100000000 text8 > 100m.txt

# download word2vec.c
# originally coming from https://code.google.com/archive/p/word2vec/ or https://github.com/dav/word2vec
cd ..
wget https://storage.googleapis.com/google-code-archive-source/v2/code.google.com/word2vec/source-archive.zip
unzip source-archive.zip
mv word2vec word2vec_original_source_repo
cp word2vec_original_source_repo/trunk/word2vec.c ./word2vec.c
