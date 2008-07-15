require "rubygems"
require "ruby-debug"

module Debugger
  class RiceBridgeCommandProcessor < Processor
    attr_reader   :display
    
    def initialize
      @display = []
      
      @mutex = Mutex.new
      @last_cmd = nil
      @last_file = nil   # Filename the last time we stopped
      @last_line = nil   # line number the last time we stopped
      @debugger_breakpoints_were_empty = false # Show breakpoints 1st time
      @debugger_displays_were_empty = true # No display 1st time
      @debugger_context_was_dead = true # Assume we haven't started.
    end
    
    require 'pathname'  # For cleanpath
    
    # Regularize file name. 
    # This is also used as a common funnel place if basename is 
    # desired or if we are working remotely and want to change the 
    # basename. Or we are eliding filenames.
    def self.canonic_file(filename)
      # For now we want resolved filenames 
      if Command.settings[:basename]
        File.basename(filename)
      else
        # Cache this?
        Pathname.new(filename).cleanpath.to_s
      end
    end
    
    def self.protect(mname)
      alias_method "__#{mname}", mname
      module_eval %{
        def #{mname}(*args)
          @mutex.synchronize do
            __#{mname}(*args)
          end
        rescue IOError, Errno::EPIPE
        rescue Exception
          print "INTERNAL ERROR!!! #\{$!\}\n" rescue nil
          print $!.backtrace.map{|l| "\t#\{l\}"}.join("\n") rescue nil
        end
      }
    end
    
    def at_breakpoint(context, breakpoint)
      aprint 'stopped' if Debugger.annotate.to_i > 2
      n = Debugger.breakpoints.index(breakpoint) + 1
      file = CommandProcessor.canonic_file(breakpoint.source)
      line = breakpoint.pos
      if Debugger.annotate.to_i > 2
        print afmt("source #{file}:#{line}")
      end
      print "Breakpoint %d at %s:%s\n", n, file, line
    end
    protect :at_breakpoint
    
    def at_catchpoint(context, excpt)
      aprint 'stopped' if Debugger.annotate.to_i > 2
      file = CommandProcessor.canonic_file(context.frame_file(0))
      line = context.frame_line(0)
      print afmt("%s:%d" % [file, line]) if ENV['EMACS']
      print "Catchpoint at %s:%d: `%s' (%s)\n", file, line, excpt, excpt.class
      fs = context.stack_size
      tb = caller(0)[-fs..-1]
      if tb
        for i in tb
          print "\tfrom %s\n", i
        end
      end
    end
    protect :at_catchpoint
    
    def at_tracing(context, file, line)
      return if defined?(Debugger::RDEBUG_FILE) && 
      Debugger::RDEBUG_FILE == file # Don't trace ourself
      @last_file = CommandProcessor.canonic_file(file)
      file = CommandProcessor.canonic_file(file)
      unless file == @last_file and @last_line == line and 
        Command.settings[:tracing_plus]
        print "Tracing(%d):%s:%s %s",
        context.thnum, file, line, Debugger.line_at(file, line)
        @last_file = file
        @last_line = line
      end
      always_run(context, file, line, 2)
    end
    protect :at_tracing
    
    def at_line(context, file, line)
      process_commands(context, file, line)
    end
    protect :at_line
    
    def at_return(context, file, line)
      context.stop_frame = -1
      process_commands(context, file, line)
    end
    
    private
    
    # Run these commands, for example display commands or possibly
    # the list or irb in an "autolist" or "autoirb".
    # We return a list of commands that are acceptable to run bound
    # to the current state.
    def always_run(context, file, line, run_level)
      event_cmds = Command.commands.select{|cmd| cmd.event }
      
      # Remove some commands in post-mortem
      event_cmds = event_cmds.find_all do |cmd| 
        cmd.allow_in_post_mortem
      end if context.dead?
      
      state = State.new do |s|
        s.context = context
        s.file    = file
        s.line    = line
        s.binding = context.frame_binding(0)
        s.display = display
        s.commands = event_cmds
      end
      
      # Bind commands to the current state.
      commands = event_cmds.map{|cmd| cmd.new(state)}
      
      list = commands.select do |cmd| 
        cmd.class.always_run >= run_level
      end
      list.each {|cmd| cmd.execute}
      return state, commands
    end
    
    # Handle debugger commands
    def process_commands(context, file, line)
      state, commands = always_run(context, file, line, 1)
      @state = state
      
      if file == __FILE__
        one_cmd(commands, context, "s")
        return
      end
      
      preloop(commands, context)
      
      trace = []
       (0...context.stack_size).to_a.reverse.each do |i|
        file = context.frame_file(i)
        line = context.frame_line(i)
        next if file == __FILE__
        trace << [File.expand_path(file), line]
      end
      
      puts "#rice:pos #{trace.inspect}"
      while !state.proceed?
        begin
          catch(:debug_error) do
            input = STDIN.gets.strip
            case input
            when "step"
              one_cmd(commands, context, "s")
            when "eval"
              code = STDIN.gets.strip
              state.output = ""
              one_cmd(commands, context, "e Marshal.dump(#{code})")
              puts "#rice:out #{state.output}"
            end
          end
        rescue StandardError => e
          puts e.to_s, e.backtrace
        end
      end
      postloop(commands, context)
    end
    
    def one_cmd(commands, context, input)
      if cmd = commands.find{ |c| c.match(input) }
        if context.dead? && cmd.class.need_context
          STDOUT.print "Command is unavailable\n"
        else
          cmd.execute
        end
      else
        unknown_cmd = commands.find{|cmd| cmd.class.unknown }
        if unknown_cmd
          unknown_cmd.execute
        else
          STDOUT.print "Unknown command\n"
        end
      end
    end
    
    def preloop(commands, context)
      aprint('stopped') if Debugger.annotate.to_i > 2
      if context.dead?
        unless @debugger_context_was_dead
          if Debugger.annotate.to_i > 2
            aprint('exited') 
            print "The program finished.\n" 
          end
          @debugger_context_was_dead = true
        end
      end
    end
    
    def postloop(commands, context)
    end
    
    class State # :nodoc:
      attr_accessor :context, :file, :line, :binding
      attr_accessor :frame_pos, :previous_line, :display
      attr_accessor :commands, :output
      
      def initialize
        super()
        @frame_pos = 0
        @previous_line = nil
        @proceed = false
        @output = ""
        yield self
      end
      
      def interface
        self
      end
      
      def errmsg(*args)
        STDOUT.printf(*args)
      end
      
      def print(*args)
        out = sprintf(*args)
        @output << out
      end
      
      def proceed?
        @proceed
      end
      
      def proceed
        @proceed = true
      end
    end
  end
  
  self.handler = RiceBridgeCommandProcessor.new
end

Debugger.start
debugger
load $*[0]
puts "#rice:end"
exit