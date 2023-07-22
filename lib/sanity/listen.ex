defmodule Sanity.Listen do
  @moduledoc """
  For listening to changes using the [Sanity CMS listening API
  endpoint](https://www.sanity.io/docs/listening).

  The streams returned by `listen!/2` and `listen_for_doc_changes!/2` must be iterated upon in the
  same process that called the function. When this process exits then the underlying HTTPS
  connection will be closed. The HTTPS connection will also be closed if the stream is halted.
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

  defmodule DocListenConn do
    @moduledoc false
    defstruct [:doc, :draft, :id, :opts]
  end

  @doc """
  Returns `{doc, doc_conn}` where `doc` is the latest version, including drafts, of a document. `doc_conn`
  can be passed to `listen_for_doc_changes!/1` to stream document updates.
  """
  def get_draft_or_doc!(id, opts) do
    opts = NimbleOptions.validate!(opts, @request_opts_schema)

    draft_id = "drafts.#{id}"

    results =
      Sanity.query("*[_id in $ids]", ids: [id, draft_id])
      |> Sanity.request!(opts)
      |> Sanity.result!()

    doc = Enum.find(results, &(&1["_id"] == id))
    draft = Enum.find(results, &(&1["_id"] == draft_id))

    {draft || doc, %DocListenConn{doc: doc, draft: draft, id: id, opts: opts}}
  end

  @doc """
  Returns an endless `Stream` that emits the latest version of a document. Call
  `get_draft_or_doc!/2` to get the `doc_conn` to be passed to this function. If a draft version of
  the document exists then the draft will be emitted. Otherwise, the published version of the
  document will be emitted. If neither the draft not the published document exist then `nil` will be
  emitted.

  When the "Publish" or "Unpublish" actions are being performed in Sanity Studio then it is normal
  to temporarily have an outdated document or `nil` emitted. For example, consider the case where
  you have a unpublished draft and the click the "Publish" button. Sanity Studio will delete the
  draft document and create the published document. The order of these mutations is inconsistent and
  if draft is deleted before the published document is created then `nil` will be emitted briefly.
  """
  def listen_for_doc_changes!(%DocListenConn{id: id} = doc_conn) do
    draft_id = "drafts.#{id}"

    listen!(
      "_id in $ids",
      Keyword.merge(doc_conn.opts,
        query_params: [include_result: true],
        variables: %{ids: [id, draft_id]}
      )
    )
    |> Stream.transform(%{doc: doc_conn.doc, draft: doc_conn.draft}, fn
      %Event{event: "welcome"}, acc ->
        {[], acc}

      %Event{event: "mutation", data: data}, acc ->
        last = acc.draft || acc.doc

        acc =
          case data do
            %{"documentId" => ^id, "result" => %{"_id" => ^id} = result} ->
              # doc updated
              %{acc | doc: result}

            %{"documentId" => ^id} = data when not is_map_key(data, "result") ->
              # doc deleted
              %{acc | doc: nil}

            %{"documentId" => ^draft_id, "result" => %{"_id" => ^draft_id} = result} ->
              # draft updated
              %{acc | draft: result}

            %{"documentId" => ^draft_id} = data when not is_map_key(data, "result") ->
              # draft deleted
              %{acc | draft: nil}

            %{"documentId" => "_.listeners." <> _} ->
              # ignore noise related to listener
              acc
          end

        next = acc.draft || acc.doc

        {if(next == last, do: [], else: [next]), acc}
    end)
  end
end
