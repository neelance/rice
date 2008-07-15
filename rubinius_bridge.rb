require "debugger/interface"

class Debugger
  class RiceBridgeInterface < Interface
    def initialize(out=STDOUT, err=STDERR)
      @out, @err = out, err
      load_commands
      Debugger.instance.interface = self
    end
    
    def process_commands(dbg, thread, ctxt, bp_list)
      file = ctxt.file.to_s
      line = ctxt.method.line_from_ip(ctxt.ip)
      
      if file =~ /^kernel/ or file == __FILE__
        process_command dbg, "o"
        return
      end
      
      trace = Backtrace.backtrace(ctxt).frames.reverse
      trace.reject! { |frame| frame.file.to_s =~ /^kernel/ or frame.file.to_s == __FILE__ }
      trace.map! { |frame| [File.expand_path(frame.file.to_s), frame.line] }
      trace.pop
      trace << [File.expand_path(file), line]
      last_frame = nil
      trace.reject! { |frame| duplicate = (last_frame == frame); last_frame = frame; duplicate }
      @out.puts "#rice:pos #{trace.inspect}"
      
      until @done do
        command = gets.strip
        case command
        when "step"
          process_command dbg, "s"
        when "eval"
          code = gets.strip
          output = process_command dbg, "Marshal.dump(#{code})"
          puts "#rice:out #{output}"
        end
      end
    end
    
    def handle_exception(e)
      @err.puts ""
      @err.puts "An exception has occurred:\n    #{e.message} (#{e.class})"
      @err.puts "Backtrace:"
      bt = e.awesome_backtrace
      begin
        output = Output.new
        output.set_columns(['%s', '%-s'], ' at ')
        first = true
        bt.frames.each do |ctxt|
          recv = ctxt.describe
          loc = ctxt.location
          break if recv =~ /Debugger.*#process_command/
          output.set_color(bt.color_from_loc(loc, first))
          first = false # special handling for first line
          output << [recv, loc]
        end
      rescue
        output = bt.show
      end
      @err.puts output
    end
  end
end

Debugger::RiceBridgeInterface.new
Compile.debug_script!
Compile.load_from_extension $*[0]
puts "#rice:end"
exit