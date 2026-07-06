require "benchmark"
require "sqlite3"

require "./ext/sqlite3"

module Ktistec
  # Connection parameters appended to the SQLite connection URI.
  #
  # crystal-db and crystal-sqlite3 both read configuration from the
  # URI query string: pool options are parsed by `DB::Pool::Options`
  # and connection options by `DB::Connection::Options`, while the
  # sqlite3 driver turns its recognized parameters into PRAGMAs that
  # it executes on every new connection (see
  # `SQLite3::Connection::Options#pragma_statement`). Everything here
  # therefore applies uniformly to each connection the pool opens.
  #
  # prepared_statements_cache=false
  #
  #   crystal-db caches every prepared statement per connection,
  #   keyed by the literal SQL text, in an unbounded Hash with no
  #   eviction (DB::StringKeyCache). Connections here live for the
  #   life of the process, so any code path that interpolates
  #   runtime-varying values into SQL text (rather than binding them
  #   with `?`) mints a new cache entry per distinct value --
  #   unbounded heap growth. This exact mechanism caused the memory
  #   leaks fixed in v2.0.0-4 and v2.0.0-6 ("Fix a memory leak caused
  #   by string interpolation in query string construction"); those
  #   fixes parameterized the two known offending call sites but left
  #   the cache itself unbounded, so any regression reintroduces the
  #   leak silently. Disabling the cache trades a per-query re-parse
  #   (cheap for SQLite's parser, and this workload is I/O-bound) for
  #   the elimination of the entire failure class. See FIXES.md #1.
  #
  DB_PARAMS = [
    "prepared_statements_cache=false",
  ].join('&')

  @@db_uri : String = begin
    if (db = ENV["KTISTEC_DB"]?)
      # KTISTEC_DB may itself carry query parameters; join accordingly
      "sqlite3://#{db}#{db.includes?('?') ? '&' : '?'}#{DB_PARAMS}"
    elsif ENV["KEMAL_ENV"]? == "production"
      "sqlite3://#{File.expand_path("~/.ktistec.db", home: true)}?#{DB_PARAMS}"
    else
      "sqlite3://ktistec.db?#{DB_PARAMS}"
    end
  end

  @@database : DB::Database = begin
    unless File.exists?(db_file)
      DB.open(db_uri) do |db|
        File.read(File.join(Dir.current, "etc", "database", "schema.sql")).split(';').each do |command|
          db.exec(command) unless command.blank?
        end
        # sqlite only recently replaced (insecure) rc4 with chacha20
        # for random number generation. to avoid problems with older
        # sqlite versions in the field, use the following instead of
        # hex(randomblob) to generate the secret key.
        # see: https://sqlite.org/src/info/084d8776fa95c754
        db.exec "INSERT INTO options (key, value) VALUES (?, ?)", "secret_key", Random::Secure.hex(64)
      end
    end
    DB.open(db_uri)
  end

  @@secret_key : String = begin
    database.scalar("SELECT value FROM options WHERE key = ?", "secret_key").as(String)
  end

  class_getter db_uri, database, secret_key

  def self.db_file
    db_uri.split("//").last.split("?").first
  end

  # Database utilities.
  #
  module Database
    @@migrations = {} of Version => Definition

    # Returns all defined migrations in no particular order.
    #
    def self.all_migrations
      @@migrations
    end

    # Returns all versions in sorted order.
    #
    def self.all_versions
      @@migrations.keys.sort!
    end

    # Returns all applied versions.
    #
    def self.all_applied_versions
      Ktistec.database.query_all("SELECT id FROM migrations", as: Int)
    end

    # Returns all pending versions.
    #
    def self.all_pending_versions
      all_versions - all_applied_versions
    end

    # Finds migration by version.
    #
    def self.find_migration(version)
      @@migrations[version]
    end

    # Performs an operation on a migration.
    #
    def self.do_operation(operation, version)
      migration = find_migration(version)
      case operation
      when :create
        if all_applied_versions.includes?(version)
          "#{migration.name}: is already applied"
        else
          Ktistec.database.exec("INSERT INTO migrations VALUES (?, ?)", version, migration.name)
          "#{migration.name}: created but not applied"
        end
      when :apply
        if all_applied_versions.includes?(version)
          "#{migration.name}: is already applied"
        elsif (up = migration.up).nil?
          "#{migration.name}: is not defined"
        else
          time = Benchmark.measure { up.call(Ktistec.database) }
          Ktistec.database.exec("INSERT INTO migrations VALUES (?, ?)", version, migration.name)
          "#{migration.name}: applied in %.4fs" % time.real
        end
      when :destroy
        if all_pending_versions.includes?(version)
          "#{migration.name}: is already reverted"
        else
          Ktistec.database.exec("DELETE FROM migrations WHERE id = ?", version)
          "#{migration.name}: destroyed but not reverted"
        end
      when :revert
        if all_pending_versions.includes?(version)
          "#{migration.name}: is already reverted"
        elsif (down = migration.down).nil?
          "#{migration.name}: is not defined"
        else
          time = Benchmark.measure { down.call(Ktistec.database) }
          Ktistec.database.exec("DELETE FROM migrations WHERE id = ?", version)
          "#{migration.name}: reverted in %.4fs" % time.real
        end
      else
        raise "invalid operation: #{operation}"
      end
    end

    # Common interface for all migrations.
    #
    module Migration
      # Returns the table's columns.
      #
      def columns(table)
        schema = Ktistec.database.scalar("SELECT sql FROM sqlite_master WHERE type = 'table' AND tbl_name = ?", table).as(String)
        schema[/(?<=\().*(?=\))/m].split(",").map(&.strip)
      end

      # Returns the table's indexes.
      #
      def indexes(table)
        Ktistec.database.query_all("SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ?", table, as: String)
      end

      # Adds a column to the table.
      #
      def add_column(table, column, definition, index = nil)
        Ktistec.database.exec <<-STR
          ALTER TABLE #{table} ADD COLUMN #{column} #{definition}
        STR
        if index
          Ktistec.database.exec <<-STR
            CREATE INDEX idx_#{table}_#{column} ON #{table} (#{column} #{index})
          STR
        end
      end

      # Removes a column from the table.
      #
      def remove_column(table, column)
        indexes(table).each do |index|
          if index =~ /INDEX (?<index>[^\s]+) ON (?<table>[^\s]+) \((?<columns>.*)\)/i
            index, table, columns = $~["index"], $~["table"], $~["columns"]
            next unless columns.split(",").map(&.split.first).includes?(column)
            Ktistec.database.exec <<-STR
              DROP INDEX #{index}
            STR
          end
        end
        Ktistec.database.exec <<-STR
          ALTER TABLE #{table} DROP COLUMN #{column}
        STR
      end

      # Applies the migration.
      #
      def up(filename = __FILE__, &proc : Operation)
        if filename.split("/").last =~ PATTERN
          Ktistec::Database.all_migrations.tap do |all_migrations|
            all_migrations[$1.to_i64] =
              if (definition = all_migrations[$1.to_i64]?)
                definition.copy_with(up: proc)
              else
                Definition.new(name: $2, up: proc)
              end
          end
        end
      end

      # Reverts the migration.
      #
      def down(filename = __FILE__, &proc : Operation)
        if filename.split("/").last =~ PATTERN
          Ktistec::Database.all_migrations.tap do |all_migrations|
            all_migrations[$1.to_i64] =
              if (definition = all_migrations[$1.to_i64]?)
                definition.copy_with(down: proc)
              else
                Definition.new(name: $2, down: proc)
              end
          end
        end
      end

      private PATTERN = /^([0-9]+)-(.+).cr$/
    end

    private alias Version = Int64
    private alias Operation = Proc(DB::Database, Nil)

    private record(
      Definition,
      name : String,
      up : Operation? = nil,
      down : Operation? = nil,
    )
  end
end

require "../database/migrations/**" # ameba:disable Ktistec/NoRequireGlob
