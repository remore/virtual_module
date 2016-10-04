require '../lib/virtual_module'
py = VirtualModule.new(:python=>["scipy"=>["matrix", "linalg", "integrate"]])
include py
a = matrix([[1, 1], [2, 4]])
b = matrix([[10],[26]])
p linalg.solve(a,b).tolist(:_) # [[7.0], [3.0]]
# p linalg.solve(a,b).to_a # #<Module:0x007fc3c9114a60>
foo = 2.54
py.virtual_module_eval("foo=foo*foo") # this works by accident - since Ripper can parse this into AST.
p foo # 6.4516

np = VirtualModule.new(:lang=>:python, :pkgs=>["numpy"])
arr = np.numpy.array([[1, 2],[3, 4]])
p linalg.det(arr) # -2.0

# a sample sklearn usage, ported from following code
# http://qiita.com/hikobotch/items/493ae5c889a7c98cda11
skl = VirtualModule.new(:lang=>:python, :pkgs=>["sklearn"=>["datasets", "svm", "grid_search", "cross_validation"]])
include skl
iris = datasets.load_iris(:_)
clf = grid_search.GridSearchCV(svm.LinearSVC(:_), {'C':[1, 3, 5],'loss':['hinge', 'squared_hinge']}, verbose:0)
clf.fit(iris.data, iris.target)
p "Best Parameters:", best_params = clf.best_params_
score = cross_validation.cross_val_score(svm.LinearSVC(loss:'squared_hinge', C:1), iris.data, iris.target, cv:5)
p "Scores: #{[:mean,:min,:max,:std].map{|e| e.to_s + '=' + score.send(e, :_).to_s }.join(',')}"

# a sample svm usage, ported from following code
# http://sucrose.hatenablog.com/entry/2013/05/25/133021
digits = datasets.load_digits(2)
#data_train, data_test, label_train, label_test = cross_validation.train_test_split(digits.data, digits.target)
tmparray = cross_validation.train_test_split(digits.data, digits.target)
data_train = tmparray[0]
data_test = tmparray[1]
label_train = tmparray[2]
label_test = tmparray[3]
estimator = svm.LinearSVC(C:1.0)
estimator.fit(data_train, label_train)
label_predict = estimator.predict(data_test)
p label_predict.to_a
