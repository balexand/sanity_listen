defmodule SanityListenTest do
  use ExUnit.Case
  doctest SanityListen

  test "greets the world" do
    assert SanityListen.hello() == :world
  end
end
