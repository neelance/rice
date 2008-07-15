a = 5
b = 4


class String
  def <=>(other)
    self.length <=> other.length
  end
end

def test
  junk = %w[these words should be sorted in the order of their length]
  sorted = junk.sort
  puts sorted
end

test
puts "end"