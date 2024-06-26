defmodule SSHTest.SCPTest do
  use ExUnit.Case, async: true

  @moduletag :scp

  @content "foo\nbar\n"

  @tmp_ssh_fetch "/tmp/ssh_fetch.txt"
  test "we can fetch a file with scp" do
    File.write!(@tmp_ssh_fetch, @content)

    conn = SSH.connect!("localhost")
    assert @content == SSH.fetch!(conn, @tmp_ssh_fetch)
    File.rm_rf!(@tmp_ssh_fetch)
  end

  @tmp_ssh_send "/tmp/ssh_send.txt"
  test "we can send an scp" do
    File.rm_rf!(@tmp_ssh_send)
    conn = SSH.connect!("localhost")
    SSH.send!(conn, @content, @tmp_ssh_send)

    assert @content == File.read!(@tmp_ssh_send)
    File.rm_rf!(@tmp_ssh_send)
  end

  @tmp_ssh_big_file "/tmp/ssh_big_file"
  @tmp_ssh_big_sent "/tmp/ssh_big_sent"
  test "we can send a really big file" do
    File.rm_rf!(@tmp_ssh_big_file)
    File.rm_rf!(@tmp_ssh_big_sent)

    fn -> :crypto.strong_rand_bytes(1024) end
    |> Stream.repeatedly()
    # 1 MB
    |> Stream.take(1024)
    |> Enum.into(File.stream!(@tmp_ssh_big_file))

    src_bin = File.read!(@tmp_ssh_big_file)

    hash = :crypto.hash(:sha256, src_bin)

    "localhost"
    |> SSH.connect!()
    |> SSH.send!(src_bin, @tmp_ssh_big_sent)

    res_bin = File.read!(@tmp_ssh_big_sent)

    assert hash == :crypto.hash(:sha256, res_bin)

    File.rm_rf!(@tmp_ssh_big_file)
    File.rm_rf!(@tmp_ssh_big_sent)
  end

  @scptxt1 "/tmp/scp_test_1.txt"
  test "streaming a list to stdin over the connection is possible" do
    File.rm_rf!(@scptxt1)

    "localhost"
    |> SSH.connect!()
    |> SSH.send!(["foo", "bar"], @scptxt1)

    Process.sleep(100)

    assert "foobar" == File.read!(@scptxt1)
  end

  @scptxt2 "/tmp/scp_test_2.txt"
  test "streaming an improper list to stdin over the connection is possible" do
    File.rm_rf!(@scptxt2)

    "localhost"
    |> SSH.connect!()
    |> SSH.send!(["foo" | "bar"], @scptxt2)

    Process.sleep(100)

    assert "foobar" == File.read!(@scptxt2)
  end

  @scptxt3 "/tmp/scp_test_3"
  test "permissions are correctly set (issue 22)" do
    File.rm_rf!(@scptxt3)

    "localhost"
    |> SSH.connect!()
    |> SSH.send!("#!/bin/sh\necho foo", @scptxt3, permissions: 0o777)

    Process.sleep(100)

    # make sure it's executable
    assert {_, 0} = System.cmd("test", ["-x", @scptxt3])
    # really make sure
    assert {"foo" <> _, 0} = System.cmd(@scptxt3, [])
  end

  @invalid_file "/this-is-not-a-writable-file"
  test "streaming content to a bad file is possible" do
    assert_raise SSH.SCP.Error,
                 "error executing SCP send: scp: /this-is-not-a-writable-file: Permission denied\n",
                 fn ->
                   "localhost"
                   |> SSH.connect!()
                   |> SSH.send!("foo", @invalid_file)
                 end
  end

  # STILL ASPIRATIONAL.  To be implemented in the future.
  @scptxt3_src "/tmp/scp_test_3_src"
  @scptxt3_dst "/tmp/scp_test_3_dst"
  test "streaming a file over the connection is possible" do
    File.rm_rf!(@scptxt3_src)
    File.rm_rf!(@scptxt3_src)

    fn -> :crypto.strong_rand_bytes(1024) end
    |> Stream.repeatedly()
    # 10 KB
    |> Stream.take(10)
    |> Enum.into(File.stream!(@scptxt3_src))

    src_hash =
      File.read!(@scptxt3_src)
      |> (fn bytes -> :crypto.hash(:sha256, bytes) end).()
      |> Base.encode64()

    fstream = File.stream!(@scptxt3_src, [], 1024)

    "localhost"
    |> SSH.connect!()
    |> SSH.send!(fstream, @scptxt3_dst)

    Process.sleep(100)

    dst_hash =
      File.read!(@scptxt3_dst)
      |> (fn bytes -> :crypto.hash(:sha256, bytes) end).()
      |> Base.encode64()

    assert src_hash == dst_hash
  end
end
