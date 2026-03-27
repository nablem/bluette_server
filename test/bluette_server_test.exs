defmodule BluetteServerTest do
  use ExUnit.Case
  doctest BluetteServer

  test "greets the world" do
    assert BluetteServer.hello() == :world
  end
end
