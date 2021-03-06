%%% -------------------------------------------------------------------
%%% File    : hordad_lib.erl
%%% Author  : Max E. Kuznecov <mek@mek.uz.ua>
%%% Description: Hordad library module
%%%
%%% Created : 2010-01-04 by Max E. Kuznecov <mek@mek.uz.ua>
%%% -------------------------------------------------------------------

-module(hordad_lib).

-include("lib_const.hrl").

-export([get_system_base/0,
         get_log_base/0,
         get_conf_dir/0,
         get_conf_file/1,
         get_db_dir/0,
         get_ssl_dir/0,
         get_file/2,
         datetime/1,
         build_child/1,
         getv/2,
         getv/3,
         setv/3,
         ensure_started/1
        ]).

%% @doc Get system base dir
get_system_base() ->
    {ok, [[SystemBase]]} = init:get_argument(hordad_system_base),

    SystemBase.

%% @doc Get log base dir
get_log_base() ->
    {ok, [[LogBase]]} = init:get_argument(hordad_log_base),

    LogBase.

%% @doc Get full path to configuration directory
-spec(get_conf_dir() -> string()).

get_conf_dir() ->
    filename:join([get_system_base(), ?CONST_CONF_SUBDIR]).

%% @doc Get full path to db directory
-spec(get_db_dir() -> string()).

get_db_dir() ->
    filename:join([get_system_base(), ?CONST_DB_SUBDIR]).

%% @doc Get full path to ssl directory
-spec(get_ssl_dir() -> string()).

get_ssl_dir() ->
    filename:join([get_system_base(), ?CONST_SSL_SUBDIR]).

%% @doc Get full path to file
-type(subdir() :: conf | db | log | ssl).
-spec(get_file(subdir(), string()) -> string()).

get_file(conf, File) ->
    filename:join([get_conf_dir(), File]);
get_file(db, File) ->
    filename:join([get_db_dir(), File]);
get_file(log, File) ->
    filename:join([get_log_base(), File]);
get_file(ssl, File) ->
    filename:join([get_ssl_dir(), File]).

%% @doc Get full path to configuration file
-type(conf_file_name() :: lcf).
-spec(get_conf_file(conf_file_name()) -> {ok, string()} | invalid).

get_conf_file(lcf) ->
    % Check for overriding env var
    case application:get_env(hordad_lcf, conf) of
        {ok, Path} ->
            {ok, Path};
        undefined ->
            {ok, filename:join([get_conf_dir(), ?CONST_CONF_LCF])}
    end;
get_conf_file(_) ->
    invalid.

%% @doc Format time
-spec(datetime(local | utc) -> string()).

datetime(local) ->
    httpd_util:rfc1123_date(erlang:localtime());
datetime(utc) ->
    httpd_util:rfc1123_date(erlang:universaltime()).

%% @doc Build supervisor child specification
-type(child_spec() :: {Id::any(),
                       StartFunc :: tuple(),
                       Restart :: atom(),
                       Shutdown :: atom() | integer(),
                       Type :: atom(),
                       Modules :: [atom()]}).

-spec(build_child(atom()) -> [child_spec()]).

build_child(App) ->
    Sup = list_to_atom(atom_to_list(App) ++ "_sup"),
    {App, {Sup, start_link, []}, permanent, 2000, worker, [App]}.

%% @doc Wrapper for proplists:get_value/2

getv(Key, List) when is_list(List) ->
    proplists:get_value(Key, List).

%% @doc Wrapper for proplists:get_value/3

getv(Key, List, Default) when is_list(List) ->
    proplists:get_value(Key, List, Default).

%% @doc Insert key/value pair into proplist, replaces existing one
setv(Key, Value, List) ->
    [{Key, Value} | proplists:delete(Key, List)].

%% @doc Check if application is started and start it otherwise
-spec(ensure_started(atom()) ->
             {ok, running} | {ok, started} | {error, any()}).

ensure_started(App) ->
    Running = [A || {A, _, _} <- application:which_applications()],

    case lists:member(App, Running) of
        true ->
            {ok, running};
        false ->
            case application:start(App) of
                ok ->
                    {ok, started};
                {error, _}=E ->
                    E
            end
    end.
