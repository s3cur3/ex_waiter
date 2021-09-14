defmodule ExWaiterTest do
  use ExUnit.Case

  alias ExWaiter.Exceptions.InvalidResult
  alias ExWaiter.Exceptions.RetriesExhausted

  # We want to simulate a series of queries and stub out the expected values upon
  # each successive attempt. This store takes an ordered list of expected return
  # values and a starting index of 0. Every time it is queried, it grabs the value
  # at the current index and increments the index.
  defmodule OrderedStore do
    def new(ordered_attempts, starting_index \\ 0) do
      {:ok, store} = Agent.start_link(fn -> {ordered_attempts, starting_index} end)
      store
    end

    def current_value(store) do
      value =
        Agent.get(store, fn {attempts, current_index} -> Enum.at(attempts, current_index) end)

      increment_index(store)
      value
    end

    defp increment_index(store) do
      Agent.update(store, fn {attempts, current_index} -> {attempts, current_index + 1} end)
    end
  end

  describe "await/2" do
    test "waits for a result and retries up to 5 times by default" do
      attempts = [nil, nil, nil, nil, "Got it!"]
      store = OrderedStore.new(attempts)

      assert {:ok, "Got it!", waiter} =
               ExWaiter.await(fn ->
                 case OrderedStore.current_value(store) do
                   nil ->
                     {:error, nil}

                   value ->
                     {:ok, value}
                 end
               end)

      assert %{
               attempt_num: 5,
               attempts_left: 0,
               num_attempts: 5,
               attempts: [
                 %{attempt_num: 1, fulfilled?: false, value: nil, delay_before: 10},
                 %{attempt_num: 2, fulfilled?: false, value: nil, delay_before: 20},
                 %{attempt_num: 3, fulfilled?: false, value: nil, delay_before: 30},
                 %{attempt_num: 4, fulfilled?: false, value: nil, delay_before: 40},
                 %{attempt_num: 5, fulfilled?: true, value: "Got it!", delay_before: 50}
               ],
               total_delay: 150,
               fulfilled?: true,
               value: "Got it!"
             } = waiter
    end

    test "doesn't make any more attempts than necessary" do
      attempts = [nil, "Got it!", "third", "fourth", "fifth"]
      store = OrderedStore.new(attempts)

      assert {:ok, "Got it!", waiter} =
               ExWaiter.await(fn ->
                 case OrderedStore.current_value(store) do
                   nil -> {:error, nil}
                   value -> {:ok, value}
                 end
               end)

      assert %{
               attempt_num: 2,
               attempts_left: 3,
               num_attempts: 5,
               attempts: [
                 %{attempt_num: 1, fulfilled?: false, value: nil},
                 %{attempt_num: 2, fulfilled?: true, value: "Got it!"}
               ],
               fulfilled?: true,
               value: "Got it!"
             } = waiter
    end

    test "throws an exception by default when retries are exhausted" do
      attempts = [nil, nil, nil, nil, nil]
      store = OrderedStore.new(attempts)

      assert_raise(RetriesExhausted, fn ->
        ExWaiter.await(fn ->
          case OrderedStore.current_value(store) do
            nil -> {:error, nil}
            value -> {:ok, value}
          end
        end)
      end)
    end

    test "can optionally return an error tuple when retries are exhausted" do
      attempts = [nil, nil, nil, nil, nil]
      store = OrderedStore.new(attempts)

      assert {:error, nil, waiter} =
               ExWaiter.await(
                 fn ->
                   case OrderedStore.current_value(store) do
                     nil -> {:error, nil}
                     value -> {:ok, value}
                   end
                 end,
                 exception_on_retries_exhausted?: false
               )

      assert %{
               attempt_num: 5,
               attempts_left: 0,
               num_attempts: 5,
               attempts: [
                 %{attempt_num: 1, fulfilled?: false, value: nil},
                 %{attempt_num: 2, fulfilled?: false, value: nil},
                 %{attempt_num: 3, fulfilled?: false, value: nil},
                 %{attempt_num: 4, fulfilled?: false, value: nil},
                 %{attempt_num: 5, fulfilled?: false, value: nil}
               ],
               fulfilled?: false,
               value: nil
             } = waiter
    end

    test "can be configured for less attempts" do
      attempts = [nil, nil, "Got it!"]
      store = OrderedStore.new(attempts)

      assert {:error, nil, waiter} =
               ExWaiter.await(
                 fn ->
                   case OrderedStore.current_value(store) do
                     nil -> {:error, nil}
                     value -> {:ok, value}
                   end
                 end,
                 num_attempts: 2,
                 exception_on_retries_exhausted?: false
               )

      assert %{
               attempt_num: 2,
               attempts_left: 0,
               num_attempts: 2,
               attempts: [
                 %{attempt_num: 1, fulfilled?: false, value: nil},
                 %{attempt_num: 2, fulfilled?: false, value: nil}
               ],
               fulfilled?: false,
               value: nil
             } = waiter
    end

    test "waits increasing milliseconds before each successive retry by default" do
      attempts = [nil, nil, nil, nil, nil]
      store = OrderedStore.new(attempts)

      assert {:error, nil, waiter} =
               ExWaiter.await(
                 fn ->
                   case OrderedStore.current_value(store) do
                     nil -> {:error, nil}
                     value -> {:ok, value}
                   end
                 end,
                 exception_on_retries_exhausted?: false
               )

      assert %{
               attempts: [
                 %{attempt_num: 1, delay_before: 10},
                 %{attempt_num: 2, delay_before: 20},
                 %{attempt_num: 3, delay_before: 30},
                 %{attempt_num: 4, delay_before: 40},
                 %{attempt_num: 5, delay_before: 50}
               ],
               fulfilled?: false,
               total_delay: 150
             } = waiter
    end

    test "takes a delay configuration function" do
      attempts = [nil, nil, nil, nil, nil]
      store = OrderedStore.new(attempts)

      assert {:error, nil, waiter} =
               ExWaiter.await(
                 fn ->
                   case OrderedStore.current_value(store) do
                     nil -> {:error, nil}
                     value -> {:ok, value}
                   end
                 end,
                 delay_before_fn: fn waiter -> waiter.attempt_num * 2 end,
                 exception_on_retries_exhausted?: false
               )

      assert %{
               attempts: [
                 %{attempt_num: 1, delay_before: 2},
                 %{attempt_num: 2, delay_before: 4},
                 %{attempt_num: 3, delay_before: 6},
                 %{attempt_num: 4, delay_before: 8},
                 %{attempt_num: 5, delay_before: 10}
               ],
               fulfilled?: false,
               total_delay: 30
             } = waiter
    end

    test "raises an exception with an invalid result" do
      attempts = [nil]
      store = OrderedStore.new(attempts)

      assert_raise(InvalidResult, fn ->
        ExWaiter.await(fn ->
          case OrderedStore.current_value(store) do
            nil ->
              "This is an invalid result. It should be either {:ok, term} or {:error, term}"

            value ->
              {:ok, value}
          end
        end)
      end)
    end
  end
end
