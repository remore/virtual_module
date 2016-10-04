require 'natto'
require 'sanitize'

sentences={}
natto = Natto::MeCab.new
%w"ps ls cat cd top df du touch mkdir".each do |cmd|
  list = []
  natto.parse(`man #{cmd} | col -bx | cat`) do |n|
    list << n.surface
  end
  sentences[cmd] = list
end

require '../lib/virtual_module.rb'
py = VirtualModule.new(:methods=><<EOS, :python=>["gensim"])
class LabeledListSentence(object):
    def __init__(self, words_list, label_list):
        self.words_list = words_list
        self.label_list = label_list

    def __iter__(self):
        for i, words in enumerate(self.words_list):
            yield gensim.models.doc2vec.LabeledSentence(words, [self.label_list[i]])

EOS
model = py.gensim.models.doc2vec.Doc2Vec(py.LabeledListSentence(sentences.values, sentences.keys), min_count:0)
p model.docvecs.most_similar(["ps"])
