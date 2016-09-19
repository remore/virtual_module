require 'msgpack'
require 'msgpack-rpc'
require 'ripper'
require 'binding_of_caller'
require 'julializer'
require 'open3'
require 'tmpdir'

module VirtualModule
  require 'virtual_module/version'

  class << self
    def new(methods, **args)
      option = {:lang=>:julia, :pkgs=>[], :ipc=>:file}.merge(args)
      vm_builder = Builder.new(option[:lang], option[:pkgs], option[:ipc])
      vm_builder.add(methods)
      vm_builder.build
    end
  end

  module SexpParser
    def extract_defs(s)
      if s.instance_of?(Array) && s[0].instance_of?(Symbol) then
        if [:def].include?(s[0])
          "#{s[1][1]},"
        else
          s.map{|e| extract_defs(e)}.join
        end
      elsif s.instance_of?(Array) && s[0].instance_of?(Array) then
        s.map{|e| extract_defs(e)}.join
      end
    end

    def extract_args(s)
      if s.instance_of?(Array) && s[0].instance_of?(Symbol) then
        if [:vcall, :var_field].include?(s[0])
          "#{s[1][1]},"
        else
          s.map{|e| extract_args(e)}.join
        end
      elsif s.instance_of?(Array) && s[0].instance_of?(Array) then
        s.map{|e| extract_args(e)}.join
      end
    end
  end

  class Builder
    include SexpParser

    def initialize(lang=:julia, pkgs=[], ipc=:file)
      @provider = instance_eval("#{lang.capitalize}SourceProvider").new(pkgs)
      @ipc = instance_eval("#{ipc.to_s.capitalize}IpcInterface").new(@provider)
    end

    def add(methods="")
      @provider.source << methods
      @provider.compile
      @ipc.reset @provider
    end

    def build
      vm_builder = self
      ipc = @ipc
      @vm = Module.new{
        @vm_builder = vm_builder
        @ipc = ipc
        def self.virtual_module_eval(*args)
          @vm_builder.send(:virtual_module_eval, *args)
        end
        def self.method_missing(key, *args, &block)
          @vm_builder.send(:call, key, *args)
        end
        def self.___get_serialized___
          @ipc.serialized
        end
      }
      extract_defs(Ripper.sexp(@provider.source.join(";"))).split(",").each{|e|
        @vm.class_eval {
          define_method e.to_sym, Proc.new { |*args|
            vm_builder.call(e.to_sym, *args)
          }
        }
      }
      @vm
    end

    def call(name, *args)
      begin
        @ipc.call(name, *args)
      rescue StandardError => e
        @ipc.serialized = e.message
        @vm
      end
    end

    def virtual_module_eval(script, auto_binding=true)
      vars, type_info, params = inspect_local_vars(binding.of_caller(2), script)
      @provider.compile(vars, type_info, params, script, auto_binding)
      @ipc.reset @provider
      evaluated = self.call(:___main, params, type_info)
      if auto_binding
        binding.of_caller(2).eval(evaluated[1].map{|k,v| "#{k}=#{v};" if !v.nil? }.join)
      end

      return evaluated[0]
    end

    alias_method :virtual_instance_eval, :virtual_module_eval
    alias_method :virtual_eval, :virtual_module_eval

    private
      def inspect_local_vars(context, script)
        vars = extract_args(Ripper.sexp(script)).split(",").uniq.map{|e| e.to_sym} & context.eval("local_variables")

        type_info = {}
        type_info[:params] = context.eval("Hash[ *#{vars}.collect { |e| [ e, eval(e.to_s).class.to_s ] }.flatten ]").select{|k,v| ["FloatArray", "IntArray"].include?(v)}

        params = context.eval(<<EOS)
require 'msgpack'
___params = {}
___params = local_variables.map{|e| [e, eval(e.to_s)]}.each{|e| ___params[e[0]]=e[1] if #{vars}.include?(e[0])}[0][1]
___params
EOS
        [vars, type_info, params]
      end
  end

  class BaseSourceProvider
    attr_accessor :source
    def initialize(pkgs)
      @source = load_packages(pkgs)
      @compiled_lib = ""
    end

    def load_packages(pkgs)
      [] #to be overrieded
    end
  end

  class JuliaSourceProvider < BaseSourceProvider
    def load_packages(pkgs)
      pkgs.map{|e| "import #{e}"}
    end

    def main_loop(input_queue_path, output_queue_path)
      <<EOS
using MsgPack
while true
  source = open( "#{input_queue_path}", "r" ) do fp
    readall(fp)
  end
  result = eval(parse(source))
  open( "#{output_queue_path}", "w" ) do fp
    try
      write(fp,pack(result))
    catch
      serialize(fp,result)
    end
  end
end
EOS
    end

    def lib_script(ipc=nil)
      if ipc!=:rpc
        @compiled_lib
      else
        <<EOS
import MsgPackRpcServer
module RemoteFunctions
#{@compiled_lib}
end
MsgPackRpcServer.run(parse(ARGS[1]), RemoteFunctions)
EOS
      end
    end

    def compile(vars=nil, type_info=nil, params=nil, script=nil, auto_binding=nil)
      @compiled_lib = File.read(
        File.dirname(__FILE__)+"/virtual_module/bridge.jl") + ";" +
        Julializer.ruby2julia(@source.join(";\n")
      )
      if !vars.nil? && !type_info.nil? && !params.nil? && !script.nil? && !auto_binding.nil?
        @compiled_lib += <<EOS
  function ___convert_type(name, typename, params)
    if length(findin(#{type_info[:params].keys.map{|e| e.to_s}},[name]))>0
      if typename=="FloatArray"
        convert(Array{Float64,1}, params[name])
      elseif typename=="IntArray"
        convert(Array{Int64,1}, params[name])
      end
    else
      params[name]
    end
  end

  function ___main(params, type_info)
    #{vars.map{|e| e.to_s + '=___convert_type("'+e.to_s+'","'+(type_info[:params][e]||"")+'", params)'}.join(";")}
    ##{vars.map{|e| 'println("'+e.to_s+'=", typeof('+e.to_s+'))' }.join(";")}
    ___evaluated = (#{Julializer.ruby2julia(script)})

    #{vars.map{|e| 'params["'+e.to_s+'"]='+e.to_s }.join(";") if auto_binding}

    (___evaluated,#{auto_binding ? "params" : "-1" })
  end
EOS
      end
    end

    def generate_message(input_queue_path, name, *args)
      script = ""
      params = []
      args.each_with_index do |arg, i|
        type = arg.class == Module ? "serialized" : "msgpack"
        File.write("#{input_queue_path}.#{i}.#{type}", arg.class == Module ? arg.___get_serialized___ : MessagePack.pack(arg))
        params << "params_#{i}"
        val = arg.class == Module ? "deserialize(fp)" : "unpack(readall(fp))"
        script += "#{params.last} =open( \"#{input_queue_path}.#{i}.#{type}\", \"r\" ) do fp; #{val}; end;"
      end
      script += "#{name}(#{params.join(',')});"
    end

  end

  class BaseIpcInterface
    LIB_SCRIPT = "vm-lib"

    attr_accessor :work_dir
    attr_accessor :serialized

    def initialize(provider)
      @provider = provider
      @work_dir = Dir.mktmpdir(nil, Dir.home)
    end
    def call(name, *args)
      #do nothing
    end
    def reset(provider)
      @provider = provider
    end
  end

  class FileIpcInterface < BaseIpcInterface
    INPUT = "vm-input"
    OUTPUT = "vm-output"
    MAIN_LOOP = "vm-main"

    def initialize(provider)
      super
      File.mkfifo("#{@work_dir}/#{INPUT}")
      File.mkfifo("#{@work_dir}/#{OUTPUT}")
      at_exit do
        Process.kill(:INT, @pid) if !@pid.nil?
        FileUtils.remove_entry @work_dir if File.directory?(@work_dir)
      end
    end

    def call(name, *args)
      #require 'byebug'
      #byebug
      if Helper.is_installed?(:julia)
        enqueue @provider.generate_message("#{@work_dir}/#{INPUT}", name, *args)
      elsif Helper.is_installed?(:docker)
        enqueue @provider.generate_message("/opt/#{INPUT}", name, *args)
      else
        raise Exception.new("Either julia or docker command is required to run virtual_module")
      end
      #byebug
      response = dequeue
      begin
        MessagePack.unpack(response)
      rescue
        raise StandardError.new(response)
      end
    end

    def reset(source)
      super
      restart_server_process
    end

    private
      def restart_server_process
        Process.kill(:KILL, @pid) if !@pid.nil?
        File.write("#{@work_dir}/#{LIB_SCRIPT}", @provider.lib_script)
        File.write("#{@work_dir}/#{MAIN_LOOP}", @provider.main_loop("#{@work_dir}/#{INPUT}", "#{@work_dir}/#{OUTPUT}"))
        if Helper.is_installed?(:julia)
          command = "julia --depwarn=no -L #{@work_dir}/#{LIB_SCRIPT} #{@work_dir}/#{MAIN_LOOP}"
        elsif Helper.is_installed?(:docker)
          command = "docker run -v #{@work_dir}/:/opt/ remore/virtual_module julia --depwarn=no -L /opt/#{LIB_SCRIPT} /opt/#{MAIN_LOOP}"
        else
          raise Exception.new("Either julia or docker command is required to run virtual_module")
        end
        @pid = Process.spawn(command, :err => :out,:out => "/dev/null") # , :pgroup => Process.pid)
        Process.detach @pid
      end

      def enqueue(message)
        File.write("#{@work_dir}/#{INPUT}", message)
      end

      def dequeue
        File.open("#{@work_dir}/#{OUTPUT}", 'r'){|f| f.read}
      end
  end

  class RpcIpcInterface < BaseIpcInterface
    def initialize(provider)
      super
      init_connection
      @server = "127.0.0.1"
      @port = 8746
      @timeout = 10
    end

    def call(name, *args)
      restart_server_process
      while `echo exit | telnet #{@server} #{@port} 2>&1`.chomp[-5,5]!="host." do
        sleep(0.05)
      end
      @client = MessagePack::RPC::Client.new(@server, @port) if @client.nil?
      @client.timeout = @timeout
      args.count>0 ? @client.call(name, *args) : @client.call(name)
    end

    private
      def init_connection
        @pid = nil
        @client.close if !@client.nil?
        @client = nil
        at_exit do
          @client.close if !@client.nil?
          Process.kill(:INT, @pid) if !@pid.nil?
          FileUtils.remove_entry @work_dir if File.directory?(@work_dir)
        end
      end

      def restart_server_process
        Process.kill(:KILL, @pid) if !@pid.nil?
        `lsof -wni tcp:#{@port} | cut -f 4 -d ' ' | sed -ne '2,$p' | xargs kill -9`
        init_connection
        File.write("#{@work_dir}/#{LIB_SCRIPT}", @provider.lib_script(:rpc))
        @pid = Process.spawn("julia --depwarn=no #{@work_dir}/#{LIB_SCRIPT} #{@port}", :err => :out,:out => "/dev/null") #, :pgroup=>Process.pid)
        Process.detach @pid
      end
  end

  module Helper
    class << self
      def is_installed?(command)
        Open3.capture3("which #{command.to_s}")[0].size > 0
      end
    end
  end

end
