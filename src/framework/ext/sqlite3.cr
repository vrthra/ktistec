require "json"
require "xml"
require "sqlite3"

require "../../ktistec/constants"

module DB
  abstract class Statement
    protected def emit_log(args : Enumerable)
      # override the library definition of `emit_log` to silence it.
    end
  end

  # Bound the per-connection prepared-statement cache.
  #
  # crystal-db's StringKeyCache grows without limit: every distinct
  # SQL text ever executed on a connection stays cached (statement
  # handle and all) until the connection closes, and connections here
  # live for the life of the process. Any code path that interpolates
  # runtime-varying values into SQL text instead of binding them with
  # `?` therefore grows the heap without bound -- the mechanism behind
  # the memory leaks fixed in v2.0.0-4 (00b6395a) and v2.0.0-6
  # (d87000a9). Those fixes parameterized the known offending call
  # sites but left the cache unbounded, so any future regression
  # reintroduces the leak silently.
  #
  # The driver's `prepared_statements_cache=false` option is not a
  # usable alternative: on the `Database#exec` path uncached
  # statements are never finalized (`PoolPreparedStatement` builds
  # via `conn.prepared.build`, which deliberately skips `auto_close`,
  # and nothing else closes them), so disabling the cache leaks
  # native sqlite3_stmt handles and makes `sqlite3_close` fail with
  # "unable to close due to unfinalized statements".
  #
  # Bounding the cache keeps the fast path (the application's fixed
  # repertoire of queries is far smaller than the cap, so steady-state
  # hit rate is unaffected) while capping the damage of any
  # interpolated-SQL regression at MAX_ENTRIES statements. Eviction is
  # insertion-order (Crystal Hashes preserve it): a hot statement that
  # gets evicted is simply re-prepared and re-enters the cache.
  #
  # Closing an evicted statement is safe here: a connection executes
  # one operation at a time (an open ResultSet keeps the connection
  # checked out, and nested queries check out a different connection
  # from the pool), so the eviction victim -- necessarily not the
  # statement being fetched -- cannot be mid-execution. `close` is
  # idempotent (DB::Disposable), and PoolStatement holds no statement
  # references across executions, so a closed statement is rebuilt on
  # next use.
  #
  class StringKeyCache(T)
    MAX_ENTRIES = 512

    def fetch(key : String, &) : T
      value = @cache.fetch(key, nil)
      unless value
        while @cache.size >= MAX_ENTRIES
          _, evicted = @cache.shift
          evicted.close if evicted.responds_to?(:close)
        end
        value = @cache[key] = yield
      end
      value
    end
  end
end

private alias Supported = JSON::Serializable | Array(JSON::Serializable) | Hash(String, String) | Hash(String, JSON::Any) | Array(String)

class SQLite3::ResultSet
  {% for type in Supported.union_types %}
    def read(type : {{type}}.class)
      (json = read(String)) ; type.from_json(json)
    end
    def read(type : {{type}}?.class)
      (json = read(String?)) ? type.from_json(json) : nil
    end
  {% end %}
end

class SQLite3::Statement
  {% for type in Supported.union_types %}
    private def bind_arg(index, value : {{type}})
      bind_arg(index, value.to_json)
    end
  {% end %}
end

lib LibSQLite3
  fun config = sqlite3_config(Int32, ...) : Code
  fun memory_used = sqlite3_memory_used : Int64
  fun result_text = sqlite3_result_text(SQLite3Context, UInt8*, Int32, Void*) : Nil
  fun test_control = sqlite3_test_control(Int32, ...) : Int32
  fun version_number = sqlite3_libversion_number : Int32
  fun version = sqlite3_libversion : UInt8*
end

module Ktistec
  module SQLite3
    SQLITE_CONFIG_MEMSTATUS       =  9_i32
    SQLITE_TESTCTRL_OPTIMIZATIONS = 15_i32

    if (code = LibSQLite3.config(SQLITE_CONFIG_MEMSTATUS, 1_i32)) != LibSQLite3::Code::OKAY
      Log.warn { "#{code}: couldn't set SQLITE_CONFIG_MEMSTATUS: this is not fatal" }
    end

    TRANSIENT = Pointer(Void*).new(-1.to_u64!)

    private def self.strip_fn(context : LibSQLite3::SQLite3Context, argc : Int32, argv : LibSQLite3::SQLite3Value*)
      txt = LibSQLite3.value_text(argv[0])
      str = String.new(txt)
      unless str.blank?
        str = XML.parse_html(str, Ktistec::Constants::HTML_PARSER_OPTIONS).xpath_string("string()")
      end
      LibSQLite3.result_text(context, str, str.bytesize, TRANSIENT)
      nil
    end

    UTF8          =           1
    DETERMINISTIC = 0x000000800
    DIRECTONLY    = 0x000080000

    Ktistec.database.setup_connection do |connection|
      LibSQLite3.create_function(connection, "strip", 1, UTF8 | DETERMINISTIC | DIRECTONLY, nil, ->strip_fn, nil, nil)

      # Disable faulty Bloom filter optimization.
      # See: https://sqlite.org/forum/forumpost/56de336385
      if LibSQLite3.version_number.in?(3039000...3041000)
        LibSQLite3.test_control(Ktistec::SQLite3::SQLITE_TESTCTRL_OPTIMIZATIONS, connection, 0x080000_i32)
      end
    end

    # Features of the linked SQLite3 library.
    #
    record Features, version : String, json : Bool, stat4 : Bool, fts5 : Bool, icu : Bool do
      include JSON::Serializable
    end

    class_property! features : Features

    # Probes the linked SQLite3 library for features.
    #
    # Probes test behavior where possible because compile options are
    # interpreted differently across versions and may be omitted from
    # the build entirely.
    #
    # STAT4 can only be detected via compile options or by its effect
    # on `ANALYZE` (only STAT4 builds populate `sqlite_stat4`), so this
    # must run after `ANALYZE`.
    #
    def self.probe_features
      self.features = Features.new(
        version: String.new(LibSQLite3.version),
        json: probe?("SELECT json_valid('{}')"),
        stat4: probe?("SELECT sqlite_compileoption_used('ENABLE_STAT4')") || probe?("SELECT EXISTS (SELECT 1 FROM sqlite_stat4)"),
        fts5: probe?("SELECT EXISTS (SELECT 1 FROM pragma_module_list WHERE name = 'fts5')"),
        icu: probe?("SELECT upper('é') = 'É'"),
      )
    end

    def self.probe?(query)
      Ktistec.database.scalar(query) == 1
    rescue ::SQLite3::Exception | DB::Error
      false
    end

    LibSQLite3.version.tap do |version|
      version = String.new(version)
      if LibSQLite3.version_number < 3035000
        STDERR.puts "Ktistec requires SQLite3 version 3.35.0 or later (linked version is #{version})."
        exit -1
      elsif LibSQLite3.version_number.in?(3039000...3041000)
        STDERR.puts "Disabling Bloom filter optimization for SQLite3 version #{version}."
      end
    end
  end
end
