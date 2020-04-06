%%%-------------------------------------------------------------------
%%% @copyright (C) 2020, Maxim Fedorov <maximfca@mail.com>
%%% @doc
%%% Command line parser, made with hierarchy of commands in mind.
%%%
%%% Inspired by Python argparse library.
%%% Known incompatibilities:
%%%  * boolean flag (option), automatically using {store, true}
%%%  * all positional arguments are required by default (even 'maybe')
%%%  * first-class (sub) commands, slightly differently from argparse
%%%
%%% Commands vs. positional arguments: command always takes precedence
%%%  over positional argument.
%%% Commands form exclusive groups, e.g. only one command can
%%%  be followed at a time.
%%%
%%% Kinds of arguments supported:
%%%  * command (priority positional argument) : ectl {crawler|reader|writer}
%%%  * command, and sub-command:                ectl crawler {start|stop|check}
%%%
%%%  * positional argument (required):          ectl <arg1> <arg2>
%%%  * positional argument (with default):      ectl [<arg1>]
%%%
%%%  * boolean flag:              ectl [-rf]
%%%  * required flag:             ectl -r
%%%  * short optional argument:   ectl [-i <int>]
%%%  * short optional:            ectl [-i [<int>]]
%%%  * required short option:     ectl -i <int>
%%%  * long option flag:          ectl [--foo]
%%%  * long optional argument:    ectl [--foo <arg>]
%%%  * required long:             ectl --foo <arg>
%%%  * list of arguments:         ectl <arg>, ...
%%%
%%% Help conventions follow Unix Utility Argument Syntax:
%%%  utility_name [-abcDxyz][-p arg][operand]
%%%
%%% @end
%%%

-module(argparse).
-author("maximfca@gmail.com").

-export([
    validate/1,
    validate/2,
    parse/2,
    parse/3,
    help/2,
    format_error/1,
    format_error/2
]).

%%--------------------------------------------------------------------
%% API

-compile(warn_missing_spec).

%% @doc
%% Built-in types include basic validation abilities
%% String and binary validation may use regex match (ignoring captured value).
-type arg_type() :: boolean |
    float | {float, [{min, float()} | {max, float()}]} |
    int | {int, [{min, integer()} | {max, integer()}]} |
    string | {string, string()} | {string, string(), [term()]} |
    binary | {binary, binary()} | {binary, binary(), [term()]} |
    atom | {atom, unsafe} |
    {custom, fun((string()) -> term())}.

%% Command line argument specification.
%% Argument can be optional - starting with - (dash), and positional.
-type argument() :: #{
    %% Argument name, and a destination to store value too
    %% It is allowed to have several arguments named the same, setting or appending to the same variable.
    %% It is used to format the name, hence it should be format-table with "~s".
    name := atom() | string() | binary(),

    %% short, single-character variant of command line option, omitting dash (example: $b, meaning -b),
    %%  when present, this is optional argument
    short => char(),

    %% long command line option, omitting first dash (example: "kernel", or "-long", meaning "-kernel" and "--long"
    %% long command always wins over short abbreviation (e.g. -kernel is considered before -k -e -r -n -e -l)
    %%  when present, this is optional argument
    long => string(),

    %% throws an error if value is not present in command line
    required => true,

    %% default value, produced if value is not present in command line
    default => term(),

    %% parameter type (string by default)
    type => arg_type(),

    %% action to take when argument is matched
    action => store |       %% default: store argument consumed (last stored wins)
        {store, term()} |   %% does not consume argument, stores term() instead
        append |            %% appends consumed argument to a list
        {append, term()} |  %% does not consume an argument, appends term() to a list
        count |             %% does not consume argument, bumps counter
        extend,             %% uses when nargs is list/nonempty_list/all - appends every element to the list

    %% how many positional arguments to consume
    nargs =>
        pos_integer() |     %% consume exactly this amount, e.g. '-kernel key value' #{long => "-kernel", args => 2}
                            %%      returns #{kernel => ["key", "value"]}
        maybe |             %% if next argument is positional, consume it, otherwise produce default
        {maybe, term()} |   %% if next argument is positional, consume it, otherwise produce term()
        list |              %% consume zero or more positional arguments, until next optional
        nonempty_list |     %% consume at least one positional argument, until next optional
        all,                %% fold remaining command line into this argument

    %% help string printed in usage
    help => string()
}.

%% Arguments map: argument name to a term, produced by parser.
%% Supplied to command handler
-type arg_map() :: #{term() => term()}.

%% Command handler. May produce some output.
-type handler() :: fun((arg_map()) -> term()).

%% Sub-commands are arranged into maps (cannot start with prefix)
-type command_map() :: #{string() => command()}.

%% Command descriptor
-type command() :: #{
    %% Sub-commands
    commands => command_map(),

    %% accepted arguments list. Positional order is important!
    arguments => [argument()],

    %% help line
    help => string(),

    %% recommended handler function, cli behaviour deduces handler from
    %%  command name and module implementing cli behaviour
    handler => handler()
}.

-export_type([
    argument/0,
    command/0,
    handler/0,
    cmd_path/0,
    arg_map/0
]).

%% Optional or positional argument?
-define(IS_OPTIONAL(Arg), is_map_key(short, Arg) orelse is_map_key(long, Arg)).
-define(IS_POSITIONAL(Arg), not ?IS_OPTIONAL(Arg)).

%% Command path, for deeply nested sub-commands
-type cmd_path() :: [string()].

%% Parser state (not available via API)
-record(eos, {
    %% prefix character map, by default, only -
    prefixes :: #{integer() => true},
    %% argument map to be returned
    argmap = #{} :: arg_map(),
    %% sub-commands, in reversed orders, allowing to recover path taken
    commands = [] :: cmd_path(),
    %% command being matched
    current :: command(),
    %% unmatched positional arguments, in expected match order
    pos = [] :: [argument()],
    %% expected optional arguments, mapping between short/long form and an argument
    short = #{} :: #{integer() => argument()},
    long = #{} :: #{string() => argument()},
    %% flag, whether there are no options that can be confused with negative numbers
    no_digits = true :: boolean()
}).

%% Error Reason thrown by parser (feed it into format_error to get human-readable error).
-type argparse_reason() ::
    {invalid_command, cmd_path(), Field :: atom(), Reason :: string()} |
    {invalid_option, cmd_path(), Name :: string(), Field :: atom(), Reason :: string()} |
    {unknown_argument, cmd_path(), Argument :: string()} |
    {missing_argument, cmd_path(), argument()} |
    {invalid_argument, cmd_path(), argument(), Argument :: string()}.

%% Parser options
-type parser_options() :: #{
    %% allowed prefixes (default is [$-]).
    prefixes => [integer()]
}.

%% Command name with command spec
-type command_spec() :: {Name :: string(), command()}.

%% Result returned from parse/2,3: can be only argument map,
%%  or argument map with command_spec.
-type parse_result() :: arg_map() | {arg_map(), command_spec()}.

%% @doc
%% Validates command specification, throws if there is an error.
%% Returns program name (from init:get_argument(progname)) with
%%  canonical command.
-spec validate(command()) -> command_spec().
validate(Command) ->
    validate(Command, #{}).

-spec validate(command(), parser_options()) -> command_spec().
validate(Command, Options) ->
    validate_impl(Command, Options).

%% @doc
%% Parses supplied arguments according to expected command definition.
-spec parse(Args :: [string()], command() | command_spec()) -> parse_result().
parse(Args, Command) ->
    parse(Args, Command, #{}).

%% @doc
%% Parses supplied arguments, with additional options specified.
-spec parse(Args :: [string()], command() | command_spec(),
    Options :: parser_options()) -> parse_result.
parse(Args, Command, Options) ->
    {Prog, Cmd} = validate(Command, Options),
    Prefixes = maps:from_list([{P, true} || P <- maps:get(prefixes, Options, [$-])]),
    parse_impl(Args, merge_arguments(Prog, Cmd, #eos{prefixes = Prefixes})).

%% By default, options are indented with 2 spaces for each level of
%%  sub-command.
-define (DEFAULT_INDENT, "  ").

%% Help format options
-type help_options() :: #{
    progname => string(),   %% program name override
    command => [string()]   %% nested command (missing/empty for top-level command)
}.

%% @doc
%% Returns help for Command formatted according to Options specified
-spec help(command() | command_spec(), help_options()) -> string().
help(Command, Options) ->
    format_help(validate(Command, Options), Options).

%% @doc
%% Format exception reasons produced by parse/2.
%% Exception of class error with reason {argparse, Reason} is normally
%%  raised, and format_error accepts only the Reason part, leaving
%%  other exceptions that do not belong to argparse out.
-spec format_error(argparse_reason()) -> string().
format_error({invalid_command, Path, Field, Text}) ->
    lists:flatten(io_lib:format("~sinternal error, invalid field '~s': ~s~n",
        [format_path(Path), Field, Text]));
format_error({invalid_option, Path, Name, Field, Text}) ->
    lists:flatten(io_lib:format("~sinternal error, option ~s field '~s': ~s~n",
        [format_path(Path), Name, Field, Text]));
format_error({unknown_argument, Path, Argument}) ->
    lists:flatten(io_lib:format("~sunrecognised argument: ~s~n",
        [format_path(Path), Argument]));
format_error({missing_argument, Path, Name}) ->
    lists:flatten(io_lib:format("~srequired argument missing: ~s~n",
        [format_path(Path), Name]));
format_error({invalid_argument, Path, Name, Value}) ->
    lists:flatten(io_lib:format("~sinvalid argument ~s for: ~s~n",
        [format_path(Path), Value, Name])).

%% @doc
%% Formats exception, and adds command usage information for
%%  command that was known/parsed when exception was raised.
-spec format_error(argparse_reason(), command() | command_spec()) -> string().
format_error(Reason, Command) ->
    Path = element(2, Reason),
    ErrorText = format_error(Reason),
    UsageText = help(Command, #{command => Path}),
    ErrorText ++ UsageText.

%%--------------------------------------------------------------------
%% Parser implementation

%% @private
%% parse_impl implements entire internal parse logic.

%% Claus: option starting with any prefix
%% No separate clause for single-character short form, because there could be a single-character
%%  long form taking precedence.
parse_impl([[Prefix | Name] | Tail], #eos{prefixes = Pref} = Eos) when is_map_key(Prefix, Pref) ->
    %% match "long" option from the list of currently known
    case maps:find(Name, Eos#eos.long) of
        {ok, Option} ->
            consume(Tail, Option, Eos);
        error ->
            %% try to match single-character flag
            case Name of
                [Flag] when is_map_key(Flag, Eos#eos.short) ->
                    %% found a flag
                    consume(Tail, maps:get(Flag, Eos#eos.short), Eos);
                [Flag | Rest] when is_map_key(Flag, Eos#eos.short) ->
                    %% can be a combination of flags, or flag with value,
                    %%  but can never be a negative integer, because otherwise
                    %%  it will be reflected in no_digits
                    case abbreviated(Name, [], Eos#eos.short) of
                        false ->
                            %% short option with Rest being an argument
                            consume([Rest | Tail], maps:get(Flag, Eos#eos.short), Eos);
                        Expanded ->
                            %% expand multiple flags into actual list, adding prefix
                            parse_impl([[Prefix,E] || E <- Expanded] ++ Tail, Eos)
                    end;
                MaybeNegative when Prefix =:= $-, Eos#eos.no_digits ->
                    case is_digits(MaybeNegative) of
                        true ->
                            %% found a negative number
                            parse_positional([Prefix|Name], Tail, Eos);
                        false ->
                            fail({unknown_argument, Eos#eos.commands, [Prefix|Name]})
                    end;
                _Unknown ->
                    fail({unknown_argument, Eos#eos.commands, [Prefix|Name]})
            end
    end;

%% Arguments not starting with Prefix: attempt to match sub-command, if available
parse_impl([Positional | Tail], #eos{current = #{commands := SubCommands}} = Eos) ->
    case maps:find(Positional, SubCommands) of
        error ->
            %% sub-command not found, try positional argument
            parse_positional(Positional, Tail, Eos);
        {ok, SubCmd} ->
            %% found matching sub-command with arguments, descend into it
            parse_impl(Tail, merge_arguments(Positional, SubCmd, Eos))
    end;

%% Clause for arguments that don't have sub-commands (therefore check for
%%  positional argument).
parse_impl([Positional | Tail], Eos) ->
    parse_positional(Positional, Tail, Eos);

%% Entire command line has been matched, go over missing arguments,
%%  add defaults etc
parse_impl([], #eos{argmap = ArgMap0, commands = Commands, current = Current, pos = Pos} = Eos) ->
    %% error if stopped at sub-command with no handler
    map_size(maps:get(commands, Current, #{})) >0 andalso
        (not is_map_key(handler, Current)) andalso
        fail({missing_argument, Commands, ""}),
    %% go over remaining positional, verify they are all not required
    ArgMap1 = fold_args_map(Commands, true, ArgMap0, Pos),
    %% go over optionals, and either raise an error, or set default
    ArgMap2 = fold_args_map(Commands, false, ArgMap1, maps:values(Eos#eos.short)),
    ArgMap3 = fold_args_map(Commands, false, ArgMap2, maps:values(Eos#eos.long)),
    case Eos#eos.commands of
        [_] ->
            %% if there were no commands specified, only the argument map
            ArgMap3;
        [_|_] ->
            %% otherwise return argument map, command path taken, and the
            %%  last command matched (usually it contains a handler to run)
            {ArgMap3, {hd(Eos#eos.commands), Eos#eos.current}}
    end.

%% @private
%% Generate error for missing required argument, and supply defaults for
%%  missing optional arguments that have defaults.
fold_args_map(Commands, Req, ArgMap, Args) ->
    lists:foldl(
        fun (#{name := Name} = Opt, Acc) when is_map_key(Name, Acc); map_get(required, Opt) =:= false ->
                %% argument present, or explicitly not required
                Acc;
            (#{name := Name, required := true}, _Acc) ->
                %% missing, and required explicitly
                fail({missing_argument, Commands, Name});
            (#{name := Name, default := Default}, Acc) when Req =:= true ->
                %% positional argument with default
                Acc#{Name => Default};
            (#{name := Name}, _Acc) when Req =:= true ->
                %% missing, for positional argument, implicitly required
                fail({missing_argument, Commands, Name});
            (#{name := Name, default := Default}, Acc) ->
                %% missing, optional, and there is a default
                Acc#{Name => Default};
            (_Opt, Acc) ->
                %% missing, optional, no default - don't populate
                Acc
        end, ArgMap, Args).

%%--------------------------------------------------------------------
%% argument consumption (nargs) handling

parse_positional(Arg, _Tail, #eos{pos = [], commands = Commands}) ->
    fail({unknown_argument, Commands, Arg});
parse_positional(Arg, Tail, #eos{pos = Pos} = Eos) ->
    %% positional argument itself is a value
    consume([Arg | Tail], hd(Pos), Eos).

%% @private
%% Adds CmdName to path, and includes any arguments found there
merge_arguments(CmdName, #{arguments := Args} = SubCmd, Eos) ->
    add_args(Args, Eos#eos{current = SubCmd, commands = [CmdName | Eos#eos.commands]});
merge_arguments(CmdName, SubCmd, Eos) ->
    Eos#eos{current = SubCmd, commands = [CmdName | Eos#eos.commands]}.

%% @private
%% adds arguments into current set of discovered pos/opts
add_args([], Eos) ->
    Eos;
add_args([#{short := S, long := L} = Option | Tail], #eos{short = Short, long = Long} = Eos) ->
    %% remember if this option can be confused with negative number
    NoDigits = no_digits(Eos#eos.no_digits, Eos#eos.prefixes, S, L),
    add_args(Tail, Eos#eos{short = Short#{S => Option}, long = Long#{L => Option}, no_digits = NoDigits});
add_args([#{short := S} = Option | Tail], #eos{short = Short} = Eos) ->
    %% remember if this option can be confused with negative number
    NoDigits = no_digits(Eos#eos.no_digits, Eos#eos.prefixes, S, 0),
    add_args(Tail, Eos#eos{short = Short#{S => Option}, no_digits = NoDigits});
add_args([#{long := L} = Option | Tail], #eos{long = Long} = Eos) ->
    %% remember if this option can be confused with negative number
    NoDigits = no_digits(Eos#eos.no_digits, Eos#eos.prefixes, 0, L),
    add_args(Tail, Eos#eos{long = Long#{L => Option}, no_digits = NoDigits});
add_args([PosOpt | Tail], #eos{pos = Pos} = Eos) ->
    add_args(Tail, Eos#eos{pos = Pos ++ [PosOpt]}).

%% @private
%% If no_digits is still true, try to find out whether it should turn false,
%%  because added options look like negative numbers, and prefixes include -
no_digits(false, _, _, _) ->
    false;
no_digits(true, Prefixes, _, _) when not is_map_key($-, Prefixes) ->
    true;
no_digits(true, _, Short, _) when Short >= $0, Short =< $9 ->
    false;
no_digits(true, _, _, Long) ->
    not is_digits(Long).

%%--------------------------------------------------------------------
%% additional functions for optional arguments processing

%% @private
%% Returns true when option (!) description passed requires a positional argument,
%%  hence cannot be treated as a flag.
requires_argument(#{nargs := {maybe, _Term}}) ->
    false;
requires_argument(#{nargs := maybe}) ->
    false;
requires_argument(#{nargs := _Any}) ->
    true;
requires_argument(Opt) ->
    case maps:get(action, Opt, store) of
        store ->
            maps:get(type, Opt, string) =/= boolean;
        append ->
            maps:get(type, Opt, string) =/= boolean;
        _ ->
            false
    end.

%% @private
%% Attempts to find if passed list of flags can be expanded
abbreviated([Last], Acc, AllShort) when is_map_key(Last, AllShort) ->
    lists:reverse([Last | Acc]);
abbreviated([_], _Acc, _Eos) ->
    false;
abbreviated([Flag | Tail], Acc, AllShort) ->
    case maps:find(Flag, AllShort) of
        error ->
            false;
        {ok, Opt} ->
            case requires_argument(Opt) of
                true ->
                    false;
                false ->
                    abbreviated(Tail, [Flag | Acc], AllShort)
            end
    end.

%%--------------------------------------------------------------------
%% argument consumption (nargs) handling

%% consume predefined amount (none of which can be an option?)
consume(Tail, #{nargs := Count} = Opt, Eos) when is_integer(Count) ->
    {Consumed, Remain} = split_to_option(Tail, Count, Eos, []),
    length(Consumed) < Count andalso fail({invalid_argument, Eos#eos.commands, maps:get(name, Opt), Tail}),
    action(Remain, Consumed, Opt#{type => {list, maps:get(type, Opt, string)}}, Eos);

%% handle 'reminder' by just dumping everything in
consume(Tail, #{nargs := all} = Opt, Eos) ->
    action([], Tail, Opt#{type => {list, maps:get(type, Opt, string)}}, Eos);

%% require at least one argument
consume(Tail, #{nargs := nonempty_list} = Opt, Eos) ->
    {Consumed, Remains} = split_to_option(Tail, -1, Eos, []),
    Consumed =:= [] andalso fail({invalid_argument, Eos#eos.commands, maps:get(name, Opt), Tail}),
    action(Remains, Consumed, Opt#{type => {list, maps:get(type, Opt, string)}}, Eos);

%% consume all until next option
consume(Tail, #{nargs := list} = Opt, Eos) ->
    {Consumed, Remains} = split_to_option(Tail, -1, Eos, []),
    action(Remains, Consumed, Opt#{type => {list, maps:get(type, Opt, string)}}, Eos);

%% maybe consume one, maybe not...
%% special cases for 'boolean maybe', only consume 'true' and 'false'
consume(["true" | Tail], #{type := boolean} = Opt, Eos) ->
    action(Tail, true, Opt#{type => raw}, Eos);
consume(["false" | Tail], #{type := boolean} = Opt, Eos) ->
    action(Tail, false, Opt#{type => raw}, Eos);
consume(Tail, #{type := boolean} = Opt, Eos) ->
    %% if neither true or false, don't consume, just do the action with 'true' as arg
    action(Tail, true, Opt#{type => raw}, Eos);

%% maybe behaviour, as '?'
consume(Tail, #{nargs := maybe} = Opt, Eos) ->
    case split_to_option(Tail, 1, Eos, []) of
        {[], _} ->
            %% no argument given, produce default argument (if not present,
            %%  then produce default value of the specified type)
            action(Tail, default(Opt), Opt#{type => raw}, Eos);
        {[Consumed], Remains} ->
            action(Remains, Consumed, Opt, Eos)
    end;

%% maybe consume one, maybe not...
consume(Tail, #{nargs := {maybe, Const}} = Opt, Eos) ->
    case split_to_option(Tail, 1, Eos, []) of
        {[], _} ->
            action(Tail, Const, Opt, Eos);
        {[Consumed], Remains} ->
            action(Remains, Consumed, Opt, Eos)
    end;

%% default case, which depends on action
consume(Tail, #{action := count} = Opt, Eos) ->
    action(Tail, undefined, Opt, Eos);

%% for {store, ...} and {append, ...} don't take argument out
consume(Tail, #{action := {Act, _Const}} = Opt, Eos) when Act =:= store; Act =:= append ->
    action(Tail, undefined, Opt, Eos);

%% optional: ensure not to consume another option start
consume([[Prefix | _] = ArgValue | Tail], Opt, Eos) when ?IS_OPTIONAL(Opt), is_map_key(Prefix, Eos#eos.prefixes) ->
    case Eos#eos.no_digits andalso is_digits(ArgValue) of
        true ->
            action(Tail, ArgValue, Opt, Eos);
        false ->
            fail({missing_argument, Eos#eos.commands, maps:get(name, Opt)})
    end;

consume([ArgValue | Tail], Opt, Eos) when ?IS_OPTIONAL(Opt) ->
    action(Tail, ArgValue, Opt, Eos);

%% positional: just consume one, no 'maybe' behaviour
consume([ArgValue | Tail], Opt, Eos) ->
    %% for positionals, strip the matched one now
    action(Tail, ArgValue, Opt, Eos#eos{pos = tl(Eos#eos.pos)}).

%% no more arguments for consumption, but last optional may still be action-ed
%%consume([], Current, Opt, Eos) ->
%%    action([], Current, undefined, Opt, Eos).

%% smart split: ignore arguments that can be parsed as negative numbers,
%%  unless there are arguments that look like negative numbers
split_to_option([], _, _Eos, Acc) ->
    {lists:reverse(Acc), []};
split_to_option(Tail, 0, _Eos, Acc) ->
    {lists:reverse(Acc), Tail};
split_to_option([[Prefix | _] = MaybeNumber | Tail] = All, Left,
    #eos{no_digits = true, prefixes = Prefixes} = Eos, Acc) when is_map_key(Prefix, Prefixes) ->
    case is_digits(MaybeNumber) of
        true ->
            split_to_option(Tail, Left - 1, Eos, [MaybeNumber | Acc]);
        false ->
            {lists:reverse(Acc), All}
    end;
split_to_option([[Prefix | _] | _] = All, _Left,
    #eos{no_digits = false, prefixes = Prefixes}, Acc) when is_map_key(Prefix, Prefixes) ->
    {lists:reverse(Acc), All};
split_to_option([Head | Tail], Left, Opts, Acc) ->
    split_to_option(Tail, Left - 1, Opts, [Head | Acc]).

%%--------------------------------------------------------------------
%% Action handling

action(Tail, ArgValue, #{name := ArgName, action := store} = Opt, #eos{argmap = ArgMap} = Eos) ->
    Value = convert_type(maps:get(type, Opt, string), ArgValue, ArgName, Eos),
    parse_impl(Tail, Eos#eos{argmap = ArgMap#{ArgName => Value}});

action(Tail, undefined, #{name := ArgName, action := {store, Value}}, #eos{argmap = ArgMap} = Eos) ->
    parse_impl(Tail, Eos#eos{argmap = ArgMap#{ArgName => Value}});

action(Tail, ArgValue, #{name := ArgName, action := append} = Opt, #eos{argmap = ArgMap} = Eos) ->
    Value = convert_type(maps:get(type, Opt, string), ArgValue, ArgName, Eos),
    parse_impl(Tail, Eos#eos{argmap = ArgMap#{ArgName => maps:get(ArgName, ArgMap, []) ++ [Value]}});

action(Tail, undefined, #{name := ArgName, action := {append, Value}}, #eos{argmap = ArgMap} = Eos) ->
    parse_impl(Tail, Eos#eos{argmap = ArgMap#{ArgName => maps:get(ArgName, ArgMap, []) ++ [Value]}});

action(Tail, ArgValue, #{name := ArgName, action := extend} = Opt, #eos{argmap = ArgMap} = Eos) ->
    Value = convert_type(maps:get(type, Opt, string), ArgValue, ArgName, Eos),
    Extended = maps:get(ArgName, ArgMap, []) ++ Value,
    parse_impl(Tail, Eos#eos{argmap = ArgMap#{ArgName => Extended}});

action(Tail, undefined, #{name := ArgName, action := count}, #eos{argmap = ArgMap} = Eos) ->
    parse_impl(Tail, Eos#eos{argmap = ArgMap#{ArgName => maps:get(ArgName, ArgMap, 0) + 1}});

%% default: same as set
action(Tail, ArgValue, Opt, Eos) ->
    action(Tail, ArgValue, Opt#{action => store}, Eos).

%%--------------------------------------------------------------------
%% Type conversion

%% Handle "list" variant for nargs returning list
convert_type({list, Type}, Arg, Opt, Eos) ->
    [convert_type(Type, Var, Opt, Eos) || Var <- Arg];

%% raw - no conversion applied (most likely default)
convert_type(raw, Arg, _Opt, _Eos) ->
    Arg;

%% Handle actual types
convert_type(string, Arg, _Opt, _Eos) ->
    Arg;
convert_type({string, Re}, Arg, Opt, Eos) ->
    case re:run(Arg, Re) of
        {match, _X} -> Arg;
        _ -> fail({invalid_argument, Eos#eos.commands, Opt, Arg})
    end;
convert_type({string, Re, ReOpt}, Arg, Opt, Eos) ->
    case re:run(Arg, Re, ReOpt) of
        match -> Arg;
        {match, _} -> Arg;
        _ -> fail({invalid_argument, Eos#eos.commands, Opt, Arg})
    end;
convert_type(int, Arg, Opt, Eos) ->
    get_int(Arg, Opt, Eos);
convert_type({int, Opts}, Arg, Opt, Eos) ->
    minimax(get_int(Arg, Opt, Eos), Opts, Eos, Opt);
convert_type(boolean, "true", _Opt, _Eos) ->
    true;
convert_type(boolean, "false", _Opt, _Eos) ->
    false;
convert_type(binary, Arg, _Opt, _Eos) ->
    list_to_binary(Arg);
convert_type({binary, Re}, Arg, Opt, Eos) ->
    case re:run(Arg, Re) of
        {match, _X} -> list_to_binary(Arg);
        _ -> fail({invalid_argument, Eos#eos.commands, Opt, Arg})
    end;
convert_type({binary, Re, ReOpt}, Arg, Opt, Eos) ->
    case re:run(Arg, Re, ReOpt) of
        match -> list_to_binary(Arg);
        {match, _} -> list_to_binary(Arg);
        _ -> fail({invalid_argument, Eos#eos.commands, Opt, Arg})
    end;
convert_type(float, Arg, Opt, Eos) ->
    get_float(Arg, Opt, Eos);
convert_type({float, Opts}, Arg, Opt, Eos) ->
    minimax(get_float(Arg, Opt, Eos), Opts, Eos, Opt);
convert_type(atom, Arg, Opt, Eos) ->
    try list_to_existing_atom(Arg)
    catch error:badarg ->
        fail({invalid_argument, Eos#eos.commands, Opt, Arg})
    end;
convert_type({atom, unsafe}, Arg, _Opt, _Eos) ->
    list_to_atom(Arg);
convert_type({custom, Fun}, Arg, Opt, Eos) ->
    try Fun(Arg)
    catch error:invalid_argument ->
        fail({invalid_argument, Eos#eos.commands, Opt, Arg})
    end.

%% @private
%% Given Var, and list of {min, X}, {max, Y}, ensure that
%%  value falls within defined limits.
minimax(Var, [], _Eos, _Opt) ->
    Var;
minimax(Var, [{min, Min} | _], Eos, Opt) when Var < Min ->
    fail({invalid_argument, Eos#eos.commands, Opt, Var});
minimax(Var, [{max, Max} | _], Eos, Opt) when Var > Max ->
    fail({invalid_argument, Eos#eos.commands, Opt, Var});
minimax(Var, [_ | Tail], Eos, Opt) ->
    minimax(Var, Tail, Eos, Opt).

%% @private
%% returns int from string, or errors out with debugging info
get_int(Arg, Opt, Eos) ->
    case string:to_integer(Arg) of
        {Int, []} ->
            Int;
        {error, _Reason} ->
            fail({invalid_argument, Eos#eos.commands, Opt, Arg})
    end.

%% @private
%% returns float from string, that is floating-point, or integer
get_float(Arg, Opt, Eos) ->
    case string:to_float(Arg) of
        {Float, []} ->
            Float;
        {error, _Reason} ->
            %% possibly in disguise
            case string:to_integer(Arg) of
                {Int, []} ->
                    Int;
                {error, _IntReason} ->
                    fail({invalid_argument, Eos#eos.commands, Opt, Arg})
            end
    end.

%% Returns 'true' if String can be converted to a number
is_digits(String) ->
    case string:to_integer(String) of
        {_Int, []} ->
            true;
        {error, _} ->
            case string:to_float(String) of
                {_Float, []} ->
                    true;
                {error, _} ->
                    false
            end
    end.

%% 'maybe' nargs for an option that does not have default set still have
%%  to produce something, let's call it hardcoded default.
default(#{default := Default}) ->
    Default;
default(#{type := boolean}) ->
    true;
default(#{type := int}) ->
    0;
default(#{type := float}) ->
    0.0;
default(#{type := string}) ->
    "";
default(#{type := atom}) ->
    undefined;
%% no type given, consider it 'undefined' atom
default(_) ->
    undefined.

%% when parsing, state is stored in a reversed form
%% when error needs to be formatted, command path should be
%%  reversed and joined with " "
format_path([]) ->
    "";
format_path(Commands) ->
    lists:concat(lists:join(" ", lists:reverse(Commands))) ++ ": ".

%% to simplify throwing errors with the right reason
fail(Reason) ->
    erlang:error({?MODULE, Reason}).

%%--------------------------------------------------------------------
%% Validation and preprocessing
%% Theoretically, Dialyzer should do that too.
%% Practically, so many people ignore Dialyzer and then spend hours
%%  trying to understand why things don't work, that is makes sense
%%  to provide a mini-Dialyzer here.

validate_impl(Command, #{progname := Prog} = Options) ->
    Prefixes = maps:from_list([{P, true} || P <- maps:get(prefixes, Options, [$-])]),
    validate_command([{Prog, Command}], Prefixes);
validate_impl(Command, Options) ->
    {ok, [[Prog]]} = init:get_argument(progname),
    validate_impl(Command, Options#{progname => Prog}).

%% validates commands, throws invalid_command or invalid_option error
validate_command([{Name, Cmd} | _] = Path, Prefixes) ->
    (is_list(Name) andalso (not is_map_key(hd(Name), Prefixes))) orelse
        fail({invalid_command, clean_path(Path), commands, "command name must be a string, not starting with optional prefix"}),
    is_map(Cmd) orelse
        fail({invalid_command, clean_path(Path), commands, "command description must be a map"}),
    is_list(maps:get(help, Cmd, [])) orelse
        fail({invalid_command, clean_path(Path), help, "help must be a string"}),
    is_map(maps:get(commands, Cmd, #{})) orelse
        fail({invalid_command, clean_path(Path), commands, "sub-commands must be a map"}),
    is_map_key(handler, Cmd) andalso (not is_function(maps:get(handler, Cmd))) andalso
        fail({invalid_command, clean_path(Path), handler, "handler must be a function accepting single map argument"}),
    Cmd1 =
        case maps:find(arguments, Cmd) of
            error ->
                Cmd;
            {ok, Opts} ->
                Cmd#{arguments => [validate_option(Path, Opt) || Opt <- Opts]}
        end,
    %% collect all short & long option identifiers - to figure out any conflicts
    lists:foldl(
        fun ({_, #{arguments := Opts}}, Acc) ->
            lists:foldl(
                fun (#{short := Short, name := OName}, {AllS, AllL}) ->
                        is_map_key(Short, AllS) andalso
                            fail({invalid_option, clean_path(Path), OName,
                                    "short conflicting with " ++ atom_to_list(maps:get(Short, AllS))}),
                        {AllS#{Short => OName}, AllL};
                    (#{long := Long, name := OName}, {AllS, AllL}) ->
                        is_map_key(Long, AllL) andalso
                            fail({invalid_option, clean_path(Path), OName,
                                    "long conflicting with " ++ atom_to_list(maps:get(Long, AllL))}),
                        {AllS, AllL#{Long => OName}};
                    (_, AccIn) ->
                        AccIn
                end, Acc, Opts);
            (_, Acc) ->
                Acc
        end, {#{}, #{}}, Path),
    %% verify all sub-commands
    case maps:find(commands, Cmd1) of
        error ->
            {Name, Cmd1};
        {ok, Sub} ->
            {Name, Cmd1#{commands => maps:map(
                fun (K, V) ->
                    {K, Updated} = validate_command([{K, V} | Path], Prefixes),
                    Updated
                end, Sub)}}
    end.

%% validates option spec
validate_option(Path, #{name := Name} = Opt) when is_atom(Name) ->
    %% arguments cannot have unrecognised map items
    Unknown = maps:keys(maps:without([name, help, short, long, action, nargs, type, default, required], Opt)),
    Unknown =/= [] andalso fail({invalid_option, clean_path(Path), hd(Unknown), "unrecognised field"}),
    %% verify specific arguments
    is_list(maps:get(help, Opt, [])) orelse
        fail({invalid_option, clean_path(Path), Name, help, "must be a string"}),
    is_list(maps:get(long, Opt, [])) orelse
        fail({invalid_option, clean_path(Path), Name, long, "must be a string"}),
    is_boolean(maps:get(required, Opt, true)) orelse
        fail({invalid_option, clean_path(Path), Name, required, "must be boolean"}),
    is_integer(maps:get(short, Opt, $a)) orelse
        fail({invalid_option, clean_path(Path), Name, short, "must be character"}),
    Opt1 = maybe_validate(action, Opt, fun validate_action/3, Path),
    Opt2 = maybe_validate(type, Opt1, fun validate_type/3, Path),
    maybe_validate(nargs, Opt2, fun validate_args/3, Path);
validate_option(Path, _Opt) ->
    fail({invalid_option, clean_path(Path), "", name, "argument must be a map, and specify 'name'"}).

maybe_validate(Key, Map, Fun, Path) when is_map_key(Key, Map) ->
    maps:put(Key, Fun(maps:get(Key, Map), Path, Map), Map);
maybe_validate(_Key, Map, _Fun, _Path) ->
    Map.

%% validate action field
validate_action(store, _Path, _Opt) -> store;
validate_action({store, Term}, _Path, _Opt) -> {store, Term};
validate_action(append, _Path, _Opt) -> append;
validate_action({append, Term}, _Path, _Opt) -> {append, Term};
validate_action(count, _Path, _Opt) -> count;
validate_action(extend, _Path, _Opt) -> extend;
validate_action(_Action, Path, #{name := Name}) ->
    fail({invalid_option, clean_path(Path), Name, action, "unsupported"}).

%% validate type field
validate_type(Simple, _Path, _Opt) when Simple =:= boolean; Simple =:= int; Simple =:= float;
    Simple =:= string; Simple =:= binary; Simple =:= atom; Simple =:= {atom, unsafe} ->
    Simple;
validate_type({custom, Fun}, _Path, _Opt) when is_function(Fun, 1) ->
    {custom, Fun};
validate_type({float, Opts}, Path, #{name := Name}) ->
    [fail({invalid_option, clean_path(Path), Name, type, "invalid validator"})
        || {Kind, Val} <- Opts, (Kind =/= min andalso Kind =/= max) orelse (not is_float(Val))],
    {float, Opts};
validate_type({int, Opts}, Path, #{name := Name}) ->
    [fail({invalid_option, clean_path(Path), Name, type, "invalid validator"})
        || {Kind, Val} <- Opts, (Kind =/= min andalso Kind =/= max) orelse (not is_integer(Val))],
    {int, Opts};
validate_type({string, Re} = Valid, _Path, _Opt) when is_list(Re) ->
    Valid;
validate_type({string, Re, L} = Valid, _Path, _Opt) when is_list(Re), is_list(L) ->
    Valid;
validate_type({binary, Re} = Valid, _Path, _Opt) when is_binary(Re) ->
    Valid;
validate_type({binary, Re, L} = Valid, _Path, _Opt) when is_binary(Re), is_list(L) ->
    Valid;
validate_type(_Type, Path, #{name := Name}) ->
    fail({invalid_option, clean_path(Path), Name, type, "unsupported"}).

validate_args(N, _Path, _Opt) when is_integer(N), N >= 1 -> N;
validate_args(Simple, _Path, _Opt) when Simple =:= all; Simple =:= list; Simple =:= maybe; Simple =:= nonempty_list ->
    Simple;
validate_args({maybe, Term}, _Path, _Opt) -> {maybe, Term};
validate_args(_Nargs, Path, #{name := Name}) ->
    fail({invalid_option, clean_path(Path), Name, nargs, "unsupported"}).

%% used to throw an error - strips command component out of path
clean_path(Path) ->
    [Cmd || {Cmd, _} <- Path].

%%--------------------------------------------------------------------
%% Built-in Help formatter

%% Example format:
%%
%% usage: utility [-rxvf] [-i <int>] [--float <float>] <command> [<ARGS>]
%%
%% Commands:
%%   start   verifies configuration and starts server
%%   stop    stops running server
%%
%% Optional arguments:
%%  -r       recursive
%%  -v       increase verbosity level
%%  -f       force
%%  -i <int> interval set
%%  --float <float> floating-point long form argument
%%

%% Example for deeper nested help (amount of flags reduced from previous example)
%%
%% usage: utility [-rz] [-i <int>] start <SERVER> [<NAME>]
%%
%% Optional arguments:
%%  -r       recursive
%%  -z       use zlib compression
%%  -i <int> integer variable
%%  SERVER   server to start
%%  NAME     extra name to pass
%%

format_help({CmdName, Root}, Format) ->
    Prefix = hd(maps:get(prefixes, Format, [$-])),
    Nested = maps:get(command, Format, []),
    %% descent into commands collecting all options on the way
    {Cmd, AllArgs} = collect_options(Root, Nested, []),
    %% split arguments into Flags, Options, Positional, and create help lines
    {_, Longest, Flags, Opts, Args, OptLines} = lists:foldl(fun format_opt_help/2,
        {Prefix, 0, "", [], [], []}, AllArgs),
    %% collect and format sub-commands
    Immediate = maps:get(commands, Cmd, #{}),
    {Long, Subs} = maps:fold(
        fun (Name, Sub, {Long, SubAcc}) ->
            Help = maps:get(help, Sub, ""),
            {max(Long, length(Name)), [{Name, Help}|SubAcc]}
        end, {Longest, []}, Immediate),
    %% format sub-commands
    SubFormat = io_lib:format("  ~~-~bs ~~s~n", [Long]),
    Commands = lists:concat([io_lib:format(SubFormat, [N, D]) || {N, D} <- Subs]),
    ShortCmd =
        case map_size(Immediate) of
            0 ->
                "";
            Small when Small < 3 ->
                " " ++ lists:concat(lists:join(" ", Nested)) ++  " {" ++
                    lists:concat(lists:join("|", maps:keys(Immediate))) ++ "}";
            _Largs ->
                io_lib:format("~s <command>", [lists:concat(lists:join(" ", Nested))])
        end,
    %% format flags
    FlagsForm = if Flags =:=[] -> ""; true -> io_lib:format(" [~c~s]", [Prefix, Flags]) end,
    %% format non-flag optionals
    OptsForm = Opts,
    %% format positional arguments
    ArgsForm = Args,
    %% format extended view
    OptFormat = io_lib:format("  ~~-~bs ~~s~n", [Longest]),
    FormOpts = [io_lib:format(OptFormat, [Hdr, Dsc]) || {Hdr, Dsc} <- OptLines],
    %% format first usage line
    lists:flatten(io_lib:format("usage: ~s~s~s~s~s~n~s~s", [CmdName, ShortCmd, FlagsForm, OptsForm, ArgsForm,
        maybe_add("~nSubcommands:~n~s", Commands), maybe_add("~nOptional arguments:~n~s", FormOpts)])).

%% collects options on the Path, and returns found Command
collect_options(Command, [], Args) ->
    {Command, maps:get(arguments, Command, []) ++ Args};
collect_options(Command, [Cmd|Tail], Args) ->
    Sub = maps:get(commands, Command),
    SubCmd = maps:get(Cmd, Sub),
    collect_options(SubCmd, Tail, maps:get(arguments, Command, []) ++ Args).

%% conditionally adds text and empty lines
maybe_add(_ToAdd, []) ->
    [];
maybe_add(ToAdd, List) ->
    io_lib:format(ToAdd, [List]).

%% create help line for every option, collecting together all flags, short options,
%%  long options, and positional arguments

%% format optional argument
format_opt_help(Opt, {Prefix, Longest, Flags, Opts, Args, OptLines}) when ?IS_OPTIONAL(Opt) ->
    Desc = lists:flatten(io_lib:format("~s~s~s",
        [maps:get(help, Opt, ""), format_type(Opt), format_default(Opt)])),
    %% does it need an argument? look for nargs and action
    RequiresArg = requires_argument(Opt),
    %% long form always added to Opts
    {Name0, MaybeOpt0} =
        case maps:find(long, Opt) of
            error ->
                {"", []};
            {ok, Long} when RequiresArg ->
                FN = [Prefix | Long],
                {FN, [format_required(false, FN ++ " ", Opt)]};
            {ok, Long} when map_get(required, Opt) =:= true ->
                FN = [Prefix | Long],
                {FN, [[$ |FN]]};
            {ok, Long} ->
                FN = [Prefix | Long],
                {FN, [io_lib:format(" [~s]", [FN])]}
        end,
    %% short may go to flags, or Opts
    {Name, MaybeFlag, MaybeOpt} =
        case maps:find(short, Opt) of
            error ->
                {Name0, [], MaybeOpt0};
            {ok, Short} when RequiresArg ->
                SN = [Prefix, Short],
                {maybe_concat(SN, Name0), [],
                    [format_required(false, SN ++ " ", Opt) | MaybeOpt0]};
            {ok, Short} ->
                {maybe_concat([Prefix, Short], Name0), [Short], MaybeOpt0}
        end,
    %% name length, capped at 16
    NameLen = length(Name),
    Capped = min(24, NameLen),
    {Prefix, max(Capped, Longest), Flags ++ MaybeFlag, Opts ++ MaybeOpt, Args, [{Name, Desc} | OptLines]};

%% format positional argument
format_opt_help(#{name := Name} = Opt, {Prefix, Longest, Flags, Opts, Args, OptLines}) ->
    Desc = lists:flatten(io_lib:format("~s~s~s",
        [maps:get(help, Opt, ""), format_type(Opt), format_default(Opt)])),
    %% positional, hence required
    LName = io_lib:format("~s", [Name]),
    LPos = format_required(maps:get(required, Opt, true), "", Opt),
    {Prefix, max(Longest, length(LName)), Flags, Opts, Args ++ LPos, [{LName, Desc}|OptLines]}.

%% option formatting helpers
maybe_concat(No, []) -> No;
maybe_concat(No, L) -> No ++ ", " ++ L.

format_required(true, Extra, #{name := Name} = Opt) ->
    io_lib:format(" ~s<~s>~s", [Extra, Name, format_nargs(Opt)]);
format_required(false, Extra, #{name := Name} = Opt) ->
    io_lib:format(" [~s<~s>~s]", [Extra, Name, format_nargs(Opt)]).

format_nargs(#{nargs := Dots}) when Dots =:= list; Dots =:= all; Dots =:= nonempty_list ->
    "...";
format_nargs(_) ->
    "".

format_type(#{type := {Num, Valid}}) when Num =:= int; Num =:= float ->
    case {proplists:get_value(min, Valid), proplists:get_value(max, Valid)} of
        {undefined, undefined} ->
            io_lib:format(", ~s", [Num]);
        {Min, undefined} ->
            io_lib:format(", ~s > ~tp", [Num, Min]);
        {undefined, Max} ->
            io_lib:format(", ~s < ~tp", [Num, Max]);
        {Min, Max} ->
            io_lib:format(", ~tp < ~s < ~tp", [Min, Num, Max])
    end;
format_type(#{type := Type}) when is_tuple(Type), (element(1, Type) =:= string orelse element(1, Type) =:= binary) ->
    Re = element(2, Type),
    io_lib:format(", ~s re: ~s", [Type, Re]);
format_type(#{type := boolean}) ->
    "";
format_type(#{type := Type}) when is_atom(Type) ->
    io_lib:format(", ~s", [Type]);
format_type(_Opt) ->
    "".

format_default(#{default := Def}) ->
    io_lib:format(", [~tp]", [Def]);
format_default(_) ->
    "".
