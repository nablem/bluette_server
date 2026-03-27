defmodule BluetteServer.Auth.MockVerifierTest do
  use ExUnit.Case, async: true

  alias BluetteServer.Auth.MockVerifier

  test "returns claims for valid mock token" do
    assert {:ok, claims} = MockVerifier.verify("mock:abc123:abc@example.com")

    assert claims == %{
             uid: "abc123",
             email: "abc@example.com",
             provider: "google",
             mock: true
           }
  end

  test "returns invalid_token when prefix is wrong" do
    assert {:error, :invalid_token} = MockVerifier.verify("abc123")
  end

  test "returns invalid_token_format when payload is malformed" do
    assert {:error, :invalid_token_format} = MockVerifier.verify("mock:abc123")
  end
end
