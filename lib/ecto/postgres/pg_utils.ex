defmodule Vtc.Ecto.Postgres.Utils do
  @moduledoc false

  alias Ecto.Migration

  @typedoc """
  Alias of String.t() that hints raw SQL text.
  """
  @type raw_sql() :: String.t()

  ## Exposes a macro for defining modules that will only be compiled if the caller
  ## has set `:vtc, Postrgrex, :include?` to `true` in their application config.

  @spec __using__(Keyword.t()) :: Macro.t()
  defmacro __using__(_) do
    quote do
      import Vtc.Ecto.Postgres.Utils, only: [defpgmodule: 2, when_pg_enabled: 1]

      require Vtc.Ecto.Postgres.Utils
    end
  end

  @doc """
  Wraps defmodule, conditionally declaring the module during compilation
  based on caller configuration.
  """
  @spec defpgmodule(module(), do: Macro.t()) :: Macro.t()
  defmacro defpgmodule(name, do: body) do
    if_pg_enabled(fn ->
      quote do
        defmodule unquote(name) do
          unquote(body)
        end
      end
    end)
  end

  @doc """
  Only executes if the calling application has Postgres types enabled.
  """
  @spec when_pg_enabled(do: Macro.t()) :: Macro.t()
  defmacro when_pg_enabled(do: body) do
    if_pg_enabled(fn ->
      quote do
        unquote(body)
      end
    end)
  end

  defp if_pg_enabled(action, otherwise \\ fn -> nil end) do
    if get_config(:include?, false) do
      :ok = enforce_dep(Ecto, :ecto)
      :ok = enforce_dep(Postgrex, :postgrex)

      action.()
    else
      otherwise.()
    end
  end

  @doc """
  Fetches a config for `:vtc, Postgrex`
  """
  @spec get_config(atom(), result) :: result when result: any()
  def get_config(opt, default), do: :vtc |> Application.get_env(Postgrex, []) |> Keyword.get(opt, default)

  @doc """
  Affirms that module from dep is present, throwing otherwise.
  """
  @spec enforce_dep(module(), atom()) :: :ok
  def enforce_dep(module, name) do
    if not Code.ensure_loaded?(module) do
      throw(
        ":vtc, Postgrex, `:include?` config is true, but `#{module}` module not found. Add `#{name}` to your dependencies"
      )
    end

    :ok
  end

  @doc """
  Run migrations, allowing callers to specigy
  """
  @spec run_migrations([(() -> {raw_sql(), raw_sql()} | :skip)], include: Keyword.t(), exclude: Keyword.t()) :: :ok
  def run_migrations(functions, opts) do
    include = Keyword.get(opts, :include, [])
    exclude = Keyword.get(opts, :exclude, [])

    Enum.each(functions, &run_migration_function(&1, include, exclude))
  end

  @spec run_migration_function((() -> {raw_sql(), raw_sql()} | :skip), [atom()], [atom()]) :: :ok
  defp run_migration_function(function, includes, excludes) do
    name = function |> Function.info() |> Keyword.fetch!(:name)

    commands = function.()
    included? = name in includes or includes == []
    excluded? = name in excludes

    if commands != :skip and included? and not excluded? do
      {up_command, down_command} = commands
      Migration.execute(up_command, down_command)
    end

    :ok
  end

  @typedoc """
  The possible classes of custom types.
  """
  @type type_class() :: :composite | :enum | :range

  @typedoc """
  Describes attributes that can go in the `AS` block for a type.

  Compisute type: `field: type` keyword list.

  Enum type: `value` list.

  Range type: `attr: value` keyword list.
  """
  @type type_attrs() :: Keyword.t(atom() | raw_sql()) | [atom() | String.t()]

  @doc """
  Creates a custom postgres type.

  ## Args

  - `name`: The name of the type

  - `type_class`: The type of type, if applicable. i.e., `:range`, `:enum`.
    Default: `:composite`.

  - `attrs`: Type attributes to go in the `AS` block.
  """
  @spec create_type(Macro.t(), type_class(), Macro.t()) :: Macro.t()
  defmacro create_type(name, type_class \\ :composite, attrs) do
    comment = create_comment_string(__CALLER__, :type)

    quote do
      unquote(__MODULE__).create_plpgsql_type_raw_sql(
        unquote(name),
        unquote(type_class),
        unquote(attrs),
        unquote(comment)
      )
    end
  end

  @doc false
  @spec create_plpgsql_type_raw_sql(atom(), type_class(), type_attrs(), String.t()) :: {raw_sql(), raw_sql()}
  def create_plpgsql_type_raw_sql(name, type_class, attrs, comment) do
    {
      create_type_raw_sql_up(name, type_class, attrs, comment),
      create_type_raw_sql_down(name)
    }
  end

  # Creates a custom type.
  #
  # Postgres docs: https://www.postgresql.org/docs/current/sql-createtype.html
  @spec create_type_raw_sql_up(atom(), type_class(), type_attrs(), String.t()) :: raw_sql()
  defp create_type_raw_sql_up(name, type_class, attrs, comment) do
    type_class_sql =
      case type_class do
        :composite -> ""
        type_class -> String.upcase("#{type_class} ")
      end

    attrs_sql =
      Enum.map_join(attrs, ",\n", fn
        {attr, value} -> if type_class == :range, do: "#{attr} = #{value}", else: "#{attr} #{value}"
        enum_attr -> "'#{enum_attr}'"
      end)

    """
    DO $$ BEGIN
      CREATE TYPE #{name} AS #{type_class_sql}(
        #{attrs_sql}
      );

      COMMENT ON
      TYPE #{name}
      IS '#{comment}';
    EXCEPTION WHEN duplicate_object
      THEN null;
    END $$;
    """
  end

  # Drops a custom type.
  #
  # Postgres docs: https://www.postgresql.org/docs/current/sql-droptype.html
  @spec create_type_raw_sql_down(atom()) :: raw_sql()
  defp create_type_raw_sql_down(name) do
    """
    DROP TYPE #{name};
    """
  end

  @typedoc """
  Options type for `plpgsql_add_function/2`
  """
  @type create_func_opts() :: [
          args: Keyword.t(atom()),
          returns: atom(),
          declares: Keyword.t(atom() | {atom(), raw_sql()}),
          body: raw_sql()
        ]

  @doc """
  Builds a [plpgsql](https://www.postgresql.org/docs/current/plpgsql.html) function,
  taking care of all the biolerplate.

  ## Args

  - `name`: The name of the function, including schema namespace.

  ## Options

  - `args`: The arguments the function takes and their types in a `arg: type` keyword
    list.

  - `returns`: The type the function returns.

  - `declares`: A `name: type` keyword list of variables that should be declared in the
    function's "DECLARES" block. Optionally can pass `name: {type, calculation}` to
    declare a short calculation to set the variable.

  - `body`: The function body.
  """
  @spec create_plpgsql_function(Macro.t(), Macro.t()) :: Macro.t()
  defmacro create_plpgsql_function(name, opts) do
    comment = create_comment_string(__CALLER__, :function)

    quote do
      opts = Keyword.put_new(unquote(opts), :comment, unquote(comment))
      unquote(__MODULE__).create_plpgsql_function_raw_sql(unquote(name), opts)
    end
  end

  @doc false
  @spec create_plpgsql_function_raw_sql(String.t(), create_func_opts()) :: {raw_sql(), raw_sql()}
  def create_plpgsql_function_raw_sql(name, opts) do
    {
      create_plpgsql_function_raw_sql_up(name, opts),
      create_plpgsql_function_raw_sql_down(name, opts)
    }
  end

  # Creates a pl/pgsql function.
  #
  # Postgres docs: https://www.postgresql.org/docs/current/plpgsql.html
  @spec create_plpgsql_function_raw_sql_up(String.t(), create_func_opts()) :: raw_sql()
  defp create_plpgsql_function_raw_sql_up(name, opts) do
    args = Keyword.get(opts, :args, [])
    returns = Keyword.fetch!(opts, :returns)
    declares = Keyword.get(opts, :declares, nil)
    body = Keyword.fetch!(opts, :body)
    comment = Keyword.fetch!(opts, :comment)

    cost = Keyword.get(opts, :cost, nil)
    cost_sql = if is_integer(cost), do: "COST #{cost}", else: ""

    args_sql = Enum.map_join(args, ", ", fn {arg, type} -> "#{arg} #{type}" end)
    types_sql = Enum.map_join(args, ", ", fn {_, type} -> "#{type}" end)

    declare =
      if is_nil(declares) do
        ""
      else
        vars =
          Enum.map_join(declares, fn
            {var, {type, value}} -> "#{var} #{type} := #{value};\n"
            {var, type} -> "#{var} #{type};\n"
          end)

        """
        DECLARE
        #{vars}
        """
      end

    comment_info_block = plpgsql_function_comment_info_block(args, returns)
    comment = comment <> comment_info_block

    """
    DO $wrapper$ BEGIN
      CREATE FUNCTION #{name}(#{args_sql})
        RETURNS #{returns}
        LANGUAGE plpgsql
        STRICT
        IMMUTABLE
        PARALLEL SAFE
        #{cost_sql}
      AS $func$
        #{declare}
        BEGIN
          #{body}
        END;
      $func$;

      COMMENT ON
      FUNCTION #{name}(#{types_sql})
      IS '#{comment}';

      EXCEPTION WHEN duplicate_function
        THEN null;
    END $wrapper$;
    """
  end

  # Creates formatted information to inject into the function comment.
  @spec plpgsql_function_comment_info_block(Keyword.t(atom()), atom()) :: String.t()
  defp plpgsql_function_comment_info_block(args, returns) do
    args_sql = Enum.map_join(args, ", \n", fn {arg, type} -> "- `#{arg}`: `#{type}`" end)
    returns_sql = "**Returns**: #{returns}"

    """
    ## Arguments

    #{args_sql}

    #{returns_sql}
    """
  end

  # Drops a pl/pgsql function.
  #
  # Postgres docs: https://www.postgresql.org/docs/current/sql-createfunction.html
  @spec create_plpgsql_function_raw_sql_down(String.t(), create_func_opts()) :: raw_sql()
  defp create_plpgsql_function_raw_sql_down(name, opts) do
    args = Keyword.get(opts, :args, [])
    args_sql = Enum.map_join(args, ", ", fn {_, type} -> "#{type}" end)

    """
    DROP FUNCTION #{name}(#{args_sql});
    """
  end

  @doc """
  Builds an SQL query for creating a new native operator.
  """
  @spec create_operator(Macro.t(), Macro.t(), Macro.t(), Macro.t(), Macro.t()) :: Macro.t()
  defmacro create_operator(name, left_type, right_type, func_name, opts \\ []) do
    comment = create_comment_string(__CALLER__, :operator)

    quote do
      opts = Keyword.put_new(unquote(opts), :comment, unquote(comment))

      unquote(__MODULE__).create_operator_raw_sql(
        unquote(name),
        unquote(left_type),
        unquote(right_type),
        unquote(func_name),
        opts
      )
    end
  end

  @doc false
  @spec create_operator_raw_sql(atom(), atom(), atom(), String.t(), commutator: atom(), negator: atom()) ::
          {raw_sql(), raw_sql()}
  def create_operator_raw_sql(name, left_type, right_type, func_name, opts) do
    {
      create_operator_raw_sql_up(name, left_type, right_type, func_name, opts),
      create_operator_raw_sql_down(name, left_type, right_type)
    }
  end

  # Creates a custom operator.
  #
  # Postgres docs: https://www.postgresql.org/docs/current/sql-dropoperator.html
  @spec create_operator_raw_sql_up(atom(), atom(), atom(), String.t(), commutator: atom(), negator: atom()) :: raw_sql()
  defp create_operator_raw_sql_up(name, left_type, right_type, func_name, opts) do
    commutator = Keyword.get(opts, :commutator)
    negator = Keyword.get(opts, :negator)
    comment = Keyword.get(opts, :comment)

    commutator_sql = if is_nil(commutator), do: "", else: "COMMUTATOR = #{commutator},"
    negator_sql = if is_nil(negator), do: "", else: "NEGATOR = #{negator},"

    """
    DO $wrapper$ BEGIN
      CREATE OPERATOR #{name} (
        LEFTARG = #{left_type},
        RIGHTARG = #{right_type},
        #{commutator_sql}
        #{negator_sql}
        FUNCTION = #{func_name}
      );

      COMMENT ON
      OPERATOR #{name} (#{left_type}, #{right_type})
      IS '#{comment}';

    EXCEPTION WHEN duplicate_function
      THEN null;

    END $wrapper$;
    """
  end

  # Drops a custom operator.
  #
  # Postgres docs: https://www.postgresql.org/docs/current/sql-dropoperator.html
  @spec create_operator_raw_sql_down(atom(), atom(), atom()) :: raw_sql()
  defp create_operator_raw_sql_down(name, left_type, right_type) do
    """
    DROP OPERATOR #{name} (#{left_type}, #{right_type});
    """
  end

  @doc """
  Builds an SQL query for creating a new native CAST
  """
  @spec create_operator_class(atom(), atom(), atom(), Macro.t(), Macro.t()) :: Macro.t()
  defmacro create_operator_class(name, type, index_type, operators, functions) do
    comment = create_comment_string(__CALLER__, :operator_class)

    quote do
      unquote(__MODULE__).create_operator_class_raw_sql(
        unquote(name),
        unquote(type),
        unquote(index_type),
        unquote(operators),
        unquote(functions),
        unquote(comment)
      )
    end
  end

  @doc false
  @spec create_operator_class_raw_sql(
          atom(),
          atom(),
          atom(),
          Keyword.t(pos_integer()),
          [{String.t(), pos_integer()}],
          String.t()
        ) :: {raw_sql(), raw_sql()}
  def create_operator_class_raw_sql(name, type, index_type, operators, functions, comment) do
    {
      create_operator_class_raw_sql_up(name, type, index_type, operators, functions, comment),
      create_operator_class_raw_sql_down(name, index_type)
    }
  end

  # Create a custom operator class.
  #
  # Postgres docs: https://www.postgresql.org/docs/current/sql-createopclass.html
  @spec create_operator_class_raw_sql_up(
          atom(),
          atom(),
          atom(),
          Keyword.t(pos_integer()),
          [{String.t(), pos_integer()}],
          String.t()
        ) :: raw_sql()
  defp create_operator_class_raw_sql_up(name, type, index_type, operators, functions, comment) do
    operators_sql_list =
      Enum.map(operators, fn {operator, index} ->
        "operator #{index} #{operator}"
      end)

    functions_sql_list =
      Enum.map(functions, fn {function, index} ->
        "function #{index} #{function}(#{type}, #{type})"
      end)

    sql_list = operators_sql_list |> Enum.concat(functions_sql_list) |> Enum.join(",")

    """
    DO $wrapper$ BEGIN
      CREATE OPERATOR CLASS #{name}
      DEFAULT FOR TYPE #{type} USING #{index_type} AS
        #{sql_list};

      COMMENT ON
      OPERATOR CLASS #{name} USING #{index_type}
      IS '#{comment}';
    EXCEPTION WHEN duplicate_object
      THEN null;
    END $wrapper$;
    """
  end

  # Drops a custom operator class.
  #
  # Postgres docs: https://www.postgresql.org/docs/current/sql-dropopclass.html
  @spec create_operator_class_raw_sql_down(atom(), atom()) :: raw_sql()
  defp create_operator_class_raw_sql_down(name, index_type) do
    """
    DROP OPERATOR CLASS #{name} USING #{index_type};
    """
  end

  @doc """
  Builds an SQL query for creating a new native CAST
  """
  @spec create_cast(atom(), atom(), Macro.t(), Macro.t()) :: Macro.t()
  defmacro create_cast(left_type, right_type, func_name, opts \\ []) do
    comment = create_comment_string(__CALLER__, :cast)

    quote do
      unquote(__MODULE__).create_cast_raw_sql(
        unquote(left_type),
        unquote(right_type),
        unquote(func_name),
        unquote(comment),
        unquote(opts)
      )
    end
  end

  @doc false
  @spec create_cast_raw_sql(atom(), atom(), atom() | String.t(), String.t(), implicit: boolean()) ::
          {raw_sql(), raw_sql()}
  def create_cast_raw_sql(left_type, right_type, func_name, comment, opts) do
    {
      create_cast_raw_sql_up(left_type, right_type, func_name, comment, opts),
      create_cast_raw_sql_down(left_type, right_type)
    }
  end

  # Creates a custom operator cast.
  #
  # Postgres docs: https://www.postgresql.org/docs/current/sql-createcast.html
  @spec create_cast_raw_sql_up(atom(), atom(), atom() | String.t(), String.t(), implicit: boolean()) :: raw_sql()
  defp create_cast_raw_sql_up(left_type, right_type, func_name, comment, opts) do
    implicit = if Keyword.get(opts, :implicit, false), do: "AS IMPLICIT", else: ""

    """
    DO $wrapper$ BEGIN
      CREATE CAST (#{left_type} AS #{right_type})
      WITH FUNCTION #{func_name}(#{left_type})
      #{implicit};

      COMMENT ON
      CAST (#{left_type} AS #{right_type})
      IS '#{comment}';
    EXCEPTION WHEN duplicate_object
      THEN null;
    END $wrapper$;
    """
  end

  # Drops a custom operator cast.
  #
  # Postgres docs: https://www.postgresql.org/docs/current/sql-dropcast.html
  @spec create_cast_raw_sql_down(atom(), atom()) :: raw_sql()
  defp create_cast_raw_sql_down(left_type, right_type) do
    """
    DROP CAST (#{left_type} AS #{right_type});
    """
  end

  # Builds a comment string based on the calling function's docsting.
  @spec create_comment_string(Macro.Env.t(), :type | :function | :cast | :operator | :operator_class) :: String.t()
  defp create_comment_string(env, object_type) do
    {_, doc_string} = Module.get_attribute(env.module, :doc)
    doc_string = String.replace(doc_string, "'", "''")

    {func_name, func_arity} = env.function

    object_type = object_type |> Atom.to_string() |> String.capitalize()
    url = "https://hexdocs.pm/vtc/#{env.module}.html##{func_name}/#{func_arity}"

    """
    Created by Vtc, a video timecode library for Elixir
    https://hexdocs.pm/vtc

    #{object_type} documentation:
    #{url}

    #{doc_string}
    """
  end

  @doc """
  Creates a public and private schema for a type based on the repo's confguration.
  """
  @spec create_type_schema(atom()) :: {raw_sql(), raw_sql()} | :skip
  def create_type_schema(type_name) do
    schema_name = get_type_config(Migration.repo(), type_name, :functions_schema, :public)

    if schema_name != :public do
      {
        create_type_schema_up(schema_name),
        create_type_schema_down(schema_name)
      }
    else
      :skip
    end
  end

  # Creates a type's schema.
  #
  # Postgres docs: https://www.postgresql.org/docs/current/sql-createschema.html
  @spec create_type_schema_up(atom()) :: raw_sql() | :skip
  defp create_type_schema_up(schema_name) do
    """
    DO $$ BEGIN
    CREATE SCHEMA #{schema_name};
    EXCEPTION WHEN duplicate_schema
      THEN null;
    END $$;
    """
  end

  # Drops a type's schema.
  #
  # Postgres docs: https://www.postgresql.org/docs/current/sql-dropschema.html
  @spec create_type_schema_down(atom()) :: raw_sql() | :skip
  defp create_type_schema_down(schema_name) do
    """
    DROP SCHEMA #{schema_name};
    """
  end

  @doc """
  Returns a configuration option for a specific vtc Postgres type and Repo.
  """
  @spec get_type_config(Ecto.Repo.t(), atom(), atom(), Keyword.value()) :: Keyword.value()
  def get_type_config(repo, type_name, opt, default),
    do: repo.config() |> Keyword.get(:vtc, []) |> Keyword.get(type_name, []) |> Keyword.get(opt, default)

  @doc """
  Returns a the public function prefix for a specific vtc Postgres type and Repo.
  """
  @spec type_function_prefix(Ecto.Repo.t(), atom()) :: String.t()
  def type_function_prefix(repo, type_name), do: calculate_prefix(repo, type_name, :functions_schema)

  @spec type_private_function_prefix(Ecto.Repo.t(), atom()) :: String.t()
  def type_private_function_prefix(repo, type_name) do
    prefix = type_function_prefix(repo, type_name)
    prefix = String.trim_trailing(prefix, "_")
    "#{prefix}__private__"
  end

  # Calculate a function prefix for a specific schema and vtc postgres type based on the
  # Repo configuration.
  @spec calculate_prefix(Ecto.Repo.t(), atom(), atom()) :: String.t()
  defp calculate_prefix(repo, type_name, schema_config_opt) do
    functions_schema = get_type_config(repo, type_name, schema_config_opt, :public)
    custom_prefix = get_type_config(repo, type_name, :functions_prefix, "")

    functions_prefix =
      cond do
        functions_schema == :public and custom_prefix == "" ->
          (type_name |> Atom.to_string() |> String.replace_prefix("pg_", "")) <> "_"

        custom_prefix != "" ->
          "#{custom_prefix}"

        true ->
          ""
      end

    "#{functions_schema}.#{functions_prefix}"
  end
end
