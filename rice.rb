require "thread"

class DebugSession
  attr_reader :process, :trace, :output_queue
  
  def initialize(name, command)
    @name = name
    @command = command
    @process = nil
    @quiet = false
    
    @ready_queue = Queue.new
    @output_queue = Queue.new
    @trace = nil
    init
  end
  
  def start(file)
    @process = File.popen "#{@command} #{file} 2>&1", "w+"
    Thread.new do
      Thread.current.abort_on_exception = true
      loop do
        line = @process.gets
        if line[0..5] == "#rice:"
          command = line[6..8]
          data = line[10..-1]
          case command
          when "pos"
            write line
            @trace = Trace.new Kernel.eval(data)
            @ready_queue.push true
          when "out"
            @output_queue.clear
            @output_queue.push Kernel.eval(data)
          when "end"
            write line
            exit
          else
            write line
          end
        else
          write line
        end
      end
    end
  end
  
  def write(text)
    puts format("%-10s", "#{@name}>") + text unless @quiet
  end
  
  def kill
    @quiet = true
    Process.kill "TERM", @process.pid
    Process.wait @process.pid
  end
  
  def init
    # override
  end
  
  def command
    # override
  end
  
  def wait
    while @trace.nil?
      @ready_queue.pop
      @ready_queue.clear
    end
  end
  
  def step
    @trace = nil
    @process.puts "step"
  end
  
  def eval(code)
    @process.puts "eval", code
  end
end

class Trace
  attr_reader :frames
  
  def initialize(frames)
    @frames = frames
  end
  
  def <=>(other)
    i = 0
    loop do
      frame1 = @frames[i]
      frame2 = other.frames[i]
      return 0 if frame1.nil? and frame2.nil?
      return -1 if frame1.nil?
      return 1 if frame2.nil?
      raise "Trace mismatch" if frame1[0] != frame2[0]
      return -1 if frame1[1] < frame2[1]
      return 1 if frame1[1] > frame2[1]
      i += 1
    end
  end
end

def sync(sessions)
  loop do
    sessions.each { |s| s.wait }
    case sessions[0].trace <=> sessions[1].trace
    when -1
      sessions[0].step
    when 1
      sessions[1].step
    when 0
      return
    end
  end
end

IGNORED_VARIABLES = ["__dbg_verbose_save"]

def compare(sessions)
  code = "local_variables"
  sessions.each { |s| s.eval code }
  outputs = sessions.map { |s| Marshal.load(s.output_queue.pop).uniq.sort.reject { |name| IGNORED_VARIABLES.include? name } }
  raise "#{code} difference: #{outputs[0].inspect} != #{outputs[1].inspect}" if outputs[0] != outputs[1]
  
  outputs[0].each do |name|
    sessions.each { |s| s.eval name }
    values = sessions.map { |s| s.output_queue.pop }
    raise "#{code} value difference: #{name} -> #{values[0].inspect} != #{values[1].inspect}" if values[0] != values[1]
  end
end

file = $*[0]

sessions = []
sessions << DebugSession.new("MRI", "ruby mri_bridge.rb")
sessions << DebugSession.new("rubinius", "~/workspace/rubinius_ubuntu/bin/rbx rubinius_bridge.rb")

begin
  sessions.each { |s| s.start(file) }
  loop do
    sync sessions
    compare sessions
    sessions.each { |s| s.step }
  end
rescue Interrupt
ensure
  sessions.each { |s| s.kill }
end