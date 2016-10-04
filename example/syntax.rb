require '../lib/virtual_module'
jl = VirtualModule.new(:julia=>["Clustering"])
a = 1234
jl.virtual_module_eval("a=a*2")
p a
p jl.zeros(2)
p jl.zeros
p jl.collect(jl.zeros(2,2))
# p vm.zeros(nil)
# これだとzeros(nothing)と等価になってしまいconvertエラー。
# しかし、MsgPackの仕様的にnil->nothing変換されるのでどうしようもない感。。

# make a random dataset with 1000 points
# each point is a 5-dimensional vector
x = jl.rand(5, 1000)
# performs K-means over X, trying to group them into 20 clusters
# set maximum number of iterations to 200
# set display to :iter, so it shows progressive info at each iteration
r = jl.Clustering.kmeans(x, 20, maxiter:200, display: :iter)
p jl.Clustering.assignments(r)

py = VirtualModule.new(:methods=><<EOS, :pkgs=>["datetime"], :lang=>:python)
def hello():
  return "hi from vm_python";

def hello2(a):
  return a*234;

EOS
p py.datetime.datetime.now(:_).year
p py.hello(:_)
p py.datetime
p py.hello2(999)
a = 123
py.virtual_module_eval("a = hello2(7); a=a-123")
p a

#p py.datetime.now(nil)
#p py.year # ERROR
hoge = py.datetime.datetime.now(nil)
p hoge
p hoge.year # 2016

py = VirtualModule.new(:python=>["gensim"])
model = py.gensim.models.Word2Vec.load_word2vec_format('~/Dropbox/Public/word2vec_performance_test/tmp/1474473448_20_9_5_1e-3_0_2_original_medium.txt')
p model.most_similar("japan")
