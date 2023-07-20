defmodule Sanity.Listen do
  @moduledoc """
  For listening to changes using the [Sanity CMS listening API
  endpoint](https://www.sanity.io/docs/listening).
  """

  defmodule Event do
    @moduledoc """
    Sanity event. Contains `data`, `event`, and `id` fields. See [Sanity
    docs](https://www.sanity.io/docs/listening) for a list of possible events.
    """

    defstruct data: nil, event: nil, id: nil
  end

  @request_opts_schema [
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
    token: [
      type: :string,
      doc: "Sanity auth token."
    ]
  ]

  @listen_opts_schema [
                        query_params: [
                          type: :keyword_list,
                          default: []
                        ],
                        variables: [
                          type: :map,
                          default: %{}
                        ]
                      ] ++ @request_opts_schema

  @doc """
  Returns an endless `Stream` of `Sanity.Listen.Event` items.

  This stream must be iterated upon in the same process that called this function. When this process
  exits then the underlying HTTPS connection will be closed. The HTTPS connection will also be
  closed if the stream is halted. For example, if `Enum.take/2` is called with the stream then the
  HTTPS connection will be closed after the specified number of events have been received.
  """
  def listen!(query, opts) do
    opts = NimbleOptions.validate!(opts, @listen_opts_schema)
    query_params = Sanity.query_to_query_params(query, opts[:variables], opts[:query_params])

    path =
      "/#{opts[:api_version]}/data/listen/#{opts[:dataset]}?#{URI.encode_query(query_params)}"

    {:ok, conn} = Mint.HTTP.connect(:https, "#{opts[:project_id]}.api.sanity.io", 443)
    {:ok, conn, request_ref} = Mint.HTTP.request(conn, "GET", path, headers(opts), nil)

    Stream.resource(
      fn -> conn end,
      fn conn ->
        receive do
          message ->
            {:ok, conn, responses} = Mint.HTTP.stream(conn, message)
            {responses, conn}
        end
      end,
      fn conn ->
        {:ok, conn} = Mint.HTTP.close(conn)
        conn
      end
    )
    |> Stream.flat_map(fn
      {:status, ^request_ref, 200} -> []
      {:headers, ^request_ref, _headers} -> []
      {:data, ^request_ref, data} -> [data]
    end)
    |> transform_to_events()
  end

  defp headers(opts) do
    case Keyword.fetch(opts, :token) do
      {:ok, token} -> [{"authorization", "Bearer #{token}"}]
      :error -> []
    end
  end

  defp transform_to_events(stream) do
    Stream.transform(stream, "", fn data, remainder ->
      {remainder, event_payloads} = String.split(remainder <> data, "\n\n") |> List.pop_at(-1)

      events =
        Enum.flat_map(event_payloads, fn
          ":" -> []
          event_payload -> [payload_to_event(event_payload)]
        end)

      {events, remainder}
    end)
  end

  defp payload_to_event(event_payload) do
    map =
      event_payload
      |> String.split("\n")
      |> Map.new(fn line ->
        [key, value] = String.split(line, ": ", parts: 2)
        {key, value}
      end)

    %Event{
      data: map["data"] && Jason.decode!(map["data"]),
      event: map["event"],
      id: map["id"]
    }
  end

  def listen_for_doc_changes(doc_id, opts) do
    opts = NimbleOptions.validate!(opts, @request_opts_schema)
    ids = [doc_id, "drafts.#{doc_id}"]

    listen!(
      "_id in $ids",
      Keyword.merge(opts, query_params: [include_result: true], variables: %{ids: ids})
    )

    # FIXME
  end
end
