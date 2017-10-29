%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
-module(rebar_gitfast_resource).
-behaviour(rebar_resource).

-export([lock/2
        ,download/3
        ,needs_update/2
        ,make_vsn/1
        ]).

-include("rebar.hrl").

-define(MSG_LOCKING(AppDir), lists:flatten(io_lib:format("Locking of git dependency failed in ~ts", [AppDir]))).

-define(MSG_UPDATING(AppDir), lists:flatten(io_lib:format("Checking for update of git dependency failed in ~ts", [AppDir]))).

lock(AppDir, {git, Url, _}) ->
    lock(AppDir, {git, Url});
lock(AppDir, {git, Url}) ->
    {ok, CurrentRef} = read_dotgit(AppDir, ?MSG_LOCKING(AppDir), ref),
    {git, Url, {ref, CurrentRef}}.

download(Dir, {git, Url}, State) ->
    ?WARN("WARNING: It is recommended to use {branch, Name}, {tag, Tag} or {ref, Ref}, otherwise updating the dep may not work as expected.", []),
    download(Dir, {git, Url, {branch, "master"}}, State);
download(Dir, {git, Url, ""}, State) ->
    ?WARN("WARNING: It is recommended to use {branch, Name}, {tag, Tag} or {ref, Ref}, otherwise updating the dep may not work as expected.", []),
    download(Dir, {git, Url, {branch, "master"}}, State);
download(Dir, {git, Url, BranchOrTagOrRefOrRev}, State) ->
    Title = title(BranchOrTagOrRefOrRev),
    ok = filelib:ensure_dir(Dir),
    maybe_warn_local_url(Url),
    Method = pick_strategy(Url, BranchOrTagOrRefOrRev, State),
    download(Method, Url, Dir, Title).

%% Return true if either the git url or tag/branch/ref is not the same as the currently
%% downloaded git repo for the dep
needs_update(Dir, {git, Url, {tag, Tag}}) ->
    AbortMsg = ?MSG_UPDATING(Dir),
    {ok, CurrentTag} = read_dotgit(Dir, AbortMsg, tag),
    ?DEBUG("Comparing git tag ~ts with ~ts", [Tag, CurrentTag]),
    Tag =/= CurrentTag
        orelse not same_url(Dir, Url);
needs_update(Dir, {git, Url, {branch, Branch}}) ->
    AbortMsg = ?MSG_UPDATING(Dir),
    {ok, CurrentBranch} = read_dotgit(Dir, AbortMsg, branch),
    ?DEBUG("Comparing git branch ~ts with ~ts", [Branch, CurrentBranch]),
    Branch =/= CurrentBranch
        orelse not same_url(Dir, Url);
needs_update(Dir, {git, Url, "master"}) ->
    needs_update(Dir, {git, Url, {branch, "master"}});
needs_update(Dir, {git, _, Ref}) ->
    AbortMsg = ?MSG_UPDATING(Dir),
    {ok, CurrentRef} = read_dotgit(Dir, AbortMsg, ref),
    ?DEBUG("Comparing git ref ~ts with ~ts", [Ref, CurrentRef]),
    Ref =/= CurrentRef
        orelse not same_url(Dir, Url).

make_vsn(Dir) ->
    case collect_default_refcount(Dir) of
        Vsn={plain, _} ->
            Vsn;
        {Vsn, RawRef, RawCount} ->
            {plain, build_vsn_string(Vsn, RawRef, RawCount)}
    end.

%% Internal functions

title({branch, Branch}) -> Branch;
title({tag, Tag}) -> Tag;
title({ref, Ref}) -> Ref;
title(Rev) ->
    ?WARN("WARNING: It is recommended to use {branch, Name}, {tag, Tag} or {ref, Ref}, otherwise updating the dep may not work as expected.", []),
    Rev.

pick_strategy("https://github.com/"++_, _, _) -> curl_github;
pick_strategy("git@github.com:"++_, _, _) -> curl_github;
%% Support State options to disable gitfast on certain deps.
%% Switch on whether .git is a folder/file to decide how to fetch metadata.
pick_strategy(_, _, _) -> git_archive.

download(git_archive, Url, Dir, Title) ->
    %% Note: git-archive does not accept SHA1s
    %% Note: does it accept https:// URLs?
    ArchUrl = "git@bitbucket.org:"++ Repo,
    TarredFile = "repo.tar",
    eo_os:chksh('fetch_git-archive', Dir,
                ["git", "archive", "--output", TarredFile, "--remote="++ArchUrl, Branch],
                infinity),
    AbsTarred = filename:join(Dir, TarredFile),
    AbsTitledPath = filename:join(Dir, repo_name(Url)),
    %% Note: the tarball does not have a root directory
    ok = erl_tar:extract(AbsTarred, [{cwd,AbsTitledPath}]),
    eo_util:rmr_symlinks(AbsTitledPath),
    ok = file:delete(AbsTarred),
    {ok, AbsTitledPath};

download(curl_github, Url, Dir, Title) ->
fetch (Dir, {git, "https://github.com/"++Repo=Url, #rev{ id = Title }}) ->
    TarUrl = "https://codeload.github.com/"++ Repo ++"/tar.gz/"++ edoc_lib:escape_uri(Title),
    TarredFile = "repo.tar.gz",
    eo_os:chksh(fetch_curl, Dir,
                ["curl", "--fail", "--silent", "--show-error", "--location",
                 "--output", TarredFile, TarUrl], infinity),
    AbsTarred = filename:join(Dir, TarredFile),
    %% Note: the tar has a root directory
    ok = erl_tar:extract(AbsTarred, [{cwd,Dir}, compressed]),
    AbsTitledPath = filename:join(Dir, repo_name(Url)),
    case [filename:join(Dir, D) || D <- filelib:wildcard("*", Dir)
                                       , D =/= TarredFile
                                       , filelib:is_dir(filename:join(Dir, D))]
    of
        [] -> eo_util:mkdir(AbsTitledPath);
        [AbsUnTarred] ->
            eo_util:rmr_symlinks(AbsUnTarred),
            eo_util:mv([AbsUnTarred], AbsTitledPath)
    end,
    ok = file:delete(AbsTarred),
    {ok, AbsTitledPath};

download(clone, Url, Dir, Title) ->
fetch (Dir, {git, Url, #rev{ id = Title }}) ->
    AbsTitledPath = filename:join(Dir, repo_name(Url)),
    eo_os:chksh('fetch_git-clone', Dir,
                ["git", "clone", "--depth", "1", Url, "--branch", Title, "--", AbsTitledPath],
                infinity),
    eo_util:rmr_symlinks(AbsTitledPath),
    {ok, AbsTitledPath};


git_clone(branch,Url,Dir,Branch) ->
    rebar_utils:sh(?FMT("git clone ~ts ~ts -b ~ts --single-branch",
                        [rebar_utils:escape_chars(Url),
                         rebar_utils:escape_chars(filename:basename(Dir)),
                         rebar_utils:escape_chars(Branch)]),
                   [{cd, filename:dirname(Dir)}]);
git_clone(tag,Url,Dir,Tag) ->
    rebar_utils:sh(?FMT("git clone ~ts ~ts -b ~ts --single-branch",
                        [rebar_utils:escape_chars(Url),
                         rebar_utils:escape_chars(filename:basename(Dir)),
                         rebar_utils:escape_chars(Tag)]),
                   [{cd, filename:dirname(Dir)}]);
git_clone(ref,Url,Dir,Ref) ->
    rebar_utils:sh(?FMT("git clone -n ~ts ~ts",
                        [rebar_utils:escape_chars(Url),
                         rebar_utils:escape_chars(filename:basename(Dir))]),
                   [{cd, filename:dirname(Dir)}]),
    rebar_utils:sh(?FMT("git checkout -q ~ts", [Ref]), [{cd, Dir}]);
git_clone(rev,Url,Dir,Rev) ->
    rebar_utils:sh(?FMT("git clone -n ~ts ~ts",
                        [rebar_utils:escape_chars(Url),
                         rebar_utils:escape_chars(filename:basename(Dir))]),
                   [{cd, filename:dirname(Dir)}]),
    rebar_utils:sh(?FMT("git checkout -q ~ts", [rebar_utils:escape_chars(Rev)]),
                   [{cd, Dir}]).

maybe_warn_local_url(Url) ->
    WarnStr = "Local git resources (~ts) are unsupported and may have odd behaviour. "
              "Use remote git resources, or a plugin for local dependencies.",
    case parse_git_url(Url) of
        {error, no_scheme} -> ?WARN(WarnStr, [Url]);
        {error, {no_default_port, _, _}} -> ?WARN(WarnStr, [Url]);
        {error, {malformed_url, _, _}} -> ?WARN(WarnStr, [Url]);
        _ -> ok
    end.

collect_default_refcount(Dir) ->
    %% Get the tag timestamp and minimal ref from the system. The
    %% timestamp is really important from an ordering perspective.
    case rebar_utils:sh("git log -n 1 --pretty=format:\"%h\n\" ",
                       [{use_stdout, false},
                        return_on_error,
                        {cd, Dir}]) of
        {error, _} ->
            ?WARN("Getting log of git dependency failed in ~ts. Falling back to version 0.0.0", [rebar_dir:get_cwd()]),
            {plain, "0.0.0"};
        {ok, String} ->
            RawRef = string:strip(String, both, $\n),

            {Tag, TagVsn} = parse_tags(Dir),
            {ok, RawCount} =
                case Tag of
                    undefined ->
                        AbortMsg2 = "Getting rev-list of git depedency failed in " ++ Dir,
                        {ok, PatchLines} = rebar_utils:sh("git rev-list HEAD",
                                                          [{use_stdout, false},
                                                           {cd, Dir},
                                                           {debug_abort_on_error, AbortMsg2}]),
                        rebar_utils:line_count(PatchLines);
                    _ ->
                        get_patch_count(Dir, Tag)
                end,
            {TagVsn, RawRef, RawCount}
    end.

build_vsn_string(Vsn, RawRef, Count) ->
    %% Cleanup the tag and the Ref information. Basically leading 'v's and
    %% whitespace needs to go away.
    RefTag = [".ref", re:replace(RawRef, "\\s", "", [global, unicode])],

    %% Create the valid [semver](http://semver.org) version from the tag
    case Count of
        0 ->
            rebar_utils:to_list(Vsn);
        _ ->
            rebar_utils:to_list([Vsn, "+build.", integer_to_list(Count), RefTag])
    end.

get_patch_count(Dir, RawRef) ->
    AbortMsg = "Getting rev-list of git dep failed in " ++ Dir,
    Ref = re:replace(RawRef, "\\s", "", [global, unicode]),
    Cmd = io_lib:format("git rev-list ~ts..HEAD",
                        [rebar_utils:escape_chars(Ref)]),
    {ok, PatchLines} = rebar_utils:sh(Cmd,
                                        [{use_stdout, false},
                                         {cd, Dir},
                                         {debug_abort_on_error, AbortMsg}]),
    rebar_utils:line_count(PatchLines).


parse_tags(Dir) ->
    %% Don't abort on error, we want the bad return to be turned into 0.0.0
    case rebar_utils:sh("git log --oneline --no-walk --tags --decorate",
                        [{use_stdout, false}, return_on_error, {cd, Dir}]) of
        {error, _} ->
            {undefined, "0.0.0"};
        {ok, Line} ->
            case re:run(Line, "(\\(|\\s)(HEAD[^,]*,\\s)tag:\\s(v?([^,\\)]+))", [{capture, [3, 4], list}, unicode]) of
                {match,[Tag, Vsn]} ->
                    {Tag, Vsn};
                nomatch ->
                    case rebar_utils:sh("git describe --tags --abbrev=0",
                            [{use_stdout, false}, return_on_error, {cd, Dir}]) of
                        {error, _} ->
                            {undefined, "0.0.0"};
                        {ok, LatestVsn} ->
                            {undefined, string:strip(LatestVsn, both, $\n)}
                    end
            end
    end.


read_dotgit(AppDir, AbortMsg, Key) ->
    Dotgit = filename:join(AppDir, ".git"),
    case file:consult(Dotgit) of
        {ok, Terms} ->
            {_, Value} = lists:keyfind(Key, 1, Terms),
            {ok, Value};
        {error, Reason} ->
            ?DEBUG("Reading dotgit ~ts failed with ~p", [Dotgit, Reason]),
            ?ABORT(AbortMsg, [])
    end.

same_url(Dir, Url) ->
    {ok, CurrentUrl} = read_dotgit(Dir, AbortMsg, url),
    {ok, ParsedUrl} = parse_git_url(Url),
    {ok, ParsedCurrentUrl} = parse_git_url(CurrentUrl),
    ?DEBUG("Comparing git url ~p with ~p", [ParsedUrl, ParsedCurrentUrl]),
    ParsedCurrentUrl =:= ParsedUrl.

parse_git_url(Url) ->
    %% Checks for standard scp style git remote
    SCP_PATTERN = "\\A(?<username>[^@]+)@(?<host>[^:]+):(?<path>.+)\\z",
    case re:run(Url, SCP_PATTERN, [{capture, [host, path], list}, unicode]) of
        nomatch -> parse_git_url_not_scp(Url);
        {match, [Host, Path]} ->
            {ok, {Host, filename:rootname(Path, ".git")}}
    end.

parse_git_url_not_scp(Url) ->
    UriOpts = [{scheme_defaults, [{git, 9418} | http_uri:scheme_defaults()]}],
    case http_uri:parse(Url, UriOpts) of
        {error, Reason}=E -> E;
        {ok, {_Scheme, _User, Host, _Port, Path, _Query}} ->
            {ok, {Host, filename:rootname(Path, ".git")}}
    end.
