defmodule HexWeb.Utils do
  @moduledoc """
  Assorted utility functions.
  """

  import Ecto.Query, only: [from: 2]
  require Logger

  def maybe(nil, _fun), do: nil
  def maybe(item, fun), do: fun.(item)

  def log_error(kind, error, stacktrace) do
    Logger.error Exception.format_banner(kind, error, stacktrace) <> "\n" <>
                 Exception.format_stacktrace(stacktrace)
  end

  def yesterday do
    {today, _time} = :calendar.universal_time()
    today_days = :calendar.date_to_gregorian_days(today)
    :calendar.gregorian_days_to_date(today_days - 1)
  end

  def safe_to_atom(binary, allowed) do
    if binary in allowed, do: String.to_atom(binary)
  end

  def safe_page(page, _count, _per_page) when page < 1,
    do: 1
  def safe_page(page, count, per_page) when page > div(count, per_page) + 1,
    do: div(count, per_page) + 1
  def safe_page(page, _count, _per_page),
    do: page

  def safe_int(nil), do: nil

  def safe_int(string) do
    case Integer.parse(string) do
      {int, ""} -> int
      _         -> nil
    end
  end

  def safe_search(nil), do: nil

  def safe_search(string) do
    string
    |> String.replace(~r/\//u, " ")
    |> String.replace(~r/[^\w\s]/u, "")
    |> String.strip
  end

  defp diff(a, b) do
    {days, time} = :calendar.time_difference(a, b)
    :calendar.time_to_seconds(time) - (days * 24 * 60 * 60)
  end

  @doc """
  Determine if a given timestamp is less than a day (86400 seconds) old
  """
  def within_last_day(nil), do: false
  def within_last_day(a) do
    diff = diff(Ecto.DateTime.to_erl(a),
                :calendar.universal_time)

    diff < (24 * 60 * 60)
  end

  def etag(nil), do: nil
  def etag([]),  do: nil

  def etag(models) do
    list = Enum.map(List.wrap(models), fn model ->
      [model.__struct__, model.id, model.updated_at]
    end)

    binary = :erlang.term_to_binary(list)
    :crypto.hash(:md5, binary)
    |> Base.encode16(case: :lower)
  end

  def last_modified(nil), do: nil
  def last_modified([]),  do: nil

  def last_modified(models) do
    list = Enum.map(List.wrap(models), fn model ->
      Ecto.DateTime.to_erl(model.updated_at)
    end)

    Enum.max(list)
  end

  def binarify(binary) when is_binary(binary),
    do: binary
  def binarify(number) when is_number(number),
    do: number
  def binarify(atom) when is_nil(atom) or is_boolean(atom),
    do: atom
  def binarify(atom) when is_atom(atom),
    do: Atom.to_string(atom)
  def binarify(list) when is_list(list),
    do: for(elem <- list, do: binarify(elem))
  def binarify(%Version{} = version),
    do: to_string(version)
  def binarify(%Ecto.DateTime{} = dt),
    do: Ecto.DateTime.to_iso8601(dt)
  def binarify(%{__struct__: atom}) when is_atom(atom),
    do: raise "not able to binarify %#{inspect atom}{}"
  def binarify(map) when is_map(map),
    do: for(elem <- map, into: %{}, do: binarify(elem))
  def binarify(tuple) when is_tuple(tuple),
    do: for(elem <- Tuple.to_list(tuple), do: binarify(elem)) |> List.to_tuple

  @doc """
  Returns a url to a resource on the CDN from a list of path components.
  """
  @spec cdn_url([String.t] | String.t) :: String.t
  def cdn_url(path) do
    Application.get_env(:hex_web, :cdn_url) <> "/" <> Path.join(List.wrap(path))
  end

  @doc """
  Returns a url to a resource on the docs site from a list of path components.
  """
  @spec docs_url(HexWeb.Package.t, HexWeb.Release.t) :: String.t
  @spec docs_url([String.t] | String.t) :: String.t
  def docs_url(package, release) do
    docs_url([package.name, to_string(release.version)])
  end
  def docs_url(path) do
    Application.get_env(:hex_web, :docs_url) <> "/" <> Path.join(List.wrap(path)) <> "/"
  end

  @doc """
  Returns a url to the documentation tarball in the Amazon S3 Hex.pm bucket.
  """
  @spec docs_tarball_url(HexWeb.Package.t, HexWeb.Release.t) :: String.t
  def docs_tarball_url(package, release) do
    s3      = Application.get_env(:hex_web, :s3_url)
    bucket  = Application.get_env(:hex_web, :s3_bucket)
    package = package.name
    version = to_string(release.version)
    "#{s3}/#{bucket}/docs/#{package}-#{version}.tar.gz"
  end

  @doc """
  Converts an ecto datetime record to ISO 8601 format.
  """
  @spec to_iso8601(Ecto.DateTime.t) :: String.t
  def to_iso8601(dt) do
    list = [dt.year, dt.month, dt.day, dt.hour, dt.min, dt.sec]
    :io_lib.format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", list)
    |> IO.iodata_to_binary
  end

  @doc """
  A regex parsing out the version and format at the end of a media type.
  '.version+format'
  """
  @spec vendor_regex() :: Regex.t
  def vendor_regex do
    ~r/^
        (?:\.(?<version>[^\+]+))?
        (?:\+(?<format>.*))?
        $/x
  end

  def paginate(query, page, count) when is_integer(page) and page > 0 do
    offset = (page - 1) * count
    from(var in query,
         offset: ^offset,
         limit: ^count)
  end

  def paginate(query, _page, count) do
    paginate(query, 1, count)
  end

  def shell(cmd) do
    IO.puts("$ " <> cmd)
    stream = IO.binstream(:standard_io, :line)
    result = Porcelain.shell(cmd, out: stream, err: :out)
    result.status
  end

  @publish_timeout 5 * 60 * 1000

  if Mix.env in [:test, :hex] do
    def task(fun, success, failure) do
      try do
        fun.()
      catch
        kind, error ->
          stack = System.stacktrace
          failure.({kind, error})
          :erlang.raise kind, error, stack
      else
        _ ->
          success.()
      end
    end
  else
    def task(fun, success, failure) do
      Task.Supervisor.start_child(HexWeb.PublishTasks, fn ->
        {:ok, pid} = Task.Supervisor.start_child(HexWeb.PublishTasks, fun)
        ref        = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :noproc] ->
            success.()
          {:DOWN, ^ref, :process, ^pid, reason} ->
            failure.(reason)
        after
          @publish_timeout ->
            Task.Supervisor.terminate_child(HexWeb.PublishTasks, pid)
            failure.(:timeout)
        end
      end)
    end
  end

  def sign(file, key) do
    [entry | _ ] = :public_key.pem_decode(key)
    key = :public_key.pem_entry_decode(entry)

    :public_key.sign(file, :sha512, key)
    |> Base.encode16(case: :lower)
  end

  def verify(file, signature, key) do
    [entry | _] = :public_key.pem_decode(key)
    key         = :public_key.pem_entry_decode(entry)
    signature   = Base.decode16!(signature, case: :lower)

    :public_key.verify(file, :sha512, signature, key)
  end

  def parse_ip("-") do
    nil
  end
  def parse_ip(ip) do
    parts = String.split(ip, ".") |> Enum.map(&String.to_integer/1)
    for part <- parts, into: <<>>, do: <<part>>
  end

  defmacro defdispatch({function, _, args}, to: target) do
    quote do
      def unquote(function)(unquote_splicing(args)) do
        unquote(target).unquote(function)(unquote_splicing(args))
      end
    end
  end
end
