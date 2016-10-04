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
    def new(**args)
      format_args = ->(key){
        if args.keys.include?(key)
          args[:lang] = key
          args[:pkgs] = args[key]
          args[:transpiler] ||= nil if key == :python
        end
      }
      [:python, :julia].map{|e| format_args.call(e)}
      option = {:lang=>:julia, :methods=>"", :transpiler=>->(s){Julializer.ruby2julia(s)}, :pkgs=>[], :ipc=>:file}.merge(args)
      vm_builder = Builder.new(option)
      vm_builder.add(option[:methods])
      vm_builder.build
    end
  end

  class RuntimeException < Exception; end

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

    ProxyObjectTransmitter = Struct.new(:vmbuilder, :receiver) do
      def convert_to(target_oid)
        (target_oid == vmbuilder.object_id) ?
          receiver :
          ((receiver[0..5] == "\xC1VMOBJ") ? vmbuilder.serialize(receiver[6..-1]) : receiver)
      end
      def get_index(target_oid)
        (target_oid == vmbuilder.object_id && receiver[0..5] == "\xC1VMOBJ") ? receiver[6..-1] : nil
      end
    end

    def initialize(option)
      @provider = instance_eval("#{option[:lang].capitalize}SourceProvider").new(self, option[:pkgs], option[:transpiler])
      @ipc = instance_eval("#{option[:ipc].to_s.capitalize}IpcInterface").new(@provider)
    end

    def add(methods="")
      @provider.source << methods
      @provider.compile
      @ipc.reset @provider
    end

    def build
      @vm = new_vm(nil)
      @vm
    end

    def call(receiver, name, *args)
      if args.last.class==Hash
        kwargs = args.pop
      else
        kwargs = {}
      end
      begin
        @ipc.call(receiver, name, *args, **kwargs)
      rescue => e
        new_vm(e.message)
      rescue RuntimeException => e
        raise e.message
      end
    end

    def serialize(object_lookup_id)
      @ipc.serialize(object_lookup_id)
    end

    def virtual_module_eval(receiver, script, auto_binding=true)
      vars, type_info, params = inspect_local_vars(binding.of_caller(2), script)
      @provider.compile(vars, type_info, params, script, auto_binding)
      @ipc.reset @provider
      evaluated = self.call(receiver, :vm_builtin_eval_func, [params, type_info])

      if auto_binding
        binding.of_caller(2).eval(evaluated[1].map{|k,v| "#{k}=#{v};" if !v.nil? }.join)
      end

      return evaluated[0]
    end

    alias_method :virtual_instance_eval, :virtual_module_eval
    alias_method :virtual_eval, :virtual_module_eval

    private
      def new_vm(receiver)
        vm_builder, provider, transmitter = [self, @provider, ProxyObjectTransmitter.new(self, receiver)]
        vm = Module.new{
          @vm_builder, @provider, @transmitter, @receiver = [vm_builder, provider, transmitter, receiver]
          def self.virtual_module_eval(*args)
            @vm_builder.send(:virtual_module_eval, @receiver, *args)
          end
          def self.method_missing(key, *args, &block)
            @vm_builder.send(:call, @receiver, key, *args)
          end
          def self.___proxy_object_transmitter
            @transmitter
          end
          def self.to_s
            @vm_builder.send(:call, nil, @provider.to_s, self)
          end
          def self.to_a
            @vm_builder.send(:call, nil, @provider.to_a, self)
          end
          def self.vclass
            @vm_builder.send(:call, nil, @provider.to_s,
              @vm_builder.send(:call, nil, @provider.vclass, self)
            )
          end
          def self.vmethods
            @vm_builder.send(:call, nil, @provider.vmethods, self)
          end
        }
        includables = (
          (defs = extract_defs(Ripper.sexp(@provider.source.join(";")))).nil? ? [] : defs.split(",")  +
          provider.pkgs.map{|e| e.class==Hash ? e.values : e}.flatten
        )
        includables.each{|e|
          vm.class_eval {
            define_method e.to_sym, Proc.new { |*args|
              vm_builder.call(receiver, e.to_sym, *args)
            }
          }
        } if !includables.nil?
        vm
      end

      def inspect_local_vars(context, script)
        vars = (args = extract_args(Ripper.sexp(script))).nil? ? [] : args.split(",").uniq.map{|e| e.to_sym} & context.eval("local_variables")

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
    attr_accessor :pkgs
    KwargsConverter = Struct.new(:initializer, :setter, :varargs)

    def initialize(builder, pkgs, transpiler=nil)
      @builder = builder
      @pkgs = pkgs
      @transpiler = transpiler.nil? ? ->(s){s} : transpiler
      @source = []
      @compiled_lib = ""
    end

    def load_packages
      [] #to be overrieded
    end

    def lang
      self.class.name.match(/\:\:(.*)SourceProvider/)[1].downcase.to_sym
    end

    def vclass
      raise Exception.new("An equivalent method for #{__method__} seems not supported in #{lang}.")
    end
    alias_method :vmethods, :vclass
    alias_method :to_s, :vclass
    alias_method :to_a, :vclass

    private
      def prepare_params(input_queue_path, gen_driver, conv_kwargs, name, *args, **kwargs)
        script, params = ["", []]
        if args.count == 1 && args[0].class == Symbol
          # do nothing - this will be called as "#name()"
        else
          type = ->(arg){
            arg.class == Module ? "serialized" : "msgpack"
          }
          args.each_with_index do |arg, i|
            File.write(
              "#{input_queue_path}.#{i}.#{type.call(arg)}",
              arg.class == Module ?
                arg.___proxy_object_transmitter.convert_to(@builder.object_id):
                MessagePack.pack(arg)
              )
            params << "params_#{i}"
            script += gen_driver.call(arg, input_queue_path, i, type.call(arg), params.last)
          end
          if kwargs.count>0
            script += "kwargs=#{conv_kwargs.initializer};"
            kwargs.each_with_index do |(k,v), i|
              File.write(
                "#{input_queue_path}.#{params.count+i}.#{type.call(v)}",
                v.class == Module ?
                  v.___proxy_object_transmitter.convert_to(@builder.object_id):
                  MessagePack.pack(v)
                )
              script += gen_driver.call(v, input_queue_path, params.count+i, type.call(v), conv_kwargs.setter.call(k))
            end
            params << conv_kwargs.varargs
          end
        end
        [script, name==:[] ?  "[#{params.join(',')}]" : "(#{params.join(',')})"]
      end

  end

  class PythonSourceProvider < BaseSourceProvider
    EXT = "py"

    def load_packages
      @pkgs.map{|e|
        if e.class==Hash
          e.map{|k,v| "from #{k} import #{ v.class==Array ? v.join(",") : v}"}
        else
          "import #{e}"
        end
      }.flatten
    end

    def to_a
      :list
    end

    def to_s
      :str
    end

    def vclass
      :type
    end

    def vmethods
      :dir
    end

    def main_loop(input_queue_path, output_queue_path, lib_script=nil)
      <<EOS
# coding: utf-8
import sys
sys.path.append('#{File.dirname(input_queue_path)}')
from #{lib_script} import *
import dill
import msgpack

object_lookup_table = {}
while True :
  try:
    f = open('#{input_queue_path}', 'r')
    source = f.read()
    f.close()
    if source[0]=='\\n':
      f = open('#{output_queue_path}', 'w')
      f.write(dill.dumps(object_lookup_table[int(source[1:len(source)])]))
      f.close()
    else:
      exec(source)
      f = open('#{output_queue_path}', 'w')
      try:
        f.write(msgpack.packb(___result))
      except:
        object_lookup_table[id(___result)] = ___result
        f.write('\\xc1VMOBJ'+str(id(___result)))
      f.close()
  except KeyboardInterrupt:
    print(object_lookup_table.keys())
    exit(0);
  except Exception as e:
    f = open('#{output_queue_path}', 'w')
    f.write('\\xc1VMERR'+str(type(e))+','+str(e.message))
    f.close()
EOS
    end

    def lib_script(ipc=nil)
      if ipc!=:rpc
        @compiled_lib
      else
        # :rpc mode is to be implemented
        @compiled_lib
      end
    end

    def compile(vars=nil, type_info=nil, params=nil, script=nil, auto_binding=nil)
      @compiled_lib = (load_packages + @source).join("\n")
      if !vars.nil? && !type_info.nil? && !params.nil? && !script.nil? && !auto_binding.nil?
        preprocess = vars.map{|e| e.to_s + '=params[0]["'+e.to_s+'"]'}
        postprocess = auto_binding ? vars.map{|e| 'params[0]["'+e.to_s+'"]='+e.to_s } : []
        @compiled_lib += <<EOS
def vm_builtin_eval_func(params):
  #{(preprocess.join(";") + ";") if preprocess.count>0} #{script};
  #{(postprocess.join(";") + ";") if postprocess.count>0} return (None,#{auto_binding ? "params[0]" : "-1" });

EOS
      end
    end

    def generate_message(input_queue_path, receiver, name, *args, **kwargs)
      script, params = ["", ""]
      if args.count + kwargs.count > 0
        gen_driver = ->(arg, input_queue_path, i, type, param_name){
          val = arg.class == Module ?
            (
              (table_index = arg.___proxy_object_transmitter.get_index(@builder.object_id)).nil? ?
                "dill.loads(f.read())" :
                "object_lookup_table[#{table_index}]"
            ) :
            "msgpack.unpackb(f.read())"
          "f=open('#{input_queue_path}.#{i}.#{type}', 'r'); #{param_name}=#{val}; f.close();"
        }
        conv_kwargs = KwargsConverter.new("{}", ->(k){"kwargs['#{k}']"}, "**kwargs")
        script, params = prepare_params(input_queue_path, gen_driver, conv_kwargs, name, *args, **kwargs)
      end
      callee = "#{name}"
      if !receiver.nil?
        if receiver[0..5]=="\xC1VMOBJ"
          script += "receiver=object_lookup_table[#{receiver[6..-1]}];"
        else
          File.write("#{input_queue_path}_serialized", receiver)
          script += "f=open('#{input_queue_path}_serialized', 'r'); receiver=dill.load(f); f.close();"
        end
        if name==:[]
          callee = "receiver"
        else
          callee = "receiver.#{name}"
        end
      end
      script += "___result = #{callee}#{params};"
    end
  end

  class JuliaSourceProvider < BaseSourceProvider
    EXT = "jl"

    def load_packages
      @pkgs.map{|e| "import #{e}"}
    end

    def to_a
      :tuple
    end

    def to_s
      :string
    end

    def vclass
      :summary
    end

    def main_loop(input_queue_path, output_queue_path, lib_script=nil)
      <<EOS
using MsgPack
object_lookup_table = Dict()
while true
  try
    source = open( "#{input_queue_path}", "r" ) do fp
      readall(fp)
    end
    if source[1]=='\n'
      open( "#{output_queue_path}", "w" ) do fp
        serialize(fp, object_lookup_table[parse(Int,source[2:length(source)])])
      end
    else
      result = eval(parse(source))
      open( "#{output_queue_path}", "w" ) do fp
        try
          write(fp,pack(result))
        catch
          object_lookup_table[object_id(result)] = result
          write(fp, 0xc1)
          write(fp, "VMOBJ")
          write(fp, string(object_id(result)))
        end
      end
    end
  catch err
    print(typeof(err))
    if !isa(err, InterruptException)
      open( "#{output_queue_path}", "w" ) do fp
        write(fp, 0xc1)
        write(fp, "VMERR")
        write(fp, string(err))
      end
    else
      exit
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
      @compiled_lib =
        File.read(File.dirname(__FILE__)+"/virtual_module/bridge.jl") + ";" +
        load_packages.join(";\n") + @transpiler.call(@source.join(";\n"))
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

  function vm_builtin_eval_func(params)
    #{vars.map{|e| e.to_s + '=___convert_type("'+e.to_s+'","'+(type_info[:params][e]||"")+'", params[1])'}.join(";")}
    ##{vars.map{|e| 'println("'+e.to_s+'=", typeof('+e.to_s+'))' }.join(";")}
    ___evaluated = (#{@transpiler.call(script)})

    #{vars.map{|e| 'params[1]["'+e.to_s+'"]='+e.to_s }.join(";") if auto_binding}

    (___evaluated,#{auto_binding ? "params[1]" : "-1" })
  end
EOS
      end
    end

    def generate_message(input_queue_path, receiver, name, *args, **kwargs)
      script, params = ["", ""]
      if args.count + kwargs.count > 0
        gen_driver = ->(arg, input_queue_path, i, type, param_name){
          val = case arg.class.to_s
            when "Module" then (
              (table_index = arg.___proxy_object_transmitter.get_index(@builder.object_id)).nil? ?
                "deserialize(fp)" :
                "object_lookup_table[#{table_index}]"
              )
            when "Symbol" then "convert(Symbol, unpack(readall(fp)))"
            else "unpack(readall(fp))"
          end
          script += "#{param_name} =open( \"#{input_queue_path}.#{i}.#{type}\", \"r\" ) do fp; #{val}; end;"
        }
        conv_kwargs = KwargsConverter.new("Dict{Symbol,Any}()", ->(k){"kwargs[:#{k}]"}, ";kwargs...")
        script, params = prepare_params(input_queue_path, gen_driver, conv_kwargs, name, *args, **kwargs)
      end
      callee = "#{name}"
      if !receiver.nil?
        if receiver[0..5]=="\xC1VMOBJ"
          script += "receiver=object_lookup_table[#{receiver[6..-1]}];"
        else
          File.write("#{input_queue_path}_serialized", receiver)
          script += "receiver =open( \"#{input_queue_path}_serialized\", \"r\" ) do fp; deserialize(fp); end;"
        end
        if name==:[]
          callee = "receiver"
        else
          callee = "receiver.#{name}"
        end
      end
      script += "#{callee}#{params};"
    end

  end

  class BaseIpcInterface
    LIB_SCRIPT = "vmlib"

    attr_accessor :work_dir

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
    INPUT = "vminput"
    OUTPUT = "vmoutput"
    MAIN_LOOP = "vmmain"

    def initialize(provider)
      super
      File.mkfifo("#{@work_dir}/#{INPUT}")
      File.mkfifo("#{@work_dir}/#{OUTPUT}")
      at_exit do
        Process.kill(:KILL, @pid) if !@pid.nil?
        FileUtils.remove_entry @work_dir if File.directory?(@work_dir)
      end
    end

    def call(receiver, name, *args, **kwargs)
      #require 'byebug'
      #byebug
      if Helper.is_installed?(@provider.lang)
        enqueue @provider.generate_message("#{@work_dir}/#{INPUT}", receiver, name, *args, **kwargs)
      elsif Helper.is_installed?(:docker)
        enqueue @provider.generate_message("/opt/#{INPUT}", receiver, name, *args, **kwargs)
      else
        raise Exception.new("Either #{@provider.lang} or docker command is required to run virtual_module")
      end
      response = dequeue
      case response[0..5]
      when "\xC1VMERR" then raise RuntimeException, "wrong wrong!: " + response[6..-1]
      when "\xC1VMOBJ" then raise StandardError.new(response)
      else
        begin
          MessagePack.unpack(response)
        rescue
          raise StandardError.new(response)
        end
      end
    end

    def serialize(object_lookup_id)
      enqueue "\n#{object_lookup_id}"
      dequeue
    end

    def reset(source)
      super
      restart_server_process
    end

    private
      def restart_server_process
        if !@pid.nil?
          begin
            Process.getpgid(@pid)
            Process.kill(:KILL, @pid)
          rescue Errno::ESRCH
          end
          @pid=nil
        end
        File.write("#{@work_dir}/#{LIB_SCRIPT}.#{@provider.class::EXT}", @provider.lib_script)
        File.write("#{@work_dir}/#{MAIN_LOOP}.#{@provider.class::EXT}", @provider.main_loop("#{@work_dir}/#{INPUT}", "#{@work_dir}/#{OUTPUT}", LIB_SCRIPT))
        case @provider.lang
        when :julia
          if Helper.is_installed?(:julia)
            command = "julia --depwarn=no -L #{@work_dir}/#{LIB_SCRIPT}.#{@provider.class::EXT} #{@work_dir}/#{MAIN_LOOP}.#{@provider.class::EXT}"
          elsif Helper.is_installed?(:docker)
            command = "docker run -v #{@work_dir}/:/opt/ remore/virtual_module julia --depwarn=no -L /opt/#{LIB_SCRIPT}.#{@provider.class::EXT} /opt/#{MAIN_LOOP}.#{@provider.class::EXT}"
          else
            raise Exception.new("Either julia or docker command is required to run virtual_module")
          end
        when :python
          # -B : Prevent us from creating *.pyc cache - this will be problematic when we call #virtual_module_eval repeatedly.
          command = "python -B #{@work_dir}/#{MAIN_LOOP}.#{@provider.class::EXT}"
        else
          raise Exception.new("Unsupported language was specified")
        end
        @pid = Process.spawn(command, :err => :out,:out => "/dev/null") # , :pgroup => Process.pid)
        #@pid = Process.spawn(command) # , :pgroup => Process.pid)
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

    def call(name, *args, **kwargs)
      restart_server_process
      while `echo exit | telnet #{@server} #{@port} 2>&1`.chomp[-5,5]!="host." do
        sleep(0.05)
      end
      @client = MessagePack::RPC::Client.new(@server, @port) if @client.nil?
      @client.timeout = @timeout
      args.count>0 || kwargs.count>0 ? @client.call(name, *args, **kwargs) : @client.call(name)
    end

    private
      def init_connection
        @pid = nil
        @client.close if !@client.nil?
        @client = nil
        at_exit do
          @client.close if !@client.nil?
          Process.kill(:KILL, @pid) if !@pid.nil?
          FileUtils.remove_entry @work_dir if File.directory?(@work_dir)
        end
      end

      def restart_server_process
        Process.kill(:KILL, @pid) if !@pid.nil?
        `lsof -wni tcp:#{@port} | cut -f 4 -d ' ' | sed -ne '2,$p' | xargs kill -9`
        init_connection
        File.write("#{@work_dir}/#{LIB_SCRIPT}.#{@provider.class::EXT}", @provider.lib_script(:rpc))
        @pid = Process.spawn("julia --depwarn=no #{@work_dir}/#{LIB_SCRIPT}.#{@provider.class::EXT} #{@port}", :err => :out,:out => "/dev/null") #, :pgroup=>Process.pid)
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
