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
    def new(methods, config={})
      if !config.is_a?(BaseBuilder)
        config[:lang] = :julia if config[:lang].nil?
        vm_builder = instance_eval("#{config[:lang].to_s.capitalize}Builder").new(config)
      else
        vm_builder = config
      end
      vm_builder.add(methods)
      vm_builder.build
    end
  end

  class BaseBuilder
    def initialize(config={})
      @source = []
      if !config.is_a?(BaseIpcInterface)
        props = {:ipc=>:file, :work_dir=>nil}
        props.each do |k,v|
          instance_variable_set("@#{k}", config[k] || v)
        end
        @ipc = instance_eval("#{@ipc.to_s.capitalize}IpcInterface").new(props.merge(config))
      else
        @ipc = config
      end
    end

    def add(methods)
      @source << methods
      @ipc.reset get_compiled_code
    end

    def build
      vm_builder = self
      ipc = @ipc
      vm = Module.new{
        @vm_builder = vm_builder
        @ipc = ipc
        def self.virtual_module_eval(*args)
          @vm_builder.send(:virtual_module_eval, *args)
        end
        def self.method_missing(key, *args, &block)
          @vm_builder.send(:call, key, *args)
        end
      }
      extract_defs(Ripper.sexp(@source.join(";"))).split(",").each{|e|
        vm.class_eval {
          define_method e.to_sym, Proc.new { |*args|
            vm_builder.call(e.to_sym, *args)
          }
        }
      }
      vm
    end

    def call(name, *args)
      Dir.mktmpdir(nil, Dir.home) do |tempdir|
        @work_dir = @ipc.work_dir = tempdir
        @ipc.call(name, *args)
      end
    end

    private
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

      def inspect_local_vars(context, script)
        vars = extract_args(Ripper.sexp(script)).split(",").uniq.map{|e| e.to_sym} & context.eval("local_variables")
        #p "vars=#{vars}"

        type_info = {}
        type_info[:params] = context.eval("Hash[ *#{vars}.collect { |e| [ e, eval(e.to_s).class.to_s ] }.flatten ]").select{|k,v| ["FloatArray", "IntArray"].include?(v)}
        #p "type_info=#{type_info}"

        params = context.eval(<<EOS)
require 'msgpack'
___params = {}
___params = local_variables.map{|e| [e, eval(e.to_s)]}.each{|e| ___params[e[0]]=e[1] if #{vars}.include?(e[0])}[0][1]
___params
EOS
        #File.write("#{@work_dir}.polykit.params", params)
        [vars, type_info, params]
      end
  end


  class JuliaBuilder < BaseBuilder
    def virtual_module_eval(script, auto_binding=true)
      vars, type_info, params = inspect_local_vars(binding.of_caller(2), script)
      boot_script = <<EOS
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
    ___evaluated = #{Julializer.ruby2julia(script)}

    #{vars.map{|e| 'params["'+e.to_s+'"]='+e.to_s }.join(";") if auto_binding}

    (___evaluated,#{auto_binding ? "params" : "-1" })
  end
EOS

#      File.write("#{@work_dir}.polykit.rb", <<EOS)
#  require 'msgpack-rpc'
#  client = MessagePack::RPC::Client.new('127.0.0.1', #{@port})
#  client.timeout = #{@timeout}
#  p client.call(:___main, #{params}, #{type_info})
#EOS

      @ipc.reset get_compiled_code + ";#{boot_script}"
      evaluated = self.call(:___main, params, type_info)
      if auto_binding
        binding.of_caller(2).eval(evaluated[1].map{|k,v| "#{k}=#{v};" if !v.nil? }.join)
      end

      return evaluated[0]
    end

    alias_method :virtual_instance_eval, :virtual_module_eval
    alias_method :virtual_eval, :virtual_module_eval

    private
      def get_compiled_code
        File.read(File.dirname(__FILE__)+"/virtual_module/bridge.jl") + ";" + Julializer.ruby2julia(@source.join(";\n"))
      end

  end

  class BaseIpcInterface
    INPUT_ARGS = "virtualmodule-input.msgpack"
    OUTPUT_ARGS = "virtualmodule-output.msgpack"
    ENTRYPOINT_SCRIPT = "virtualmodule-entrypoint.jl"
    LIB_SCRIPT = "virtualmodule-lib.jl"

    attr_accessor :work_dir

    def initialize(config)
      #do nothing
    end
    def call(name, *args)
      #do nothing
    end
    def reset(source)
      #do nothing
    end
  end

  class FileIpcInterface < BaseIpcInterface
    def call(name, *args)
      File.write("#{@work_dir}/#{LIB_SCRIPT}", @lib_source)
      File.write("#{@work_dir}/#{INPUT_ARGS}", MessagePack.pack(args))

      if is_installed?(:julia)
        File.write("#{@work_dir}/#{ENTRYPOINT_SCRIPT}", generate_entrypoint(@work_dir, "#{@work_dir}/#{OUTPUT_ARGS}", name, *args))
        command = "julia --depwarn=no -L #{@work_dir}/#{LIB_SCRIPT} #{@work_dir}/#{ENTRYPOINT_SCRIPT}"
      elsif is_installed?(:docker)
        File.write("#{@work_dir}/#{ENTRYPOINT_SCRIPT}", generate_entrypoint("/opt/", "/opt/#{OUTPUT_ARGS}", name, *args))
        command = "docker run -v #{@work_dir}/:/opt/ remore/virtual_module julia --depwarn=no -L /opt/virtualmodule-lib.jl /opt/virtualmodule-entrypoint.jl"
      else
        raise Exception.new("Either julia or docker command is required to run virtual_module")
      end
      out, err, status = Open3.capture3(command)
      #byebug
      # FIXME: Only For Debug
      # printf out, err
      MessagePack.unpack(File.read("#{@work_dir}/#{OUTPUT_ARGS}"))
    end

    def reset(source)
      @lib_source = source
    end

    private
      def is_installed?(command)
        Open3.capture3("which #{command.to_s}")[0].size > 0
      end

      def generate_entrypoint(basedir, target, name, *args)
        if args.count>0
          script =<<EOS
using MsgPack
params = open( "#{basedir}/#{INPUT_ARGS}", "r" ) do fp
  readall( fp )
end
result = #{name}(unpack(params)...)
EOS
        else
          script =<<EOS
using MsgPack
result = #{name}()
EOS
        end

        script + ";" + <<EOS
open( "#{target}", "w" ) do fp
  write( fp, pack(result) )
end
EOS
      end

  end

  class RpcIpcInterface < BaseIpcInterface
    def initialize(config={})
      init_connection
      props = {:server=>"127.0.0.1", :port=>8746, :timeout=>10}
      props.each do |k,v|
        instance_variable_set("@#{k}", config[k] || v)
      end
    end

    def call(name, *args)
      restart_server_process @lib_source
      while `echo exit | telnet #{@server} #{@port} 2>&1`.chomp[-5,5]!="host." do
        sleep(0.05)
      end
      @client = MessagePack::RPC::Client.new(@server, @port) if @client.nil?
      @client.timeout = @timeout
      args.count>0 ? @client.call(name, *args) : @client.call(name)
    end

    def reset(source)
      @lib_source = source
    end

    private
      def init_connection
        @pid = nil
        @client.close if !@client.nil?
        @client = nil
      end

      def restart_server_process(source)
        Process.kill(:TERM, @pid) if !@pid.nil?
        `lsof -wni tcp:#{@port} | cut -f 4 -d ' ' | sed -ne '2,$p' | xargs kill -9`
        init_connection
        compiled = <<EOS
import MsgPackRpcServer
module RemoteFunctions
#{source}
end
MsgPackRpcServer.run(#{@port}, RemoteFunctions)
EOS
        File.write("#{@work_dir}/#{LIB_SCRIPT}", compiled)
        @pid = Process.spawn("julia --depwarn=no #{@work_dir}/#{LIB_SCRIPT}")
      end

      at_exit do
        @client.close if !@client.nil?
        Process.kill(:TERM, @pid) if !@pid.nil?
      end
  end

end
