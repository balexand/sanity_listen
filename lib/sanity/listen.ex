defmodule Sanity.Listen do
  @moduledoc """
  Documentation for `Sanity.Listen`.
  """

  defmodule Event do
    defstruct data: nil, event: nil, id: nil
  end

  @opts_schema [
    api_version: [
      type: :string,
      default: "v2021-10-21"
    ],
    dataset: [
      type: :string,
      doc: "Sanity dataset.",
      required: true
    ],
    project_id: [
      type: :string,
      doc: "Sanity project ID.",
      required: true
    ],
    query_params: [
      type: :keyword_list,
      default: []
    ],
    variables: [
      type: :map,
      default: %{}
    ],
    token: [
      type: :string,
      doc: "Sanity auth token."
    ]
  ]

  @doc """
  Calls the [Sanity listen](https://www.sanity.io/docs/listening) API endpoint.
  """
  def listen(query, opts, acc, fun) do
    opts = NimbleOptions.validate!(opts, @opts_schema)
    query_params = Sanity.query_to_query_params(query, opts[:variables], opts[:query_params])

    url =
      "https://#{opts[:project_id]}.api.sanity.io/#{opts[:api_version]}/data/listen/#{opts[:dataset]}?#{URI.encode_query(query_params)}"

    request = Finch.build(:get, url, headers(opts))

    Finch.stream(
      request,
      Sanity.Listen.Finch,
      %{acc: acc, remainder: ""},
      fn
        {:status, 200}, stream_acc ->
          stream_acc

        {:status, status}, _stream_acc ->
          raise "response error status #{inspect(status)}"

        {:headers, _headers}, stream_acc ->
          stream_acc

        {:data, data}, %{remainder: remainder} = stream_acc ->
          process_data(remainder <> data, stream_acc, fun)
      end,
      receive_timeout: 60_000
    )
  end

  defp headers(opts) do
    case Keyword.fetch(opts, :token) do
      {:ok, token} -> [{"authorization", "Bearer #{token}"}]
      :error -> []
    end
  end

  defp process_data(data, stream_acc, fun) do
    case String.split(data, "\n\n", parts: 2) do
      [payload, remainder] ->
        stream_acc = payload |> String.trim() |> process_payload(stream_acc, fun)
        process_data(remainder, stream_acc, fun)

      [remainder] ->
        %{stream_acc | remainder: remainder}
    end
  end

  defp process_payload(":", stream_acc, _fun), do: stream_acc

  defp process_payload(payload, stream_acc, fun) do
    map =
      payload
      |> String.split("\n")
      |> Map.new(fn line ->
        [key, value] = String.split(line, ": ", parts: 2)
        {key, value}
      end)

    process_event(
      %Event{
        data: map["data"] && Jason.decode!(map["data"]),
        event: map["event"],
        id: map["id"]
      },
      stream_acc,
      fun
    )
  end

  defp process_event(%Event{event: event_name} = event, _stream_acc, _fun)
       when event_name in ~W[channelError disconnect] do
    raise "error event #{inspect(event)}"
  end

  defp process_event(%Event{} = event, %{acc: acc} = stream_acc, fun) do
    %{stream_acc | acc: fun.(event, acc)}
  end
end
