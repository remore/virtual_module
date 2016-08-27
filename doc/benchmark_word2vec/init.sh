#!/bin/bash

cd $(cd $(dirname $0); pwd)
mkdir training_data
cd training_data
wget http://mattmahoney.net/dc/text8.zip

echo "To complete initialization, please download word2vec.c manually from https://code.google.com/archive/p/word2vec/ or https://github.com/dav/word2vec"
