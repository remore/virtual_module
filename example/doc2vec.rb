require 'natto'

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
p model.docvecs.most_similar(["ps"]) # [["top", 0.5594387054443359], ["cat", 0.46929454803466797], ["df", 0.3900265693664551], ["mkdir", 0.38811227679252625], ["du", 0.23663029074668884], ["ls", 0.15436093509197235], ["cd", -0.1965409815311432], ["touch", -0.38958919048309326]]
