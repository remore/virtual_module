lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'virtual_module/version'

Gem::Specification.new do |s|
  s.name          = "virtual_module"
  s.version       = VirtualModule::VERSION
  s.authors       = ["Kei Sawada(@remore)"]
  s.email         = ["k@swd.cc"]
  s.summary       = %q{Born to make your Ruby Code 3x faster. Hopefully.}
  s.description   = s.summary
  s.homepage      = "https://github.com/remore/virtual_module"
  s.license       = "MIT"
  s.required_ruby_version = '>= 1.9.1'

  s.files         = %w(README.md) + Dir.glob("{lib}/**/*", File::FNM_DOTMATCH).reject {|f| File.directory?(f) }
  #s.test_files    = s.files.grep(%r{^spec\/*.rb})
  s.require_paths = ["lib"]

  s.add_dependency "msgpack"
  s.add_dependency "msgpack-rpc"
  s.add_dependency "binding_of_caller"
  s.add_dependency "julializer"
end
