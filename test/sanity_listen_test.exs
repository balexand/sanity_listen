defmodule SanityListenTest do
  use ExUnit.Case
  doctest Sanity.Listen

  test "greets the world" do
    assert Sanity.Listen.hello() == :world
  end
end
