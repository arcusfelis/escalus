%%%===================================================================
%%% @copyright (C) 2011-2012, Erlang Solutions Ltd.
%%% @doc Module abstracting TCP connection to XMPP server
%%% @end
%%%===================================================================

-module(escalus_bosh).
-behaviour(gen_server).

-include_lib("exml/include/exml_stream.hrl").
-include("include/escalus.hrl").
-include("include/escalus_xmlns.hrl").

%% Escalus transport callbacks
-export([connect/1,
         send/2,
         is_connected/1,
         upgrade_to_tls/2,
         use_zlib/2,
         get_transport/1,
         reset_parser/1,
         stop/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% BOSH XML elements
-export([session_creation_body/2, session_creation_body/5,
         session_termination_body/2,
         empty_body/2, empty_body/3]).

%% Low level API
-export([send_raw/2,
         get_sid/1,
         get_rid/1]).

-define(WAIT_FOR_SOCKET_CLOSE_TIMEOUT, 200).
-define(SERVER, ?MODULE).

-record(state, {owner,
                url,
                parser,
                sid = nil,
                rid = nil,
                requests = 0}).

%%%===================================================================
%%% API
%%%===================================================================

-spec connect([{atom(), any()}]) -> {ok, #transport{}}.
connect(Args) ->
    ssl:start(),
    lhttpc:start(),
    {ok, Pid} = gen_server:start_link(?MODULE, [Args, self()], []),
    Transport = gen_server:call(Pid, get_transport),
    {ok, Transport}.

send(#transport{rcv_pid = Pid} = Socket, Elem) ->
    gen_server:cast(Pid, {send, Socket, Elem}).

is_connected(#transport{rcv_pid = Pid}) ->
    erlang:is_process_alive(Pid).

reset_parser(#transport{rcv_pid = Pid}) ->
    gen_server:cast(Pid, reset_parser).

stop(#transport{rcv_pid = Pid}) ->
    try
        gen_server:call(Pid, stop)
    catch
        exit:{noproc, {gen_server, call, _}} ->
            already_stopped
    end.

upgrade_to_tls(#transport{} = _Conn, _Props) ->
    not_supported.

use_zlib(#transport{} = _Conn, _Props) ->
    not_supported.

get_transport(#transport{rcv_pid = Pid}) ->
    gen_server:call(Pid, get_transport).

%%%===================================================================
%%% BOSH XML elements
%%%===================================================================

session_creation_body(Rid, To) ->
    session_creation_body(<<"1.0">>, <<"en">>, Rid, To, nil).

session_creation_body(Version, Lang, Rid, To, Sid) ->
    empty_body(Rid, Sid,
               [{<<"content">>, <<"text/xml; charset=utf-8">>},
                {<<"xmlns:xmpp">>, ?NS_BOSH},
                {<<"xmpp:version">>, Version},
                {<<"hold">>, <<"1">>},
                {<<"wait">>, <<"60">>},
                {<<"xml:lang">>, Lang},
                {<<"to">>, To}]
               ++ [{<<"xmpp:restart">>, <<"true">>} || Sid =/= nil]).

session_termination_body(Rid, Sid) ->
    Body = empty_body(Rid, Sid, [{<<"type">>, <<"terminate">>}]),
    Body#xmlelement{children = [escalus_stanza:presence(<<"unavailable">>)]}.

empty_body(Rid, Sid) ->
    empty_body(Rid, Sid, []).

empty_body(Rid, Sid, ExtraAttrs) ->
    #xmlelement{name = <<"body">>,
                attrs = common_attrs(Rid, Sid) ++ ExtraAttrs}.

common_attrs(Rid) ->
    [{<<"rid">>, pack_rid(Rid)},
     {<<"xmlns">>, ?NS_HTTP_BIND}].

common_attrs(Rid, nil) ->
    common_attrs(Rid);
common_attrs(Rid, Sid) ->
    common_attrs(Rid) ++ [{<<"sid">>, Sid}].

pack_rid(Rid) ->
    list_to_binary(integer_to_list(Rid)).

%%%===================================================================
%%% Low level API
%%%===================================================================

%% Watch out for request IDs!
%% In general, you should not use this function, as this transport takes
%% care of wrapping ordinary XMPP stanzas for you.
%% However, in case of the need for a low-level access don't interleave
%% calls to send/2 and send_raw/2.
%% For send/2 the transport keeps track of an internal
%% request ID which might not necessarily be consistent with the one supplied
%% when manually building the BOSH body and sending it with send_raw/2.
%% These non matching request IDs will
%% confuse the server and possibly cause errors.
send_raw(#transport{rcv_pid = Pid} = Transport, Body) ->
    gen_server:cast(Pid, {send_raw, Transport, Body}).

get_rid(#transport{rcv_pid = Pid}) ->
    gen_server:call(Pid, get_rid).

get_sid(#transport{rcv_pid = Pid}) ->
    gen_server:call(Pid, get_sid).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Args, Owner]) ->
    Host = proplists:get_value(host, Args, <<"localhost">>),
    Port = proplists:get_value(port, Args, 5280),
    Path = proplists:get_value(path, Args, <<"/http-bind">>),
    HostStr = binary_to_list(Host),
    {MS, S, MMS} = now(),
    InitRid = MS * 1000000 * 1000000 + S * 1000000 + MMS,
    {ok, Parser} = exml_stream:new_parser(),
    {ok, #state{owner = Owner,
                url = {HostStr, Port, binary_to_list(Path)},
                parser = Parser, rid = InitRid}}.

handle_call(get_transport, _From, State) ->
    {reply, transport(State), State};
handle_call(get_sid, _From, #state{sid = Sid} = State) ->
    {reply, Sid, State};
handle_call(get_rid, _From, #state{rid = Rid} = State) ->
    {reply, Rid, State};
handle_call(stop, _From, #state{} = State) ->
    StreamEnd = escalus_stanza:stream_end(),
    NewState = send0(transport(State), exml:to_iolist(StreamEnd), State),
    {stop, normal, ok, NewState}.

handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast({send, Transport, Elem}, State) ->
    NewState = send0(Transport, Elem, State),
    {noreply, NewState};
handle_cast({send_raw, Transport, Body}, State) ->
    NewState = send(Transport, Body, State),
    {noreply, NewState};
handle_cast(reset_parser, #state{parser = Parser} = State) ->
    {ok, NewParser} = exml_stream:reset_parser(Parser),
    {noreply, State#state{parser = NewParser}}.

%% Handle async HTTP request replies.
handle_info({http_reply, {_StatusAndReason, _Hdrs, Body}, Transport}, S) ->
    NS = handle_data(Body, S#state{requests = S#state.requests - 1}),
    NNS = case NS#state.requests == 0 of
        true ->
            send(Transport, empty_body(NS#state.rid, NS#state.sid), NS);
        false ->
            NS
    end,
    {noreply, NNS};
handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, #state{parser = Parser}) ->
    exml_stream:free_parser(Parser).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Helpers
%%%===================================================================
send(#transport{socket = {Host, Port, Path}} = Transport, Body,
     #state{requests = Requests} = State) ->
    Headers = [{"Content-Type", "text/xml; charset=utf-8"}],
    Self = self(),
    AsyncReq = fun() ->
        {ok, Reply} =
            lhttpc:request(Host, Port, false, Path, 'POST',
                Headers, exml:to_iolist(Body), infinity, []),
        Self ! {http_reply, Reply, Transport}
    end,
    proc_lib:spawn_link(AsyncReq),
    State#state{rid = State#state.rid+1,
                requests = Requests + 1}.

send0(Transport, Elem, State) ->
    send(Transport, wrap_elem(Elem, State), State).

handle_data(Data, #state{owner = Owner} = State) ->
    {ok, Body} = exml:parse(Data),
    NewState = case State#state.sid of
        %% First reply for this transport, set sid
        nil ->
            State#state{sid = exml_query:attr(Body, <<"sid">>)};
        _ ->
            State
    end,
    Stanzas = unwrap_elem(Body),
    lists:foreach(fun(Stanza) ->
        Owner ! {stanza, transport(NewState), Stanza}
    end, Stanzas),
    case lists:keyfind(xmlstreamend, 1, Stanzas) of
        false ->
            ok;
        _ ->
            gen_server:cast(self(), stop)
    end,
    NewState.

transport(#state{url = Url}) ->
    #transport{module = ?MODULE,
               socket = Url,
               ssl = false,
               compress = false,
               rcv_pid = self()}.

wrap_elem(#xmlstreamstart{attrs=Attrs}, #state{rid=Rid, sid=Sid}) ->
    Version = proplists:get_value(<<"version">>, Attrs, <<"1.0">>),
    Lang = proplists:get_value(<<"xml:lang">>, Attrs, <<"en">>),
    To = proplists:get_value(<<"to">>, Attrs, <<"localhost">>),
    session_creation_body(Version, Lang, Rid, To, Sid);
wrap_elem(["</", <<"stream:stream">>, ">"], #state{sid=Sid, rid=Rid}) ->
    session_termination_body(Rid, Sid);
wrap_elem(Element, #state{sid = Sid, rid=Rid}) ->
    (empty_body(Rid, Sid))#xmlelement{children = [Element]}.

unwrap_elem(#xmlelement{name = <<"body">>, children = Body, attrs=Attrs}) ->
    Type = detect_type(Attrs),
    case Type of
        {streamstart, Ver} ->
            Server = proplists:get_value(<<"from">>, Attrs),
            StreamStart = #xmlstreamstart{name = <<"stream:stream">>, attrs=[
                        {<<"from">>, Server},
                        {<<"version">>, Ver},
                        {<<"xml:lang">>, <<"en">>},
                        {<<"xmlns">>, <<"jabber:client">>},
                        {<<"xmlns:stream">>, <<"http://etherx.jabber.org/streams">>}]},
            [StreamStart];
        streamend ->
            [escalus_stanza:stream_end()];
        _ -> []
    end ++ Body.

detect_type(Attrs) ->
    catch begin
        case proplists:get_value(<<"type">>, Attrs) of
            <<"terminate">> ->
                throw(streamend);
            _ -> normal
        end,
        case proplists:get_value(<<"xmpp:version">>, Attrs) of
            undefined -> normal;
            Version -> throw({streamstart, Version})
        end
    end.


