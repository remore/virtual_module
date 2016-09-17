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
      props = {:lang=>:julia, :pkgs=>[]}.merge(config)
      vm_builder = instance_eval("#{props[:lang].to_s.capitalize}Builder").new(props)
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

  class BaseBuilder
    include SexpParser

    def initialize(config={})
      props = {:ipc=>:file, :work_dir=>nil, :pkgs=>[], :source=>[]}
      props.each do |k,v|
        instance_variable_set("@#{k}", config[k] || v)
      end
      @ipc = instance_eval("#{@ipc.to_s.capitalize}IpcInterface").new(props.merge(config))
    end

    def add(methods="")
      @source << methods
      @ipc.reset get_compiled_code
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
      extract_defs(Ripper.sexp(@source.join(";"))).split(",").each{|e|
        @vm.class_eval {
          define_method e.to_sym, Proc.new { |*args|
            vm_builder.call(e.to_sym, *args)
          }
        }
      }
      @vm
    end

    def call(name, *args)
      @work_dir = @ipc.work_dir
      begin
        @ipc.call(name, *args)
      rescue StandardError => e
        @ipc.serialized = e.message
        @vm
      end
    end

    private
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

  class JRubyBuilder < BaseBuilder

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
    ___evaluated = (#{Julializer.ruby2julia(script)})

    #{vars.map{|e| 'params["'+e.to_s+'"]='+e.to_s }.join(";") if auto_binding}

    (___evaluated,#{auto_binding ? "params" : "-1" })
  end
EOS

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
        File.read(
          File.dirname(__FILE__)+"/virtual_module/bridge.jl") + ";" +
          Julializer.ruby2julia(@source.join(";\n")
        )
      end

  end

  class BaseIpcInterface
    LIB_SCRIPT = "vm-lib"

    attr_accessor :work_dir
    attr_accessor :serialized

    def initialize(config={})
      @work_dir = Dir.mktmpdir(nil, Dir.home)
      at_exit{ FileUtils.remove_entry_secure @work_dir }
    end
    def call(name, *args)
      #do nothing
    end
    def reset(source)
      #do nothing
    end
  end

  class FileIpcInterface < BaseIpcInterface
    INPUT = "vm-input"
    OUTPUT = "vm-output"
    MAIN_LOOP = "vm-main"

    def initialize(config={})
      super
      File.mkfifo("#{@work_dir}/#{INPUT}")
      File.mkfifo("#{@work_dir}/#{OUTPUT}")
      at_exit { Proc.new{Process.kill(:TERM, @pid) if !@pid.nil?} }
    end

    def call(name, *args)
      #require 'byebug'
      #byebug
      if Helper.is_installed?(:julia)
        File.write("#{@work_dir}/#{INPUT}", generate_entrypoint(@work_dir, "#{@work_dir}/#{OUTPUT}", name, *args))
      elsif Helper.is_installed?(:docker)
        File.write("#{@work_dir}/#{INPUT}", generate_entrypoint("/opt/", "/opt/#{OUTPUT}", name, *args))
      else
        raise Exception.new("Either julia or docker command is required to run virtual_module")
      end
      #byebug
      response = File.open("#{@work_dir}/#{OUTPUT}", 'r'){|f| f.read}
      begin
        MessagePack.unpack(response)
      rescue
        raise StandardError.new(response)
      end
    end

    def reset(source)
      @lib_source = source
      restart_server_process
    end

    private
      def restart_server_process
        Process.kill(:KILL, @pid) if !@pid.nil?
        File.write("#{@work_dir}/#{LIB_SCRIPT}", @lib_source)
        File.write("#{@work_dir}/#{MAIN_LOOP}", <<EOS)
using MsgPack
while true
  source = open( "#{@work_dir}/#{INPUT}", "r" ) do fp
    readall(fp)
  end
  result = eval(parse(source))
  open( "#{@work_dir}/#{OUTPUT}", "w" ) do fp
    try
      write(fp,pack(result))
    catch
      serialize(fp,result)
    end
  end
end
EOS

        if Helper.is_installed?(:julia)
          command = "julia --depwarn=no -L #{@work_dir}/#{LIB_SCRIPT} #{@work_dir}/#{MAIN_LOOP}"
        elsif Helper.is_installed?(:docker)
          command = "docker run -v #{@work_dir}/:/opt/ remore/virtual_module julia --depwarn=no -L /opt/#{LIB_SCRIPT} /opt/#{MAIN_LOOP}"
        else
          raise Exception.new("Either julia or docker command is required to run virtual_module")
        end
        @pid = Process.spawn(command, :err => :out,:out => "/dev/null")
      end

      def generate_entrypoint(basedir, target, name, *args)
        script = ""
        params = []
        args.each_with_index do |arg, i|
          type = arg.class == Module ? "serialized" : "msgpack"
          File.write("#{basedir}/#{INPUT}.#{i}.#{type}", arg.class == Module ? arg.___get_serialized___ : MessagePack.pack(arg))
          params << "params_#{i}"
          val = arg.class == Module ? "deserialize(fp)" : "unpack(readall(fp))"
          script += "#{params.last} =open( \"#{basedir}/#{INPUT}.#{i}.#{type}\", \"r\" ) do fp; #{val}; end;"
        end
        script += "#{name}(#{params.join(',')});"
        #script + "open( \"#{target}\", \"w\" ) do fp; write( fp, try pack(result) catch; serialize(fp,result) end ); end"
      end
  end

  class RpcIpcInterface < BaseIpcInterface
    def initialize(config={})
      super
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
        at_exit do
          Proc.new do
            @client.close if !@client.nil?
            Process.kill(:TERM, @pid) if !@pid.nil?
          end
        end
      end

      def restart_server_process(source)
        Process.kill(:KILL, @pid) if !@pid.nil?
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
  end

  module Helper
    class << self
      def is_installed?(command)
        Open3.capture3("which #{command.to_s}")[0].size > 0
      end
    end
  end

end
